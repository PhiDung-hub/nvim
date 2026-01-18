return {
  "nvimtools/none-ls.nvim", -- Use Neovim as a language server to inject LSP diagnostics, code actions, and more via Lua.
  dependencies = {
    "nvim-lua/plenary.nvim",
    "jay-babu/mason-null-ls.nvim",
  },
  config = function()
    local status, null_ls = pcall(require, "null-ls")
    if not status then
      print("WARNING: null-ls is unavailable")
      return
    end

    local formatting = null_ls.builtins.formatting

    -- Set up mason-null-ls to ensure formatter/linter tools are installed
    require("mason-null-ls").setup({
      ensure_installed = {
        "stylua",
        "prettierd",
      },
      automatic_installation = true,
    })

    null_ls.setup({
      debug = false,
      autostart = true,
      sources = {
        -- Lua (for nvim config editing)
        formatting.stylua,

        -- JS, JSX, TSX, etc.
        formatting.prettierd,
      },
    })
  end,
}
