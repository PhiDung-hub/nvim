return {
  "hrsh7th/nvim-cmp", -- Code Completion.
  dependencies = {
    "onsails/lspkind-nvim", -- vscode-like pictograms.
    "hrsh7th/cmp-buffer", -- nvim-cmp source for buffers (tab)
    "hrsh7th/cmp-cmdline", -- autocompletion for cmdline
    "tzachar/cmp-tabnine", -- support for tabnine
  },
  config = function()
    local status, cmp = pcall(require, "cmp")
    local status2, lspkind = pcall(require, "lspkind")

    if not (status and status2) then
      print("WARNING: nvim-cmp | lspkindis unavailable.")
      return
    end

    local has_words_before = function()
      local line, col = unpack(vim.api.nvim_win_get_cursor(0))
      return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
    end

    local source_mapping = {
      buffer = "[Buffer]",
      nvim_lsp = "[LSP]",
      nvim_lua = "[Lua]",
      cmp_tabnine = "[TabNine]",
      copilot = "[Copilot]",
      path = "[Path]",
    }

    -- https://github.com/hrsh7th/nvim-cmp?tab=readme-ov-file#recommended-configuration
    cmp.setup({
      snippet = {
        -- REQUIRED - you must specify a snippet engine
        expand = function(args)
          vim.snippet.expand(args.body) -- For native neovim snippets (Neovim v0.10+)
        end,
      },
      mapping = cmp.mapping.preset.insert({
        ["<C-e>"] = cmp.mapping.close(),
        ["<CR>"] = cmp.mapping.confirm({
          behavior = cmp.ConfirmBehavior.Replace,
          select = false,
        }),
        ["<Tab>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.select_next_item()
          elseif has_words_before() then
            cmp.complete()
          else
            fallback()
          end
        end, { "i", "s" }),
        ["<S-Tab>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.select_prev_item()
          else
            fallback()
          end
        end, { "i", "s" }),
      }),
      sources = cmp.config.sources({
        { name = "nvim_lsp" },
        { name = "treesitter" },
        { name = "cmp_tabnine" },
        { name = "buffer" },
      }),
      native_menu = false,
      formatting = {
        format = lspkind.cmp_format({
          mode = "symbol_text",
          maxwidth = 60,
          menu = source_mapping,
        }),
      },
    })

    cmp.setup.cmdline(":", {
      mapping = cmp.mapping.preset.cmdline(),
      sources = cmp.config.sources({
        { name = "path" },
      }, {
        {
          name = "cmdline",
          option = {
            ignore_cmds = { "Man", "!" },
          },
        },
      }),
    })

    -- Use buffer source for `/` and `?` (if you enabled `native_menu`, this won't work anymore).
    cmp.setup.cmdline({ "/", "?" }, {
      mapping = cmp.mapping.preset.cmdline(),
      sources = {
        { name = "buffer" },
      },
    })

    vim.cmd([[
      highlight! default link CmpItemKind CmpItemMenuDefault
    ]])
  end,
}
