return {
  "williamboman/mason.nvim", -- LSP manager.
  dependencies = {
    "williamboman/mason-lspconfig.nvim", -- mason config helpers.
  },
  config = function()
    local mason_ok, mason = pcall(require, "mason")
    if not mason_ok then
      print("WARNING: mason is unavailable")
      return
    end

    local mason_lspconfig_ok, mason_lspconfig = pcall(require, "mason-lspconfig")
    if not mason_lspconfig_ok then
      print("WARNING: mason_lspconfig is unavailable")
      return
    end

    -- Available server: https://github.com/williamboman/mason-lspconfig.nvim#available-lsp-servers
    -- With instruction for config: https://github.com/neovim/nvim-lspconfig/blob/master/doc/server_configurations.md
    local servers = {
      "cssls",
      "emmet_ls",
      "html",
      "jsonls",
      "solc",
      "ts_ls",
      "tailwindcss",
      "svelte",
      "yamlls",
      "ruff", -- linter + formatter
      "bashls",
      "clangd",
      "rust_analyzer",
      "taplo",
      "prismals",
      "lua_ls",
      "sqlls",
      "gopls",
    }

    mason.setup({})
    mason_lspconfig.setup({
      ensure_installed = servers,
      automatic_installation = true,
    })
  end,
}
