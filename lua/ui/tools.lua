-- :Tools (alias :Mason) — installs the language servers and formatters this config uses into
-- stdpath("data")/mason (packages/<name>, links in bin/, already on PATH via config/options.lua).
-- A fixed list instead of mason.nvim's registry; installs run async (npm, pip venv, cargo, GitHub releases).
local M = {}
local api = vim.api
local root = vim.fs.joinpath(vim.fn.stdpath("data"), "mason")
local bindir, pkgdir = root .. "/bin", root .. "/packages"
local ns = api.nvim_create_namespace("ui.tools")
local busy, win, buf, rows = {}, nil, nil, {}

local TOOLS = {
  { "bash-language-server", npm = "bash-language-server", bin = { "bash-language-server" } },
  { "clangd", github = "clangd/clangd", asset = "^clangd%-linux%-[%d%.]+%.zip$", bin = { clangd = "clangd_*/bin/clangd" } },
  { "copilot-language-server", npm = "@github/copilot-language-server", bin = { "copilot-language-server" } },
  { "css-lsp", npm = "vscode-langservers-extracted", bin = { "vscode-css-language-server" } },
  { "emmet-ls", npm = "emmet-ls", bin = { "emmet-ls" } },
  { "html-lsp", npm = "vscode-langservers-extracted", bin = { "vscode-html-language-server" } },
  { "json-lsp", npm = "vscode-langservers-extracted", bin = { "vscode-json-language-server" } },
  { "lua-language-server", github = "LuaLS/lua-language-server", asset = "linux%-x64%.tar%.gz$", into = "libexec",
    wrapper = { ["lua-language-server"] = "libexec/bin/lua-language-server" } },
  { "move-analyzer", cargo = { "--git", "https://github.com/move-language/move", "move-analyzer" }, bin = { "move-analyzer" } },
  { "prettierd", npm = "@fsouza/prettierd", bin = { "prettierd" } },
  { "prisma-language-server", npm = "@prisma/language-server", bin = { "prisma-language-server" } },
  { "pyright", npm = "pyright", bin = { "pyright", "pyright-langserver" } },
  { "ruff", pypi = "ruff", bin = { "ruff" } },
  { "rust-analyzer", github = "rust-lang/rust-analyzer", asset = "^rust%-analyzer%-x86_64%-unknown%-linux%-gnu%.gz$",
    bin = { ["rust-analyzer"] = "rust-analyzer" } },
  { "sqlls", npm = "sql-language-server", bin = { "sql-language-server" } },
  { "stylua", github = "JohnnyMorganz/StyLua", asset = "^stylua%-linux%-x86_64%.zip$", bin = { stylua = "stylua" } },
  { "svelte-language-server", npm = "svelte-language-server", bin = { "svelteserver" } },
  { "tailwindcss-language-server", npm = "@tailwindcss/language-server", bin = { "tailwindcss-language-server" } },
  { "taplo", github = "tamasfe/taplo", asset = "^taplo%-linux%-x86_64%.gz$", bin = { taplo = "taplo" } },
  { "typescript-language-server", npm = "typescript-language-server", bin = { "typescript-language-server" } },
  { "yaml-language-server", npm = "yaml-language-server", bin = { "yaml-language-server" } },
}

local function source(t)
  if t.npm then return "npm " .. t.npm end
  if t.pypi then return "pip " .. t.pypi end
  if t.cargo then return "cargo " .. t.cargo[#t.cargo] end
  return "github " .. t.github
end

-- Bin name → path inside the package dir (globs allowed).
local function bins(t)
  local out = {}
  for key, value in pairs(t.bin or {}) do
    if type(key) == "string" then out[key] = value
    elseif t.npm then out[value] = "node_modules/.bin/" .. value
    elseif t.pypi then out[value] = "venv/bin/" .. value
    else out[value] = "bin/" .. value end
  end
  for name in pairs(t.wrapper or {}) do out[name] = name end
  return out
end

local function read_json(path)
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  return ok and data or nil
end

local function version(t)
  local dir = pkgdir .. "/" .. t[1]
  local receipt = read_json(dir .. "/receipt.json")
  if receipt then return receipt.version end
  local mason = read_json(dir .. "/mason-receipt.json")
  local id = mason and vim.tbl_get(mason, "primary_source", "id") or vim.tbl_get(mason or {}, "source", "id")
  return id and id:match("@([^?]+)") or (vim.fn.isdirectory(dir) == 1 and "?" or nil)
end

local function render()
  if not (buf and api.nvim_buf_is_valid(buf)) then return end
  local lines, marks = {}, {}
  local installed = #vim.tbl_filter(version, TOOLS)
  lines[1] = (" %d tools · %d installed · %s"):format(#TOOLS, installed, bindir)
  lines[2] = " i install · u update · U update all · x remove · q close"
  lines[3], rows = "", {}
  for _, t in ipairs(TOOLS) do
    local v, state = version(t), busy[t[1]]
    local glyph, hl = state and "◆" or v and "●" or "○", state and "AosRunning" or v and "AosDone" or "AosDim"
    local text = ("  %s %-28s %-14s %s"):format(glyph, t[1], state or v or "missing", source(t))
    lines[#lines + 1], rows[#lines + 1] = text, t
    marks[#marks + 1] = { #lines - 1, 2, 2 + #glyph, hl }
    marks[#marks + 1] = { #lines - 1, 33 + #glyph, 47 + #glyph, state and "AosRunning" or v and "AosSha" or "AosDim" }
    marks[#marks + 1] = { #lines - 1, 48 + #glyph, #text, "AosDim" }
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "AosDim" })
  api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "AosDim" })
  for _, m in ipairs(marks) do api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = math.min(m[3], #lines[m[1] + 1]), hl_group = m[4] }) end
end

-- Run argv steps one after another; `done(err)` gets the failing step's stderr tail.
local function chain(steps, done)
  local step = table.remove(steps, 1)
  if not step then return done() end
  if type(step) == "function" then
    local ok, err = pcall(step)
    if not ok then return done(tostring(err)) end
    return chain(steps, done)
  end
  vim.system(step, { text = true }, vim.schedule_wrap(function(r)
    if r.code ~= 0 then return done(((r.stderr or "") .. (r.stdout or "")):sub(-600)) end
    chain(steps, done)
  end))
end

local function github_steps(t, stage, done)
  local api_url = ("https://api.github.com/repos/%s/releases/latest"):format(t.github)
  vim.system({ "curl", "-fsSL", api_url }, { text = true }, vim.schedule_wrap(function(r)
    local release = r.code == 0 and pcall(vim.json.decode, r.stdout) and vim.json.decode(r.stdout)
    local asset = release and vim.iter(release.assets or {}):find(function(a) return a.name:match(t.asset) end)
    if not asset then return done(nil, "no release asset matches " .. t.asset) end
    local file, dest = stage .. "/" .. asset.name, stage .. "/" .. (t.into or "")
    local extract = asset.name:match("%.zip$") and { "unzip", "-q", "-o", file, "-d", dest }
      or asset.name:match("%.tar%.gz$") and { "tar", "-xzf", file, "-C", dest }
      or { "sh", "-c", ('gunzip -c "%s" > "%s/%s"'):format(file, stage, next(t.bin)) }
    done({ { "mkdir", "-p", dest }, { "curl", "-fsSL", "-o", file, asset.browser_download_url }, extract,
      function() vim.fn.delete(file) end }, release.tag_name)
  end))
end

local function plain_steps(t, stage)
  if t.npm then return { { "npm", "install", "--silent", "--prefix", stage, t.npm .. "@latest" } } end
  if t.pypi then return { { "python3", "-m", "venv", stage .. "/venv" }, { stage .. "/venv/bin/pip", "install", "-q", "-U", t.pypi } } end
  -- Not --locked: move-analyzer's lockfile pins an ethnum that current rustc rejects (E0512).
  return { vim.list_extend({ "cargo", "install", "--root", stage }, t.cargo) }
end

local function installed_version(t, stage, tag)
  if tag then return tag end
  if t.npm then
    local pkg = read_json(stage .. "/node_modules/" .. t.npm .. "/package.json")
    return pkg and pkg.version or "latest"
  end
  if t.pypi then
    local info = vim.fn.glob(stage .. "/venv/lib*/python*/site-packages/" .. t.pypi .. "-*.dist-info", false, true)[1]
    return info and info:match("%-([%d%.]+)%.dist%-info$") or "latest"
  end
  local crates = read_json(stage .. "/.crates2.json")
  local key = crates and next(crates.installs or {}) or ""
  local rev = key:match("#(%x+)%)$")
  return rev and rev:sub(1, 7) or key:match("^%S+ (%S+)") or "latest"
end

-- Swap the staged package in, then (re)link bins and write wrappers and a receipt.
local function finish(t, stage, tag)
  local dir = pkgdir .. "/" .. t[1]
  local v = installed_version(t, stage, tag)
  vim.fn.delete(dir, "rf")
  assert(vim.uv.fs_rename(stage, dir))
  for name, target in pairs(t.wrapper or {}) do
    vim.fn.writefile({ "#!/usr/bin/env bash", ('exec "%s/%s" "$@"'):format(dir, target) }, dir .. "/" .. name)
  end
  vim.fn.mkdir(bindir, "p")
  for name, rel in pairs(bins(t)) do
    local path = vim.fn.glob(dir .. "/" .. rel, false, true)[1]
    assert(path, "missing " .. rel)
    vim.uv.fs_chmod(path, 493)
    vim.fn.delete(bindir .. "/" .. name)
    assert(vim.uv.fs_symlink(path, bindir .. "/" .. name))
  end
  vim.fn.writefile({ vim.json.encode({ version = v, source = source(t) }) }, dir .. "/receipt.json")
  return v
end

local function install(t)
  if busy[t[1]] then return end
  busy[t[1]] = "installing…"
  render()
  local stage = pkgdir .. "/" .. t[1] .. ".new"
  vim.fn.delete(stage, "rf")
  vim.fn.mkdir(stage, "p")
  local function done(err, tag)
    busy[t[1]] = nil
    if err then
      vim.fn.delete(stage, "rf")
      vim.notify(("✗ %s · install failed\n%s"):format(t[1], err), vim.log.levels.ERROR)
      return render()
    end
    local ok, result = pcall(finish, t, stage, tag)
    vim.notify(ok and ("✓ %s %s"):format(t[1], result) or ("✗ %s · %s"):format(t[1], result),
      ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    render()
  end
  if not t.github then return chain(plain_steps(t, stage), done) end
  github_steps(t, stage, function(steps, tag_or_err)
    if not steps then return done(tag_or_err) end
    chain(steps, function(err) done(err, tag_or_err) end)
  end)
end

local function remove(t)
  for name in pairs(bins(t)) do vim.fn.delete(bindir .. "/" .. name) end
  vim.fn.delete(pkgdir .. "/" .. t[1], "rf")
  vim.notify("○ removed " .. t[1])
  render()
end

local function at_cursor() return rows[api.nvim_win_get_cursor(0)[1]] end

local actions = {
  i = function() local t = at_cursor() if t then install(t) end end,
  u = function() local t = at_cursor() if t then install(t) end end,
  U = function() for _, t in ipairs(TOOLS) do if version(t) then install(t) end end end,
  x = function()
    local t = at_cursor()
    if t and vim.fn.confirm("Remove " .. t[1] .. "?", "&Yes\n&No", 2) == 1 then remove(t) end
  end,
}

function M.open()
  if win and api.nvim_win_is_valid(win) then return api.nvim_set_current_win(win) end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width, height = math.min(100, vim.o.columns - 4), math.min(#TOOLS + 4, vim.o.lines - 4)
  win = api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height, style = "minimal",
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    title = " ❯ tools ", title_pos = "left",
  })
  vim.wo[win].cursorline = true
  for key, fn in pairs(actions) do vim.keymap.set("n", key, fn, { buffer = buf, nowait = true }) end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
  render()
  api.nvim_win_set_cursor(win, { 4, 0 })
end

function M.setup()
  for _, cmd in ipairs({ "Tools", "Mason" }) do
    api.nvim_create_user_command(cmd, M.open, { desc = "Install language servers and formatters" })
  end
end

M.tools = TOOLS
return M
