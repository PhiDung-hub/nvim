return {
  -- copilot
  "zbirenbaum/copilot.lua",
  cmd = "Copilot",
  enabled = false,
  build = ":Copilot auth",
  dependencies = {
    {
      "zbirenbaum/copilot-cmp",
      opts = {},
      config = function()
        require("copilot_cmp").setup()
      end,
    },
  },
  opts = {
    suggestion = { enabled = false },
    panel = { enabled = false },
  },
}
