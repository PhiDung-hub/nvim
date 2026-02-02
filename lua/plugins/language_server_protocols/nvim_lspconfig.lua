return {
  "neovim/nvim-lspconfig", -- https://github.com/neovim/nvim-lspconfig
  dependencies = {
    "hrsh7th/cmp-nvim-lsp", -- nvim-cmp source for neovim's built-in LSP.
  },
  config = function()
    local cmp_nvim_lsp_ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
    if not cmp_nvim_lsp_ok then
      print("WARNING: cmp_nvim_lsp is unavailable")
      return
    end

    -- Use an on_attach function to only map the following keys
    -- after the language server attaches to the current buffer
    local on_attach = function(_, bufnr)
      -- Mappings.
      local opts = { noremap = true, silent = true, buffer = bufnr }

      vim.keymap.set("n", "<leader>f", function()
        vim.lsp.buf.format({ async = true })
      end, opts)
    end

    -- Set up completion using nvim_cmp with LSP source
    local capabilities = cmp_nvim_lsp.default_capabilities()

    -- jsx/tsx/react
    vim.lsp.config("ts_ls", {
      on_attach = function(client, bufnr)
        client.server_capabilities.documentFormattingProvider = false
        on_attach(client, bufnr)
      end,
      filetypes = {
        "javascript",
        "javascriptreact",
        "javascript.jsx",
        "typescript",
        "typescriptreact",
        "typescript.tsx",
      },
      capabilities = capabilities,
    })

    -- html & css & Tailwindcss
    vim.lsp.config("emmet_ls", {
      on_attach = on_attach,
      capabilities = capabilities,
      filetypes = { "html", "htmldjango", "typescriptreact", "javascriptreact", "css", "sass", "scss", "less" },
      init_options = {
        html = {
          options = {
            -- For possible options, see: https://github.com/emmetio/emmet/blob/master/src/config.ts#L79-L284
            ["bem.enabled"] = true,
            ["jsx.enabled"] = true,
          },
        },
      },
    })
    -- tailwind
    vim.lsp.config("tailwindcss", {
      on_attach = on_attach,
      capabilities = capabilities,
    })
    -- svelte
    vim.lsp.config("svelte", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- JSON (useful for package.json, tsconfig, etc.)
    vim.lsp.config("jsonls", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- HTML
    vim.lsp.config("html", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- CSS
    vim.lsp.config("cssls", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- Python
    vim.lsp.config("ruff", {
      capabilities = capabilities,
      on_attach = on_attach,
    })

    -- Solidity (Nomicfoundation)
    vim.lsp.config("solidity_ls_nomicfoundation", {
      cmd = { "nomicfoundation-solidity-language-server", "--stdio" },
      filetypes = { "solidity" },
      root_markers = { "hardhat.config.js", "hardhat.config.ts", "foundry.toml", ".git" },
      on_attach = on_attach,
      capabilities = capabilities,
    })
    vim.lsp.enable("solidity_ls_nomicfoundation")
    vim.lsp.enable("ts_ls")
    vim.lsp.enable("emmet_ls")
    vim.lsp.enable("tailwindcss")
    vim.lsp.enable("svelte")
    vim.lsp.enable("jsonls")
    vim.lsp.enable("html")
    vim.lsp.enable("cssls")
    vim.lsp.enable("ruff")

    vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(vim.lsp.diagnostic.on_publish_diagnostics, {
      underline = true,
      virtual_text = { spacing = 4, prefix = "" },
      severity_sort = true,
    })

    -- Diagnostic symbols in the sign column (gutter)
    local signs = { Error = "", Warn = "", Hint = "💡", Info = "" }
    for type, icon in pairs(signs) do
      local hl = "DiagnosticSign" .. type
      -- Link the highlight group to the corresponding Diagnostic highlight
      vim.api.nvim_set_hl(0, hl, { link = "Diagnostic" .. type })

      -- Define the sign safely
      -- WARN: Migrated to neovim 0.11+
      if vim.api.nvim_set_sign then
        vim.api.nvim_set_sign(hl, {
          text = icon,
          texthl = hl,
          numhl = "",
        })
      end
    end

    vim.diagnostic.config({
      float = {
        source = "if_many", -- Or "if_many"
      },
    })
  end,
}
