return {
  "folke/zen-mode.nvim",
  keys = {
    { "<C-M-O>", "<cmd>ZenMode<cr>", desc = "Zen Mode", silent = true },
  },
  opts = {
    window = {
      backdrop = 0.9,
      width = 153,
      height = 1,
    },
    plugins = {
      options = { enabled = true, ruler = true, showcmd = false },
      twilight = { enabled = false },
      gitsigns = { enabled = false },
      tmux = { enabled = false },
    },
  },
}
