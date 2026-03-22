return {
  "lukas-reineke/indent-blankline.nvim",
  main = "ibl",
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    indent = {
      char = "▏",
      tab_char = "▏",
      smart_indent_cap = true,
      priority = 1,
    },
  },
}
