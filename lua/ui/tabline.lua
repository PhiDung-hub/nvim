-- One top bar like the WezTerm tab bar: listed buffers left (` ● 1:name `), status segments right.
local M = {}
local g = require("design").glyphs

local function esc(s) return (s:gsub("%%", "%%%%")) end

function M.listed()
  return vim.tbl_filter(function(b) return vim.bo[b].buflisted end, vim.api.nvim_list_bufs())
end

local function buf_label(buf, index)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if name == "" then name = "[No Name]" end
  if #name > 24 then name = name:sub(1, 23) .. "…" end
  local current = buf == vim.api.nvim_get_current_buf()
  local mark = require("agent.review").pending(buf) > 0 and g.attention or current and g.reply or g.todo
  if vim.bo[buf].modified then name = name .. " +" end
  local hl = current and "%#TabLineSel#" or "%#TabLine#"
  return ("%%%d@v:lua.AosTabClick@%s %s %d:%s %%X"):format(buf, hl, mark, index, esc(name)), current
end

local function tabs(room)
  local parts, widths, current = {}, {}, 1
  for i, buf in ipairs(M.listed()) do
    local text, is_current = buf_label(buf, i)
    parts[#parts + 1] = text
    widths[#widths + 1] = vim.api.nvim_eval_statusline(text, { use_tabline = true }).width
    if is_current then current = i end
  end
  if #parts == 0 then return "" end
  local first, last, used = current, current, widths[current]
  while true do
    local grew = false
    if last < #parts and used + widths[last + 1] <= room then last, used, grew = last + 1, used + widths[last + 1], true end
    if first > 1 and used + widths[first - 1] <= room then first, used, grew = first - 1, used + widths[first - 1], true end
    if not grew then break end
  end
  return table.concat(parts, "%#TabLineFill# ", first, last)
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

function M.render()
  local right = {}
  local mode = modes[vim.fn.mode():sub(1, 1)]
  if mode then right[#right + 1] = segment("AosSegYellow", mode) end
  right[#right + 1] = diagnostics()
  local ai = require("core.complete").segment()
  if ai then right[#right + 1] = segment(ai.hl, ai.text) end
  for _, seg in ipairs(require("agent").segments()) do right[#right + 1] = segment(seg.hl, seg.text) end
  local branch = require("core.git").branch()
  if branch then right[#right + 1] = segment("AosSegBlue", branch) end
  right[#right + 1] = segment("AosSegMagenta", ("%d:%d"):format(vim.fn.line("."), vim.fn.col(".")))
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
vim.api.nvim_create_autocmd({ "ModeChanged", "DiagnosticChanged", "BufModifiedSet" }, {
  group = vim.api.nvim_create_augroup("AosTabline", {}),
  callback = function() vim.cmd.redrawtabline() end,
})

return M
