-- Large plugins only; everything small/medium lives in lua/core, lua/ui and lua/agent.
local parsers = {
  "lua", "python", "javascript", "typescript", "tsx", "json", "html", "css", "scss", "markdown",
  "markdown_inline", "gitignore", "svelte", "solidity", "move", "rust", "toml", "yaml", "bash", "comment",
}
return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "TSUpdate",
        callback = function()
          require("nvim-treesitter.parsers").move = {
            install_info = { url = "https://github.com/tzakian/tree-sitter-move", queries = "queries" },
          }
        end,
      })
      local ts = require("nvim-treesitter")
      -- Compare against nvim-treesitter's own installs: nvim's bundled lua/markdown parsers lag its queries.
      local installed = ts.get_installed("parsers")
      local missing = vim.tbl_filter(function(lang) return not vim.list_contains(installed, lang) end, parsers)
      if #missing > 0 then ts.install(missing) end
      require("core.treesitter").setup()
    end,
  },
  {
    "Julian/lean.nvim",
    event = { "BufReadPre *.lean", "BufNewFile *.lean" },
    init = function() vim.g.lean_config = { mappings = true } end,
    config = function() end,
  },
}
