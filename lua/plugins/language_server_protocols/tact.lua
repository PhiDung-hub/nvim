return {
  "tact-lang/tact.vim",
  ft = "tact",
  init = function()
    vim.g.tact_prefer_completefunc = 1
    vim.g.tact_style_guide = 1
    vim.g.tact_blank_identifiers = 0
  end,
  config = function()
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "tact",
      callback = function()
        vim.keymap.set("n", "<leader>f", ":TactFmt<CR>", { noremap = true, silent = true, buffer = true })
        vim.keymap.set("n", "<leader>cc", ":TactFmt<CR>", { noremap = true, silent = true, buffer = true })
      end,
    })
  end,
}
