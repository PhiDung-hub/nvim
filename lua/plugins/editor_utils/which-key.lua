return {
  "folke/which-key.nvim", -- manage hotkey
  event = "VeryLazy",
  opts = {
    -- disable the WhichKey popup for certain buf types and file types.
    -- Disabled by deafult for Telescope
    disable = {
      buftypes = {},
      filetypes = { "TelescopePrompt" },
    },
  },
}
