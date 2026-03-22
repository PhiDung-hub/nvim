return {
  "rebelot/kanagawa.nvim",
  priority = 1000,
  config = function()
    require("kanagawa").setup({
      compile = false,
      undercurl = false,
      commentStyle = { italic = false },
      functionStyle = { italic = false },
      keywordStyle = { italic = false },
      statementStyle = { bold = true, italic = false },
      variablebuiltinStyle = { italic = false },
      typeStyle = { italic = false },
      transparent = false,
      dimInactive = false,
      terminalColors = true,
      colors = {
        palette = {},
        theme = { wave = {}, lotus = {}, dragon = {}, all = {} },
      },
      overrides = function(colors)
        local theme = colors.theme
        return {
          Pmenu = { fg = theme.ui.shade0, bg = theme.ui.bg_p1 },
          PmenuSel = { fg = "NONE", bg = theme.ui.bg_p2 },
          PmenuSbar = { bg = theme.ui.bg_m1 },
          PmenuThumb = { bg = theme.ui.bg_p2 },
          Italic = { italic = false },
          Special = { italic = false },
        }
      end,
      theme = "wave",
      background = { dark = "wave", light = "lotus" },
    })

    vim.cmd.colorscheme("kanagawa")

    local palette = require("kanagawa.colors").setup().palette
    local bg_default = palette.sumiInk3
    local bg_lighter = palette.sumiInk4
    local bg_darker = palette.sumiInk2

    vim.api.nvim_set_hl(0, "LineNR", { fg = palette.dragonBlue, bg = bg_default })
    vim.api.nvim_set_hl(0, "CursorLineNR", { fg = palette.roninYellow, bg = bg_default, bold = true })
    vim.api.nvim_set_hl(0, "SignColumn", { bg = bg_default })
    vim.api.nvim_set_hl(0, "DiffviewSignColumn", { bg = bg_default })
    vim.api.nvim_set_hl(0, "ColorColumn", { bg = bg_default })
    vim.api.nvim_set_hl(0, "GitSignsDelete", { fg = palette.autumnRed, bg = bg_default })
    vim.api.nvim_set_hl(0, "GitSignsChange", { fg = palette.autumnYellow, bg = bg_default })
    vim.api.nvim_set_hl(0, "GitSignsAdd", { fg = palette.autumnGreen, bg = bg_default })
    vim.api.nvim_set_hl(0, "SagaBorder", { fg = bg_lighter, bg = bg_darker })
    vim.api.nvim_set_hl(0, "SagaNormal", { bg = bg_darker })
  end,
}
