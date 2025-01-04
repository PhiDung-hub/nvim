return {
  "nvim-treesitter/nvim-treesitter",
  dependencies = {
    "HiPhish/rainbow-delimiters.nvim",             -- rainbow bracket: https://github.com/HiPhish/rainbow-delimeters.nvim
    "JoosepAlviste/nvim-ts-context-commentstring", -- tsx/jsx comment helper, use with Comment.nvim
    "windwp/nvim-ts-autotag",                      -- auto rename tags
    "numToStr/Comment.nvim",                       -- Comment string, enhanced default `gc` behavior.
  },
  config = function()
    -- NOTE: for Tact-lang (TON blockchain)
    local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
    -- Adds tree-sitter-tact support
    parser_config.tact = {
      install_info = {
        url = "~/os_packages/tree-sitter-tact", -- a path to the cloned repo
        files = { "src/parser.c" },
        branch = "main",
        generate_requires_npm = false,
        requires_generate_from_grammar = false,
      },
    }
    vim.filetype.add({
      extension = {
        tact = "tact",
      },
    })

    local ts_installed, ts = pcall(require, "nvim-treesitter.configs")
    if not ts_installed then
      print("WARNING: nvim-treesitter is unavailable.")
      return
    end

    -- nvim-ts-rainbow plugin: https://github.com/HiPhish/rainbow-delimiters.nvim
    local rainbow_installed, delimiters = pcall(require, "rainbow-delimiters")
    if not rainbow_installed then
      print("WARNING: ts-rainbow is unavailable.")
      return
    end

    -- nvim-ts-autotag plugin: https://github.com/windwp/nvim-ts-autotag
    local autotag_installed, _ = pcall(require, "nvim-ts-autotag")
    if not autotag_installed then
      print("WARNING: nvim-ts-autotag is unavailable")
      return
    end

    -- nvim-ts-context-commentstring plugin: https://github.com/JoosepAlviste/nvim-ts-context-commentstring#commentnvim
    local ts_context_installed, ts_context_commentstring = pcall(require, "ts_context_commentstring")
    if not ts_context_installed then
      print("WARNING: ts-context-commentstring is unavailable.")
      return
    end

    ts_context_commentstring.setup({})
    vim.g.skip_ts_context_commentstring_module = true

    -- Comment plugin: https://github.com/numToStr/Comment.nvim
    local comment_installed, comment = pcall(require, "Comment")
    if not comment_installed then
      print("WARNING: Comment.nvim is unavailable")
      return
    end

    comment.setup({
      pre_hook = require("ts_context_commentstring.integrations.comment_nvim").create_pre_hook(),
    })

    ts.setup({
      highlight = {
        enable = true,
        disable = {},
        additional_vim_regex_highlighting = true,
      },

      indent = {
        enable = true,
        disable = {},
      },

      auto_install = true,
      ensure_installed = {
        "lua",
        "cpp",
        "rust",
        "solidity",
        "python",
        "javascript",
        "typescript",
        "tsx",
        "sql",
        "json",
        "html",
        "css",
        "scss",
        "markdown",
        "markdown_inline",
        "yaml",
        "toml",
        "gitignore",
        "svelte",
        "proto",
        "go",
      },

      autotag = {
        enable = true,
      },

      rainbow = {
        strategy = {
          [""] = delimiters.strategy["global"],
          vim = delimiters.strategy["local"],
        },
        query = {
          [""] = "rainbow-delimiters",
          lua = "rainbow-blocks",
        },
        highlight = {
          "RainbowDelimiterYellow",
          "RainbowDelimiterBlue",
          "RainbowDelimiterOrange",
          "RainbowDelimiterGreen",
          "RainbowDelimiterViolet",
          "RainbowDelimiterCyan",
          "RainbowDelimiterRed",
        },
      },
    })

    parser_config.tsx.filetype_to_parsername = { "javascript", "typescript", "javascript.jsx", "typescript.tsx" }
  end,
}
