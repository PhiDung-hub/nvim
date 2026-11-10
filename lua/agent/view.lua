-- Live view of the attached agent's screen in a right split, so replies to /btw and
-- task progress read inside nvim. Polls only while the split is visible.
local M = {}
local transport = require("agent.transport")
local state = { buf = nil, timer = nil }
local INTERVAL = 700

local function paint(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax match AosPrompt /^\s*[❯>].*/
      syntax match AosDim /^\s*⎿.*/
      syntax match AosSha /^\s*●/
      syntax match AosRunning /^\s*[✳◐◑◒◓].*/
      syntax match AosFailed /^\s*✗.*/
      syntax match AosDone /^\s*✓.*/
    ]])
  end)
end

local function visible() return state.buf and vim.api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 end

local function stop()
  if state.timer then state.timer:stop() end
end

local function refresh(target)
  if not visible() then return stop() end
  transport.capture(target, function(lines)
    if not visible() then return end
    while #lines > 0 and vim.trim(lines[#lines]) == "" do table.remove(lines) end
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    local win = vim.fn.bufwinid(state.buf)
    if win ~= vim.api.nvim_get_current_win() then pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 }) end
  end)
end

function M.toggle(target)
  if target.chan then
    local win = vim.fn.bufwinid(target.buf)
    if win ~= -1 then return vim.api.nvim_win_hide(win) end
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, target.buf)
    return vim.cmd.wincmd("p")
  end
  if visible() then return vim.api.nvim_win_hide(vim.fn.bufwinid(state.buf)) end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.buf, "agent://view")
    vim.bo[state.buf].bufhidden = "hide"
    paint(state.buf)
  end
  vim.cmd("botright vsplit")
  vim.api.nvim_win_set_width(0, math.floor(vim.o.columns * 0.4))
  vim.api.nvim_win_set_buf(0, state.buf)
  vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.list, vim.wo.wrap = false, false, "no", false, true
  vim.wo.winbar = ("%%#AosPrompt# ❯ %%#AosArg#%s #%s%%#AosDim# · live view"):format(target.kind, target.pane)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = state.buf, nowait = true })
  vim.keymap.set("n", "i", function() transport.focus(target) end, { buffer = state.buf, desc = "Focus agent pane" })
  vim.cmd.wincmd("p")
  state.timer = state.timer or vim.uv.new_timer()
  state.timer:start(0, INTERVAL, vim.schedule_wrap(function() refresh(target) end))
end

return M
