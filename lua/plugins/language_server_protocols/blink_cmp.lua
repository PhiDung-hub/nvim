return {
  "saghen/blink.cmp",
  version = "1.*",
  event = { "InsertEnter", "CmdlineEnter" },
  dependencies = {
    "rafamadriz/friendly-snippets",
  },
  opts = {
    keymap = {
      preset = "none",
      -- Tab accepts the highlighted item (or the first one if none is
      -- selected, applying any LSP auto-import edits). When the menu is
      -- closed it accepts the Supermaven inline suggestion instead, and
      -- otherwise falls back to a literal <Tab>.
      ["<Tab>"] = {
        function(cmp)
          if cmp.is_menu_visible() then
            return cmp.select_and_accept()
          end
          local ok, preview = pcall(require, "supermaven-nvim.completion_preview")
          if ok and preview.has_suggestion() then
            preview.on_accept_suggestion()
            return true
          end
        end,
        "fallback",
      },
      ["<Down>"] = { "select_next", "fallback" },
      ["<Up>"] = { "select_prev", "fallback" },
      ["<C-n>"] = { "select_next", "fallback" },
      ["<C-p>"] = { "select_prev", "fallback" },
      ["<CR>"] = { "accept", "fallback" },
      ["<C-e>"] = { "cancel", "fallback" },
      ["<C-b>"] = { "scroll_documentation_up", "fallback" },
      ["<C-f>"] = { "scroll_documentation_down", "fallback" },
    },
    sources = {
      default = { "lsp", "path", "snippets", "buffer" },
    },
    completion = {
      menu = {
        max_height = 10,
        draw = {
          columns = { { "kind_icon" }, { "label", "label_description", gap = 1 }, { "source_name" } },
        },
      },
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 200,
      },
      list = {
        selection = { preselect = false, auto_insert = false },
      },
    },
    signature = {
      enabled = true,
    },
    appearance = {
      nerd_font_variant = "mono",
    },
    cmdline = {
      enabled = true,
    },
  },
}
