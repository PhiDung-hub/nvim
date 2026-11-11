-- :Pack — the plugin manager window (lazy.nvim's home view in the Agent OS look). Rows read
-- `● name  version rev  time  reason`; ⏎ folds details open, and the footer lists the actions.
local M = {}
local api = vim.api
local pack = require("config.pack")
local ns = api.nvim_create_namespace("ui.pack")
local open_rows, row_name, win, buf = {}, {}, nil, nil

local KEYS = {
  { "U", "update" }, { "S", "sync" }, { "u", "update one" }, { "l", "load" }, { "C", "clean" },
  { "R", "restore lock" }, { "L", "log" }, { "⏎", "details" }, { "q", "close" },
}

local function info()
  local by = {}
  for _, p in ipairs(vim.pack.get(nil, { info = false })) do by[p.spec.name] = p end
  return by
end

local function triggers(spec)
  local t = {}
  for _, e in ipairs(spec.event or {}) do t[#t + 1] = "event " .. e end
  for _, f in ipairs(spec.ft or {}) do t[#t + 1] = "ft " .. f end
  for _, c in ipairs(spec.cmd or {}) do t[#t + 1] = ":" .. c end
  for _, k in ipairs(spec.keys or {}) do t[#t + 1] = "key " .. k[1] end
  return t
end

local function version_label(spec)
  return spec.version or spec.tag or spec.branch or "default"
end

local function add(lines, marks, text, chunks)
  lines[#lines + 1] = text
  for _, c in ipairs(chunks or {}) do marks[#marks + 1] = { #lines - 1, c[1], c[2], c[3] } end
end

local function plugin_rows(lines, marks, p, disk)
  local rev = disk and disk.rev:sub(1, 7) or "missing"
  local glyph, ghl = p.loaded and "●" or "○", p.loaded and "AosDone" or "AosDim"
  local left = ("  %s %-18s %-10s %s"):format(glyph, p.name, version_label(p.spec), rev)
  local right = p.loaded and ("%6.2f ms  %s"):format(p.time or 0, p.reason) or table.concat(triggers(p.spec), " · ")
  local text = left .. "  " .. right
  local col = #left + 2
  add(lines, marks, text, {
    { 2, 2 + #glyph, ghl }, { #glyph + 3, #glyph + 3 + #p.name, "Bold" },
    { #left - 7, #left, disk and "AosSha" or "AosFailed" }, { col, #text, p.loaded and "AosArg" or "AosDim" },
  })
  row_name[#lines] = p.name
  if not open_rows[p.name] then return end
  local detail = {
    { "src", p.src }, { "path", p.path }, { "version", version_label(p.spec) },
    { "triggers", #triggers(p.spec) > 0 and table.concat(triggers(p.spec), " · ") or "start" },
    { "build", p.spec.build and (type(p.spec.build) == "string" and p.spec.build or "function") or "—" },
  }
  for _, d in ipairs(detail) do
    add(lines, marks, ("      ⎿ %-9s %s"):format(d[1], d[2]), { { 6, 19, "AosDim" } })
    row_name[#lines] = p.name
  end
end

local function render()
  if not (buf and api.nvim_buf_is_valid(buf)) then return end
  local disk, lines, marks = info(), {}, {}
  row_name = {}
  local loaded = vim.tbl_filter(function(n) return pack.plugins[n].loaded end, pack.order)
  local head = (" %d plugins · %d loaded · startup %s"):format(#pack.order, #loaded,
    pack.startup and ("%.1f ms"):format(pack.startup) or "—")
  add(lines, marks, head, { { 0, #head, "AosDim" } })
  local foot = {}
  for _, k in ipairs(KEYS) do foot[#foot + 1] = k[1] .. " " .. k[2] end
  add(lines, marks, " " .. table.concat(foot, " · "), { { 0, -1, "AosDim" } })
  local sections = {
    { "Loaded", function(p) return p.loaded end },
    { "Not loaded", function(p) return not p.loaded end },
  }
  for _, s in ipairs(sections) do
    local names = vim.tbl_filter(function(n) return s[2](pack.plugins[n]) end, pack.order)
    if #names > 0 then
      add(lines, marks, "")
      add(lines, marks, (" ▾ %s %d"):format(s[1], #names), { { 1, -1, "AosArg" } })
      for _, n in ipairs(names) do plugin_rows(lines, marks, pack.plugins[n], disk[n]) end
    end
  end
  local stray = vim.tbl_filter(function(n) return not pack.plugins[n] end, vim.tbl_keys(disk))
  if #stray > 0 then
    add(lines, marks, "")
    add(lines, marks, (" ▾ Not in spec %d · C removes"):format(#stray), { { 1, -1, "AosRunning" } })
    for _, n in ipairs(stray) do add(lines, marks, "  ✗ " .. n, { { 2, 5, "AosFailed" } }) end
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    local len = #lines[m[1] + 1]
    local e = m[3] < 0 and len or math.min(m[3], len)
    if m[2] < e then api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = e, hl_group = m[4] }) end
  end
end

local function current()
  return row_name[api.nvim_win_get_cursor(0)[1]]
end

local function stray()
  local names = {}
  for name in pairs(info()) do
    if not pack.plugins[name] then names[#names + 1] = name end
  end
  return names
end

local actions = {
  U = function() vim.pack.update() end,
  S = function() vim.pack.update(nil, { force = true }) render() end,
  u = function() local n = current() if n then vim.pack.update({ n }) end end,
  l = function() local n = current() if n then pack.load(n, "manual") render() end end,
  R = function() vim.pack.update(nil, { target = "lockfile", force = true }) render() end,
  L = function() vim.cmd.split(vim.fs.joinpath(vim.fn.stdpath("log"), "nvim-pack.log")) end,
  C = function()
    local names = stray()
    if #names == 0 then return vim.notify("○ nothing to clean") end
    if vim.fn.confirm("Remove " .. table.concat(names, ", ") .. "?", "&Yes\n&No", 2) ~= 1 then return end
    vim.pack.del(names)
    render()
  end,
  ["<CR>"] = function()
    local n = current()
    if not n then return end
    open_rows[n] = not open_rows[n]
    render()
  end,
}

function M.open()
  if win and api.nvim_win_is_valid(win) then return api.nvim_set_current_win(win) end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width, height = math.floor(vim.o.columns * 0.8), math.floor(vim.o.lines * 0.7)
  win = api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height, style = "minimal",
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    title = " ❯ pack ", title_pos = "left",
  })
  vim.wo[win].cursorline = true
  for key, fn in pairs(actions) do vim.keymap.set("n", key, fn, { buffer = buf, nowait = true }) end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
  api.nvim_create_autocmd("PackChanged", {
    group = api.nvim_create_augroup("ui.pack", {}),
    callback = function() vim.schedule(render) end,
  })
  render()
  api.nvim_win_set_cursor(win, { math.min(5, api.nvim_buf_line_count(buf)), 0 })
end

M.keys = KEYS
return M
