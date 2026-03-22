return {
  "https://github.com/NvChad/nvim-colorizer.lua",
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    filetypes = { "*" },
    user_default_options = {
      RGB = true,
      RRGGBB = true,
      names = false,
      RRGGBBAA = false,
      AARRGGBB = false,
      rgb_fn = true,
      hsl_fn = true,
      css = true,
      css_fn = true,
      mode = "background",
      tailwind = "both",
      sass = { enable = "both", parsers = { "css" } },
      virtualtext = "■",
    },
    buftypes = {},
  },
}
