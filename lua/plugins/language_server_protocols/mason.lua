return {
  "williamboman/mason.nvim", -- LSP/DAP/Linters/Formatters installer
  dependencies = {
    "williamboman/mason-lspconfig.nvim", -- Bridge Mason <-> nvim-lspconfig
  },
  config = function()
    local mason_ok, mason = pcall(require, "mason")
    if not mason_ok then
      vim.notify("WARNING: mason is unavailable", vim.log.levels.WARN)
      return
    end

    local mlsp_ok, mason_lspconfig = pcall(require, "mason-lspconfig")
    if not mlsp_ok then
      vim.notify("WARNING: mason-lspconfig is unavailable", vim.log.levels.WARN)
      return
    end

    -- Install these LSP servers; setup is handled in nvim_lspconfig.lua
    local servers = {
      -- web
      "cssls",
      "html",
      "jsonls",
      "ts_ls",
      "tailwindcss",
      "svelte",
      "emmet_ls",
      "yamlls",

      -- languages / tools
      "bashls",
      "clangd",
      "rust_analyzer",
      "gopls",
      "taplo",
      "prismals",
      "lua_ls",
      "sqlls",
      "ruff",

      -- solidity
      "solidity_ls_nomicfoundation",
    }

    mason.setup({})
    mason_lspconfig.setup({
      ensure_installed = servers,
      automatic_installation = true,
      -- Explicitly disable automatic setup and handlers
      automatic_enable = {
        exclude = { "rust_analyzer", "ts_ls" },
      },
    })
  end,
}
