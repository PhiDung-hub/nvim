return {
  "nvim-treesitter/nvim-treesitter",
  -- Pin to master: the `main` branch is a full rewrite that requires nvim 0.12+
  -- nightly and breaks the `nvim-treesitter.configs` API used below.
  branch = "master",
  event = { "BufReadPost", "BufNewFile" },
  build = ":TSUpdate",
  dependencies = {
    "HiPhish/rainbow-delimiters.nvim",             -- rainbow brackets
    "JoosepAlviste/nvim-ts-context-commentstring", -- tsx/jsx comment context
    "windwp/nvim-ts-autotag",                      -- auto rename/close tags
  },
  config = function()
    local ts_installed, ts = pcall(require, "nvim-treesitter.configs")
    if not ts_installed then
      print("WARNING: nvim-treesitter is unavailable.")
      return
    end

    local rainbow_installed, delimiters = pcall(require, "rainbow-delimiters")
    if not rainbow_installed then
      print("WARNING: rainbow-delimiters is unavailable.")
      return
    end

    -- Native Neovim 0.10+ commenting with tsx/jsx context support
    vim.g.skip_ts_context_commentstring_module = true
    require("ts_context_commentstring").setup({ enable_autocmd = false })

    local get_option = vim.filetype.get_option
    vim.filetype.get_option = function(filetype, option)
      return option == "commentstring"
          and require("ts_context_commentstring.internal").calculate_commentstring()
        or get_option(filetype, option)
    end

    -- nvim-ts-autotag (separate setup, no longer via treesitter config key)
    require("nvim-ts-autotag").setup({
      opts = {
        enable_close = true,
        enable_rename = true,
        enable_close_on_slash = false,
      },
    })

    -- Sui Move grammar — not in nvim-treesitter's master registry. Register
    -- tzakian/tree-sitter-move (archived but stable; covers Sui Move syntax).
    -- Semantic refinements come from move-analyzer LSP attached separately.
    local parsers = require("nvim-treesitter.parsers").get_parser_configs()
    parsers.move = {
      install_info = {
        url = "https://github.com/tzakian/tree-sitter-move",
        files = { "src/parser.c" },
        branch = "main",
      },
      filetype = "move",
    }

    ts.setup({
      highlight = {
        enable = true,
        disable = {},
        additional_vim_regex_highlighting = false,
      },

      indent = {
        enable = true,
        disable = {},
      },

      auto_install = true,
      ensure_installed = {
        "lua",
        "python",
        "javascript",
        "typescript",
        "tsx",
        "json",
        "html",
        "css",
        "scss",
        "markdown",
        "markdown_inline",
        "gitignore",
        "svelte",
        "solidity",
        "move",
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
  end,
}
