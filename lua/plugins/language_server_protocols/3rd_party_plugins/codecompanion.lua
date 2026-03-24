return {
  "olimorris/codecompanion.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "ravitemer/mcphub.nvim",
  },
  cmd = { "CodeCompanionChat", "CodeCompanion", "CodeCompanionCmd" },
  keys = {
    { "<leader>cc", "<cmd>CodeCompanionChat Toggle<cr>", mode = { "n", "v" }, desc = "Toggle chat" },
    { "<leader>ci", "<cmd>CodeCompanion<cr>", mode = { "n", "v" }, desc = "Inline assist" },
    { "<leader>cp", "<cmd>CodeCompanionCmd<cr>", desc = "Command prompt" },
  },
  opts = {
    adapters = {
      gemini = function()
        return require("codecompanion.adapters").extend("gemini", {
          schema = {
            model = { default = "gemini-2.5-flash-preview-05-20" },
          },
        })
      end,
    },
    strategies = {
      chat = { adapter = "gemini" },
      inline = { adapter = "gemini" },
    },
    extensions = {
      mcphub = {
        callback = "mcphub.extensions.codecompanion",
        opts = {
          make_tools = true,
          show_server_tools_in_chat = true,
          make_vars = true,
          make_slash_commands = true,
        },
      },
    },
  },
}
