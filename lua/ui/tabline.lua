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

-- Inactive tabs sit on TabLine's surface, so accent colours are re-derived onto that background.
local derived = {}
local function on_surface(group, bold)
  local name = "AosTab" .. group .. (bold and "Bold" or "")
  if derived[name] then return name end
  local bg = vim.api.nvim_get_hl(0, { name = "TabLine", link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = vim.api.nvim_get_hl(0, { name = group, link = false }).fg, bg = bg, bold = bold })
  derived[name] = true
  return name
end

local function tail(path, depth)
  local parts = vim.split(path, "/", { trimempty = true })
  return table.concat(parts, "/", math.max(1, #parts - depth))
end

-- File names, widened with parent directories until no two tabs share one.
local function unique_names(bufs)
  local depth, names = {}, {}
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

local function buf_label(buf, index, name)
  local current = buf == vim.api.nvim_get_current_buf()
  local base = "%#" .. (current and on_surface("Normal", true) or "TabLine") .. "#"
  local function paint(group, text) return "%#" .. on_surface(group) .. "#" .. text .. base end
  local mark = require("agent.review").pending(buf) > 0 and g.attention or current and g.reply or g.todo
  local chip = current and ("%%#TabLineSel# %s %d %s "):format(mark, index, base) or ("%s %s %d:"):format(base, mark, index)
  local terminal = vim.bo[buf].buftype == "terminal"
  local icon, icon_hl = icons.get_icon(terminal and "terminal" or name:match("[^/]*$"), nil, { default = true })
  if name == "" then name = "[No Name]" end
  if #name > 28 then name = "…" .. name:sub(-27) end
  local dir, file = name:match("^(.*/)([^/]*)$")
  local label = paint(icon_hl, icon) .. " " .. (dir and paint("AosDim", esc(dir)) .. esc(file) or esc(name))
  if vim.bo[buf].modified then label = label .. " " .. paint("AosRunning", "+") end
  if not terminal and (vim.bo[buf].readonly or not vim.bo[buf].modifiable) then label = label .. " " .. paint("AosDim", lock) end
  local counts = vim.diagnostic.count(buf)
  if (counts[1] or 0) > 0 then label = label .. " " .. paint("AosFailed", g.failed .. counts[1]) end
  if (counts[2] or 0) > 0 then label = label .. " " .. paint("AosRunning", g.attention .. counts[2]) end
  if current then label = label .. " " .. paint("Statement", ("%d:%d"):format(vim.fn.line("."), vim.fn.charcol("."))) end
  return ("%%%d@v:lua.AosTabClick@%s%s %%X"):format(buf, chip, label), current
end

local function tabs(room)
  local parts, widths, current = {}, {}, 1
  local bufs = M.listed()
  local names = unique_names(bufs)
  for i, buf in ipairs(bufs) do
    local text, is_current = buf_label(buf, i, names[buf])
    parts[#parts + 1] = text
    widths[#widths + 1] = vim.api.nvim_eval_statusline(text, { use_tabline = true }).width
    if is_current then current = i end
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
  return before .. table.concat(parts, "%#TabLineFill# ", first, last) .. after
end

local modes = { i = "insert", v = "visual", V = "v-line", ["\22"] = "v-block", R = "replace", c = "command", t = "term" }

local function segment(hl, text) return ("%%#%s# %s %%#TabLineFill# "):format(hl, esc(text)) end

local function diagnostics()
  local counts = vim.diagnostic.count(0)
  local out = ""
  if (counts[1] or 0) > 0 then out = out .. ("%%#AosFailed#%s %d "):format(g.failed, counts[1]) end
  if (counts[2] or 0) > 0 then out = out .. ("%%#AosRunning#%s %d "):format(g.attention, counts[2]) end
  return out
end

-- Current file: filetype icon and name, attached language servers, and any non-default encoding/format.
local function file_info()
  local ft = vim.bo.filetype
  if ft == "" then return "" end
  local icon, hl = icons.get_icon_by_filetype(ft, { default = true })
  local clients = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({ bufnr = 0 }))
  clients = vim.tbl_filter(function(n) return n ~= "copilot" end, clients)
  local out = ("%%#%s#%s %%#AosDim#%s"):format(hl, icon, esc(ft))
  if #clients > 0 then out = out .. "%#AosFaint# · %#AosId#" .. esc(table.concat(clients, ",")) end
  if vim.b.lsp_off then out = out .. "%#AosFaint# · lsp off" end
  local enc = vim.bo.fileencoding
  if (enc ~= "" and enc ~= "utf-8") or vim.bo.fileformat ~= "unix" then
    out = out .. "%#AosFaint# · %#AosRunning#" .. esc(enc) .. (vim.bo.fileformat ~= "unix" and " " .. vim.bo.fileformat or "")
  end
  return out .. " "
end

function M.render()
  local right = {}
  local mode = modes[vim.fn.mode():sub(1, 1)]
  if mode then right[#right + 1] = segment("AosSegYellow", mode) end
  right[#right + 1] = file_info()
  right[#right + 1] = diagnostics()
  local ai = require("core.complete").segment()
  if ai then right[#right + 1] = segment(ai.hl, ai.text) end
  for _, seg in ipairs(require("agent").segments()) do right[#right + 1] = segment(seg.hl, seg.text) end
  local branch = require("core.git").status_text()
  if branch then right[#right + 1] = segment("AosSegBlue", branch) end
  right[#right + 1] = segment("AosSegMagenta", ("%dL %d%%"):format(vim.fn.line("$"), math.floor(vim.fn.line(".") * 100 / vim.fn.line("$"))))
  local status = table.concat(right)
  local room = vim.o.columns - vim.api.nvim_eval_statusline(status, { use_tabline = true }).width - 2
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
  callback = function() vim.cmd.redrawtabline() end,
})
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = { "readonly", "modifiable", "fileformat", "fileencoding" },
  callback = function() vim.cmd.redrawtabline() end,
})
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() derived = {} end })

return M
