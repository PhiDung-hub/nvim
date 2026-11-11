-- Plugin manager on nvim 0.12's vim.pack: lazy.nvim-style specs (lua/plugins.lua) with lazy loading by event, cmd,
-- keys and ft, build hooks on install/update, and per-plugin load timing for the :Pack window (ui/pack.lua).
local M = { plugins = {}, order = {}, t0 = vim.uv.hrtime() }
local api = vim.api

for _, name in ipairs({ "gzip", "matchit", "netrwPlugin", "netrw", "tarPlugin", "tohtml", "tutor", "zipPlugin" }) do
  vim.g["loaded_" .. name] = 1
end

local function ms(t) return (vim.uv.hrtime() - t) / 1e6 end

local function version_of(spec)
  if spec.version then return vim.version.range(spec.version) end
  return spec.tag or spec.branch
end

local function source_after(path)
  for _, kind in ipairs({ "vim", "lua" }) do
    for _, file in ipairs(vim.fn.glob(path .. "/after/plugin/**/*." .. kind, false, true)) do vim.cmd.source(file) end
  end
end

local function setup_plugin(p)
  local spec = p.spec
  if spec.config then return spec.config(p, spec.opts or {}) end
  if spec.opts == nil then return end
  local main = spec.main or p.name:gsub("%.nvim$", ""):gsub("^nvim%-", "")
  require(main).setup(spec.opts)
end

function M.load(name, reason)
  local p = M.plugins[name]
  if not p or p.loaded then return p end
  p.loaded, p.reason = true, reason or "start"
  if p.augroup then pcall(api.nvim_del_augroup_by_id, p.augroup) end
  for _, stub in ipairs(p.stubs or {}) do pcall(stub) end
  local t = vim.uv.hrtime()
  local starting = vim.v.vim_did_init == 0
  vim.cmd.packadd({ vim.fn.escape(name, " "), bang = starting, magic = { file = false } })
  if not starting then source_after(p.path) end
  local ok, err = pcall(setup_plugin, p)
  p.time = ms(t)
  if not ok then vim.notify(("✗ %s · config failed\n%s"):format(name, err), vim.log.levels.ERROR) end
  return p
end

-- Replay the triggering event for augroups the plugin created while loading (lazy.nvim does the same).
local function replay(event, ev, before)
  local seen = {}
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    if au.group and not before[au.group] and not seen[au.group] then
      seen[au.group] = true
      pcall(api.nvim_exec_autocmds, event, { group = au.group, buffer = ev.buf, modeline = false, data = ev.data })
    end
  end
end

local function on_event(p, item)
  local event, pattern = item:match("^(%S+)%s*(.*)$")
  api.nvim_create_autocmd(event, {
    group = p.augroup,
    pattern = pattern ~= "" and pattern or nil,
    once = true,
    callback = function(ev)
      local before = {}
      for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do before[au.group or 0] = true end
      M.load(p.name, event .. (pattern ~= "" and " " .. pattern or ""))
      replay(event, ev, before)
    end,
  })
end

local function on_cmd(p, cmd)
  api.nvim_create_user_command(cmd, function(o)
    M.load(p.name, ":" .. cmd)
    local range = o.range > 0 and (o.range == 1 and o.line1 or o.line1 .. "," .. o.line2) or ""
    vim.cmd(range .. cmd .. (o.bang and "!" or "") .. (o.args ~= "" and " " .. o.args or ""))
  end, {
    nargs = "*", bang = true, range = true, desc = "load " .. p.name,
    complete = function(_, line)
      M.load(p.name, ":" .. cmd)
      return vim.fn.getcompletion(line, "cmdline")
    end,
  })
  table.insert(p.stubs, function() pcall(api.nvim_del_user_command, cmd) end)
end

local function on_key(p, key)
  local lhs, rhs, mode = key[1], key[2], key.mode or "n"
  local opts = { desc = key.desc, silent = key.silent }
  vim.keymap.set(mode, lhs, function()
    M.load(p.name, "key " .. lhs)
    if type(rhs) == "function" then return rhs() end
    if rhs then return api.nvim_feedkeys(vim.keycode(rhs), "m", false) end
    api.nvim_feedkeys(vim.keycode(lhs), "m", false)
  end, opts)
  if rhs then table.insert(p.stubs, function() vim.keymap.set(mode, lhs, rhs, opts) end)
  else table.insert(p.stubs, function() pcall(vim.keymap.del, mode, lhs) end) end
end

local function triggers(p)
  local spec = p.spec
  local events = vim.list_extend(vim.deepcopy(spec.event or {}), vim.tbl_map(function(ft) return "FileType " .. ft end, spec.ft or {}))
  for _, item in ipairs(events) do on_event(p, item) end
  for _, cmd in ipairs(spec.cmd or {}) do on_cmd(p, cmd) end
  for _, key in ipairs(spec.keys or {}) do on_key(p, key) end
  return #events + #(spec.cmd or {}) + #(spec.keys or {}) > 0
end

local function run_build(p)
  local build = p.spec.build
  if not build then return end
  M.load(p.name, "build")
  local ok, err = pcall(type(build) == "function" and build or function() vim.cmd(build:gsub("^:", "")) end, p)
  vim.notify(ok and ("✓ %s · built"):format(p.name) or ("✗ %s · build failed\n%s"):format(p.name, err),
    ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end

-- `require` of a module an unloaded plugin ships loads that plugin first, as lazy.nvim's module trigger does.
local function owner(top)
  for _, name in ipairs(M.order) do
    local p = M.plugins[name]
    local dir = p.path .. "/lua/" .. top
    if not p.loaded and (vim.uv.fs_stat(dir) or vim.uv.fs_stat(dir .. ".lua")) then return name end
  end
end

local function searcher(modname)
  local name = owner(modname:match("^[^.]+"))
  if not name then return end
  M.load(name, "require " .. modname)
  for _, loader in ipairs(package.loaders) do
    if loader ~= searcher then
      local found = loader(modname)
      if type(found) == "function" then return found end
    end
  end
end

local function normalize(spec)
  local repo = spec[1]
  local p = { spec = spec, name = spec.name or repo:match("[^/]+$"), src = spec.src or ("https://github.com/" .. repo), stubs = {} }
  p.path = vim.fs.joinpath(vim.fn.stdpath("data"), "site/pack/core/opt", p.name)
  return p
end

function M.setup(specs)
  local list = {}
  for _, spec in ipairs(specs) do
    local p = normalize(spec)
    M.plugins[p.name], M.order[#M.order + 1] = p, p.name
    list[#list + 1] = { src = p.src, name = p.name, version = version_of(spec) }
  end
  api.nvim_create_autocmd("PackChanged", {
    callback = function(ev)
      local p, kind = M.plugins[ev.data.spec.name], ev.data.kind
      if p and (kind == "install" or kind == "update") then vim.schedule(function() run_build(p) end) end
    end,
  })
  vim.pack.add(list, { confirm = false, load = function() end })
  table.insert(package.loaders, 2, searcher)
  for _, name in ipairs(M.order) do
    local p = M.plugins[name]
    if p.spec.init then p.spec.init(p) end
    p.augroup = api.nvim_create_augroup("pack." .. name, {})
    local lazy = p.spec.lazy ~= false and triggers(p)
    if not lazy then M.load(name, "start") end
  end
  api.nvim_create_autocmd("VimEnter", { once = true, callback = function() M.startup = ms(M.t0) end })
  for _, cmd in ipairs({ "Pack", "Lazy" }) do
    api.nvim_create_user_command(cmd, function() require("ui.pack").open() end, { desc = "Plugin manager" })
  end
end

return M
