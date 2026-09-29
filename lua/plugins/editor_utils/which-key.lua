return {
  "folke/which-key.nvim", -- manage hotkey
  event = "VeryLazy",
  -- v3 API: disable.ft (the old disable.filetypes key is ignored)
  opts = {
    disable = { ft = { "TelescopePrompt", "fff_input" } },
  },
}
