return {
  "supermaven-inc/supermaven-nvim",
  event = "InsertEnter",
  config = function()
    require("supermaven-nvim").setup({
      -- Tab is owned by blink.cmp's smart <Tab>, which accepts the inline
      -- suggestion via the Supermaven API when no completion menu is open.
      disable_keymaps = true,
      ignore_filetypes = {},
      color = {
        suggestion_color = "#585858",
      },
      log_level = "off",
    })

    -- Keep the non-Tab inline-accept helpers.
    local preview = require("supermaven-nvim.completion_preview")
    vim.keymap.set("i", "<C-j>", preview.on_accept_suggestion_word, { desc = "Supermaven accept word" })
    vim.keymap.set("i", "<C-]>", preview.on_dispose_inlay, { desc = "Supermaven clear suggestion" })
  end,
}
