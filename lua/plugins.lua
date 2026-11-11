-- Large plugins only; everything small/medium lives in lua/core, lua/ui and lua/agent.
local parsers = {
  "lua", "python", "javascript", "typescript", "tsx", "json", "html", "css", "scss", "markdown",
  "markdown_inline", "gitignore", "svelte", "solidity", "move", "rust", "toml", "yaml", "bash", "comment",
}
return {
  {
    "mason-org/mason.nvim",
    cmd = { "Mason", "MasonInstall", "MasonUpdate" },
    opts = { ui = { border = "single" } },
  },
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
    "dmtrKovalenko/fff",
    tag = "v0.11.0",
    build = function() require("fff.download").download_or_build_binary() end,
    cmd = { "FFFFind", "FFFResume", "FFFScan", "FFFHealth" },
    keys = {
      { ";f", function() require("fff").find_files() end, desc = "Find files" },
      { ";r", function() require("fff").live_grep() end, desc = "Live grep" },
      { ";;", function() require("fff").resume() end, desc = "Resume search" },
    },
    opts = {
      prompt = "❯ ",
      title = "fff",
      preview = { line_numbers = true },
      hl = { normal = "Normal", border = "FFFBorder", prompt = "AosPrompt" },
    },
  },
  {
    "Julian/lean.nvim",
    event = { "BufReadPre *.lean", "BufNewFile *.lean" },
    init = function() vim.g.lean_config = { mappings = true } end,
    config = function() end,
  },
}
