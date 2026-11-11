-- One top bar like the WezTerm tab bar: listed buffers left (` ● 1:name `), status segments right.
local M = {}
local g = require("design").glyphs
local icons = require("ui.icons")

local function esc(s) return (s:gsub("%%", "%%%%")) end

-- The blank buffer nvim starts with (unnamed, empty, unchanged) is not worth a tab.
local function blank(b)
  return vim.api.nvim_buf_get_name(b) == "" and not vim.bo[b].modified and vim.bo[b].buftype == ""
    and vim.api.nvim_buf_line_count(b) == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == ""
end

function M.listed()
  return vim.tbl_filter(function(b) return vim.bo[b].buflisted and not blank(b) end, vim.api.nvim_list_bufs())
end

-- The current tab sits on TabLineSel's band, so its accent colours are re-derived onto that background.
local derived = {}
local function on_surface(group, base)
  base = base or "TabLine"
  local name = "AosTab" .. group .. (base == "TabLine" and "" or "Sel")
  if derived[name] then return name end
  local bg_hl = vim.api.nvim_get_hl(0, { name = base, link = false })
  vim.api.nvim_set_hl(0, name, { fg = vim.api.nvim_get_hl(0, { name = group, link = false }).fg, bg = bg_hl.bg, bold = bg_hl.bold })
  derived[name] = true
  return name
end

local function tail(path, depth)
  local parts = vim.split(path, "/", { trimempty = true })
  return table.concat(parts, "/", math.max(1, #parts - depth))
end

-- File names, widened with parent directories until no two tabs share one. Recomputed only when the set changes.
local names_key, names_cache
local function unique_names(bufs)
  local paths = {}
  for i, b in ipairs(bufs) do paths[i] = b .. ":" .. vim.api.nvim_buf_get_name(b) end
  local key = table.concat(paths, "\0")
  if key == names_key then return names_cache end
  local depth, names = {}, {}
  names_key, names_cache = key, names
  for _ = 0, 3 do
    local count, clash = {}, false
    for _, b in ipairs(bufs) do
      names[b] = tail(vim.api.nvim_buf_get_name(b), depth[b] or 0)
      count[names[b]] = (count[names[b]] or 0) + 1
    end
    for _, b in ipairs(bufs) do
      if names[b] ~= "" and count[names[b]] > 1 then depth[b], clash = (depth[b] or 0) + 1, true end
    end
    if not clash then break end
  end
  return names
end

local lock = "\u{f023}"

-- The file the bar describes: the current buffer, or the last one that was a file while a tree, picker or popup has
-- focus (their buffers are unlisted scratch ones with internal filetypes).
local subject = {}
local function describes(buf)
  local bt = vim.bo[buf].buftype
  return bt == "" or bt == "help" or vim.bo[buf].buflisted
end
local function subject_now()
  local buf = vim.api.nvim_get_current_buf()
  if describes(buf) or not (subject.buf and vim.api.nvim_buf_is_valid(subject.buf)) then
    subject.buf, subject.win, subject.live = buf, vim.api.nvim_get_current_win(), true
  else
    subject.live = false
  end
  return subject
end

local PAD = " "
local focused = true

-- A tab without its cursor position, so moving the cursor rebuilds nothing.
local function buf_label(buf, index, name, is_current)
  local current = is_current and focused and subject.live
  local base = "%#" .. (not focused and (is_current and "AosTabIdleSel" or "AosTabIdle")
    or current and "TabLineSel" or is_current and "AosTabIdleSel" or "TabLine") .. "#"
  -- Other tabs stay dim; only the modified mark and diagnostics keep their colour there.
  local function paint(group, text, keep)
    if not focused or not (current or keep) then return text end
    return "%#" .. on_surface(group, current and "TabLineSel") .. "#" .. text .. base
  end
  local mark = require("agent.review").pending(buf) > 0 and g.attention .. " " or ""
  local terminal = vim.bo[buf].buftype == "terminal"
  local icon, icon_hl = icons.get_icon(terminal and "terminal" or name:match("[^/]*$"), nil, { default = true })
  if name == "" then name = "[No Name]" end
  if #name > 28 then name = "…" .. name:sub(-27) end
  local dir, file = name:match("^(.*/)([^/]*)$")
  local label = paint(icon_hl, icon) .. " " .. (dir and paint("AosDim", esc(dir)) .. esc(file) or esc(name))
  if vim.bo[buf].modified then label = label .. " " .. paint("AosRunning", "+", true) end
  if not terminal and (vim.bo[buf].readonly or not vim.bo[buf].modifiable) then label = label .. " " .. paint("AosDim", lock) end
  local counts = vim.diagnostic.count(buf)
  if (counts[1] or 0) > 0 then label = label .. " " .. paint("AosFailed", g.failed .. counts[1], true) end
  if (counts[2] or 0) > 0 then label = label .. " " .. paint("AosRunning", g.attention .. counts[2], true) end
  local head = (current and "%#AosTabMark#● " .. base or "") .. ("%s%d:"):format(mark, index)
  return ("%%%d@v:lua.AosTabClick@%s%s%s%s"):format(buf, base, PAD, head, label)
end

-- Labels and their widths are kept per buffer until something they show changes (measuring one costs more than
-- building it); the render runs on every cursor move.
local cache = {}
local function tab(buf, index, name, is_current)
  local bo, counts = vim.bo[buf], vim.diagnostic.count(buf)
  local key = table.concat({
    index, name, is_current and (subject.live and 2 or 1) or 0, focused and 1 or 0, bo.modified and 1 or 0, (bo.readonly or not bo.modifiable) and 1 or 0,
    bo.buftype, counts[1] or 0, counts[2] or 0, require("agent.review").pending(buf),
  }, "\1")
  local c = cache[buf]
  if not c or c.key ~= key then
    local text = buf_label(buf, index, name, is_current)
    c = { key = key, text = text, width = vim.api.nvim_eval_statusline(text .. PAD, { use_tabline = true }).width }
    cache[buf] = c
  end
  if not (is_current and focused and subject.live) then return c.text .. PAD .. "%X", c.width end
  local pos = ("%d:%d"):format(vim.fn.line("."), vim.fn.charcol("."))
  return ("%s %%#%s#%s%%#TabLineSel#%s%%X"):format(c.text, on_surface("AosSha", "TabLineSel"), pos, PAD), c.width + 1 + #pos
end

local function tabs(room)
  local parts, widths, current = {}, {}, 1
  local bufs, here = M.listed(), subject.buf
  local names = unique_names(bufs)
  for i, buf in ipairs(bufs) do
    parts[i], widths[i] = tab(buf, i, names[buf], buf == here)
    if buf == here then current = i end
  end
  if #parts == 0 then return "" end
  room = room - 8 -- keep space for the ‹n / n› overflow markers
  local first, last, used = current, current, widths[current]
  while true do
    local grew = false
    if last < #parts and used + widths[last + 1] <= room then last, used, grew = last + 1, used + widths[last + 1], true end
    if first > 1 and used + widths[first - 1] <= room then first, used, grew = first - 1, used + widths[first - 1], true end
    if not grew then break end
  end
  local before = first > 1 and ("%%#AosDim#‹%d "):format(first - 1) or ""
  local after = last < #parts and (" %%#AosDim#%d›"):format(#parts - last) or ""
  return before .. table.concat(parts, "", first, last) .. "%#TabLineFill#" .. after
end

local modes = { i = "insert", v = "visual", V = "v-line", ["\22"] = "v-block", R = "replace", c = "command", t = "term" }

local function segment(hl, text) return ("%%#%s# %s %%#TabLineFill# "):format(hl, esc(text)) end

local function diagnostics(buf)
  local counts = vim.diagnostic.count(buf)
  local out = ""
  if (counts[1] or 0) > 0 then out = out .. ("%%#AosFailed#%s %d "):format(g.failed, counts[1]) end
  if (counts[2] or 0) > 0 then out = out .. ("%%#AosRunning#%s %d "):format(g.attention, counts[2]) end
  return out
end

-- Current file: filetype icon and name, attached language servers, and any non-default encoding/format.
local function file_info(buf)
  local bo = vim.bo[buf]
  local ft = bo.filetype
  if ft == "" then return "" end
  local icon, hl = icons.get_icon_by_filetype(ft, { default = true })
  local clients = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({ bufnr = buf }))
  clients = vim.tbl_filter(function(n) return n ~= "copilot" end, clients)
  local out = ("%%#%s#%s %%#AosDim#%s"):format(hl, icon, esc(ft))
  if #clients > 0 then out = out .. "%#AosFaint# · %#AosId#" .. esc(table.concat(clients, ",")) end
  if vim.b[buf].lsp_off then out = out .. "%#AosFaint# · lsp off" end
  local enc = bo.fileencoding
  if (enc ~= "" and enc ~= "utf-8") or bo.fileformat ~= "unix" then
    out = out .. "%#AosFaint# · %#AosRunning#" .. esc(enc) .. (bo.fileformat ~= "unix" and " " .. bo.fileformat or "")
  end
  return out .. " "
end

local status_key, status_width

function M.render()
  local right = {}
  local mode = modes[vim.fn.mode():sub(1, 1)]
  if mode then right[#right + 1] = segment("AosSegYellow", mode) end
  local sub = subject_now()
  local file = describes(sub.buf)
  if file then
    right[#right + 1] = file_info(sub.buf)
    right[#right + 1] = diagnostics(sub.buf)
  end
  local ai = require("core.complete").segment()
  if ai then right[#right + 1] = segment(ai.hl, ai.text) end
  for _, seg in ipairs(require("agent").segments()) do right[#right + 1] = segment(seg.hl, seg.text) end
  local branch = require("git.signs").status_text()
  if branch then right[#right + 1] = "%@v:lua.AosGitBranchClick@" .. segment("AosSegBlue", branch) .. "%X" end
  if file and vim.api.nvim_win_is_valid(sub.win) and vim.api.nvim_win_get_buf(sub.win) == sub.buf then
    local total = vim.api.nvim_buf_line_count(sub.buf)
    right[#right + 1] = segment("AosSegMagenta", ("%dL %d%%"):format(total, math.floor(vim.api.nvim_win_get_cursor(sub.win)[1] * 100 / total)))
  end
  local status = table.concat(right)
  if status ~= status_key then status_key, status_width = status, vim.api.nvim_eval_statusline(status, { use_tabline = true }).width end
  local room = vim.o.columns - status_width - 2
  return "%#TabLineFill# " .. tabs(room) .. "%#TabLineFill#%=" .. status
end

function _G.AosTabClick(buf) vim.api.nvim_set_current_buf(buf) end

function M.go(n)
  local buf = M.listed()[n < 0 and #M.listed() or n]
  if buf then vim.api.nvim_set_current_buf(buf) end
end

function M.close_side(side)
  local bufs, cur = M.listed(), vim.api.nvim_get_current_buf()
  local idx = vim.fn.index(bufs, cur) + 1
  for i, b in ipairs(bufs) do
    if (side == "left" and i < idx) or (side == "right" and i > idx) then pcall(vim.api.nvim_buf_delete, b, {}) end
  end
end

vim.o.tabline = "%!v:lua.require'ui.tabline'.render()"
local group = vim.api.nvim_create_augroup("AosTabline", {})
vim.api.nvim_create_autocmd({ "ModeChanged", "DiagnosticChanged", "BufModifiedSet", "LspAttach", "LspDetach", "FileType", "CursorMoved", "CursorMovedI" }, {
  group = group,
  -- Not while starting: the first paint draws it anyway.
  callback = function() if vim.v.vim_did_enter == 1 then vim.cmd.redrawtabline() end end,
})
vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev) cache[ev.buf] = nil end })
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = { "readonly", "modifiable", "fileformat", "fileencoding" },
  callback = function() vim.cmd.redrawtabline() end,
})
vim.api.nvim_create_autocmd({ "FocusGained", "FocusLost" }, {
  group = group,
  callback = function(ev)
    focused = ev.event == "FocusGained"
    vim.cmd.redrawtabline()
  end,
})
-- WezTerm can drop a FocusGained (e.g. after a tab switch); a typed key means the pane has focus. Only real input:
-- CursorMoved/TextChanged/WinEnter also fire from timers, reloads and floats in an unfocused pane.
local not_typed = {}
for _, k in ipairs({ "<FocusGained>", "<FocusLost>", "<CursorHold>", "<Ignore>", "<MouseMove>" }) do not_typed[vim.keycode(k)] = true end
vim.on_key(function(_, typed)
  if focused or not typed or typed == "" or not_typed[typed] then return end
  focused = true
  vim.schedule(vim.cmd.redrawtabline)
end, vim.api.nvim_create_namespace("ui.tabline.focus"))
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() derived, cache = {}, {} end })

return M
