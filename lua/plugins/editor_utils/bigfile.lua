return {
  "LunarVim/bigfile.nvim",
  event = "BufReadPre",
  -- Above the threshold (MiB) it disables treesitter, LSP, syntax,
  -- matchparen, indent guides, and sets foldmethod=manual / no swap.
  opts = { filesize = 1.5 },
}
