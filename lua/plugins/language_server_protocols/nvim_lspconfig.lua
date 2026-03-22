return {
  "neovim/nvim-lspconfig", -- https://github.com/neovim/nvim-lspconfig
  config = function()
    -- on_attach: keymaps and features enabled per-buffer when LSP attaches
    local on_attach = function(client, bufnr)
      -- Enable semantic tokens if supported
      if client.server_capabilities.semanticTokensProvider then
        vim.lsp.semantic_tokens.start(bufnr, client.id)
      end

      -- Native document highlights (replaces vim-illuminate)
      if client.server_capabilities.documentHighlightProvider then
        local hl_group = vim.api.nvim_create_augroup("lsp-highlight-" .. bufnr, { clear = true })
        vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
          buffer = bufnr,
          group = hl_group,
          callback = vim.lsp.buf.document_highlight,
        })
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
          buffer = bufnr,
          group = hl_group,
          callback = vim.lsp.buf.clear_references,
        })
      end
    end

    -- blink.cmp auto-injects capabilities into all LSP servers

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
    })

    -- html & css & Tailwindcss
    vim.lsp.config("emmet_ls", {
      on_attach = on_attach,
      filetypes = { "html", "htmldjango", "typescriptreact", "javascriptreact", "css", "sass", "scss", "less" },
      init_options = {
        html = {
          options = {
            ["bem.enabled"] = true,
            ["jsx.enabled"] = true,
          },
        },
      },
    })

    vim.lsp.config("tailwindcss", { on_attach = on_attach })
    vim.lsp.config("svelte", { on_attach = on_attach })
    vim.lsp.config("jsonls", { on_attach = on_attach })
    vim.lsp.config("html", { on_attach = on_attach })
    vim.lsp.config("cssls", { on_attach = on_attach })
    vim.lsp.config("ruff", { on_attach = on_attach })

    -- Solidity (Nomicfoundation)
    vim.lsp.config("solidity_ls_nomicfoundation", {
      cmd = { "nomicfoundation-solidity-language-server", "--stdio" },
      filetypes = { "solidity" },
      root_markers = { "hardhat.config.js", "hardhat.config.ts", "foundry.toml", ".git" },
      on_attach = on_attach,
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

    vim.diagnostic.config({
      underline = true,
      virtual_text = { spacing = 4, prefix = "" },
      severity_sort = true,
      float = {
        source = "if_many",
      },
      signs = {
        text = {
          [vim.diagnostic.severity.ERROR] = "",
          [vim.diagnostic.severity.WARN] = "",
          [vim.diagnostic.severity.HINT] = "💡",
          [vim.diagnostic.severity.INFO] = "",
        },
      },
    })
  end,
}
