return {
  "akinsho/git-conflict.nvim",
  version = "*",
  config = function()
    require("git-conflict").setup {
      default_mappings = true,     -- enables co/ct/cb/c0
      default_commands = true,     -- enables :GitConflictChooseOurs, etc.
      disable_diagnostics = false, -- keep diagnostics during conflicts
      list_opener = "copen",       -- opens conflicts in quickfix list if you want
      highlights = {
        incoming = "DiffAdd",      -- theirs
        current  = "DiffText",     -- ours
      },
    }

    -- extra keymaps for navigation and listing conflicts
    vim.keymap.set("n", "<leader>gx", "<cmd>GitConflictListQf<CR>",
      { desc = "List git conflicts in quickfix" })
    vim.keymap.set("n", "]x", "<cmd>GitConflictNextConflict<CR>",
      { desc = "Next conflict" })
    vim.keymap.set("n", "[x", "<cmd>GitConflictPrevConflict<CR>",
      { desc = "Prev conflict" })
  end
}

