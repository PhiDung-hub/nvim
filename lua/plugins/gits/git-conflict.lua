return {
  "akinsho/git-conflict.nvim",
  version = "*",
  event = "BufReadPost",
  keys = {
    { "<leader>gx", "<cmd>GitConflictListQf<CR>", desc = "List git conflicts in quickfix" },
    { "]x", "<cmd>GitConflictNextConflict<CR>", desc = "Next conflict" },
    { "[x", "<cmd>GitConflictPrevConflict<CR>", desc = "Prev conflict" },
  },
  opts = {
    default_mappings = true,
    default_commands = true,
    disable_diagnostics = false,
    list_opener = "copen",
    highlights = { incoming = "DiffAdd", current = "DiffText" },
  },
}
