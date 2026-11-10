-- Float terminal toggle (replaces toggleterm).
local M = {}
local state = { buf = nil, win = nil }

M.keys = {
  {
    section = "Terminal",
    keys = {
      { "<M-->", "hide / show the float (the shell keeps running)", "n t" },
      { "<Esc><leader>", "leave terminal mode", "t" },
    },
  },
}

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_hide(state.win)
    state.win = nil
    return
  end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then state.buf = vim.api.nvim_create_buf(false, true) end
  local w, h = math.floor(vim.o.columns * 0.85), math.floor(vim.o.lines * 0.8)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor", width = w, height = h, row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    title = " ❯ " .. vim.fn.fnamemodify(vim.o.shell, ":t") .. " ", title_pos = "left",
  })
  vim.wo[state.win].number, vim.wo[state.win].relativenumber, vim.wo[state.win].signcolumn = false, false, "no"
  if vim.bo[state.buf].buftype ~= "terminal" then
    vim.fn.jobstart({ vim.o.shell }, { term = true, on_exit = function() state.buf = nil end })
  end
  vim.cmd.startinsert()
end

return M
