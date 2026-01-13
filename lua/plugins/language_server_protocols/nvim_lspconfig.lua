return {
  "neovim/nvim-lspconfig", -- https://github.com/neovim/nvim-lspconfig
  dependencies = {
    "hrsh7th/cmp-nvim-lsp", -- nvim-cmp source for neovim's built-in LSP.
    "folke/neodev.nvim", -- signature help, docs and completion for the nvim lua API.
  },
  config = function()
    -- IMPORTANT: make sure to setup neodev BEFORE lspconfig
    local neodev_ok, neodev = pcall(require, "neodev")
    if neodev_ok then
      neodev.setup({})
    end

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

    -- GO
    vim.lsp.config("gopls", {
      settings = {
        gopls = {
          gofumpt = true,
        },
      },
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- RUST
    -- rustfmt formatting: https://rust-lang.github.io/rustfmt
    -- rust_analyzer config: https://github.com/rust-lang/rust-analyzer/blob/master/docs/user/generated_config.adoc
    vim.lsp.config("rust_analyzer", {
      on_attach = on_attach,
      capabilities = capabilities,
      settings = {
        ["rust-analyzer"] = {
          check = {
            command = "clippy",
          },
        },
      },
    })

    -- TOML
    vim.lsp.config("taplo", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- JSON
    vim.lsp.config("jsonls", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    -- cpp
    -- Create a shallow copy of capabilities for clangd
    local clangd_cap = vim.tbl_deep_extend("force", {}, capabilities, {
      offsetEncoding = { "utf-16" }, -- fix: use array as expected

      textDocument = { semanticHighlighting = true },
    })
    vim.lsp.config("clangd", {
      on_attach = on_attach,
      capabilities = clangd_cap,
      filetypes = { "c", "cpp", "objc", "objcpp", "cuda" },
      cmd = {
        "clangd",
        "--background-index",
        "--pch-storage=memory",
        "--clang-tidy",
        "--completion-style=detailed",
      },
    })

    -- Python
    vim.lsp.config("ruff", {
      capabilities = capabilities,
      on_attach = on_attach,
    })

    -- Solidity
    vim.lsp.config("solidity_ls_nomicfoundation", {
      capabilities = capabilities,
      on_attach = on_attach,
    })

    -- SQL
    vim.lsp.config("sqlls", {
      capabilities = capabilities,
      on_attach = on_attach,
    })

    vim.lsp.config("prismals", {
      capabilities = capabilities,
      on_attach = on_attach,
    })

    -- YAML
    vim.lsp.config("yamlls", {
      on_attach = on_attach,
      capabilities = capabilities,
    })

    local augroup_format = vim.api.nvim_create_augroup("Format", { clear = true })
    local enable_format_on_save = function(_, bufnr)
      vim.api.nvim_clear_autocmds({ group = augroup_format, buffer = bufnr })
      vim.api.nvim_create_autocmd("BufWritePre", {
        group = augroup_format,
        buffer = bufnr,
        callback = function()
          vim.lsp.buf.format({ bufnr = bufnr })
        end,
      })
    end

    -- lua for neovim
    vim.lsp.config("lua_ls", {
      capabilities = capabilities,
      single_file_support = true,
      on_attach = function(client, bufnr)
        on_attach(client, bufnr)
        enable_format_on_save(client, bufnr)
      end,
      settings = {
        Lua = {
          diagnostics = {
            -- Get the language server to recognize the `vim` global
            globals = { "vim" },
          },
        },
      },
    })

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
