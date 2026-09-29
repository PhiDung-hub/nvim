-- Neovim only notices external edits when it checks a file's timestamp.
-- Poll the active file so edits made by another process appear while focused.
local group = vim.api.nvim_create_augroup("CheckExternalChanges", { clear = true })

local function check_current_file()
  if vim.fn.mode():sub(1, 1) == "c" then return end

  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then return end
  if vim.api.nvim_buf_get_name(buf) == "" then return end

  -- autoread reloads only unchanged buffers; modified buffers keep their edits
  -- and receive Neovim's normal external-change warning.
  vim.api.nvim_cmd({ cmd = "checktime", args = { tostring(buf) } }, {})
end

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "TermLeave" }, {
  group = group,
  callback = function() vim.schedule(check_current_file) end,
})

vim.fn.timer_start(1000, function()
  check_current_file()
end, { ["repeat"] = -1 })
