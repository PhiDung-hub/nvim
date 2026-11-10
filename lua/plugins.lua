-- Large plugins only; everything small/medium lives in lua/core, lua/ui and lua/agent.
local parsers = {
  "lua", "python", "javascript", "typescript", "tsx", "json", "html", "css", "scss", "markdown",
  "markdown_inline", "gitignore", "svelte", "solidity", "move", "rust", "toml", "yaml", "bash", "comment",
}

return {
  {
    "saghen/blink.cmp",
    version = "1.*",
    event = { "InsertEnter", "CmdlineEnter" },
    opts = {
      keymap = {
        preset = "none",
        ["<Right>"] = { function(cmp) if cmp.is_menu_visible() then return cmp.select_and_accept() end end, "fallback" },
        ["<Down>"] = { "select_next", "fallback" },
        ["<Up>"] = { "select_prev", "fallback" },
        ["<C-n>"] = { "select_next", "fallback" },
        ["<C-p>"] = { "select_prev", "fallback" },
        ["<CR>"] = { "accept", "fallback" },
        ["<C-e>"] = { "cancel", "fallback" },
        ["<C-b>"] = { "scroll_documentation_up", "fallback" },
        ["<C-f>"] = { "scroll_documentation_down", "fallback" },
      },
      sources = { default = { "lsp", "path", "buffer" } },
      completion = {
        menu = {
          border = "single",
          draw = { columns = { { "kind_icon" }, { "label", "label_description", gap = 1 }, { "source_name" } } },
        },
        documentation = { auto_show = true, auto_show_delay_ms = 200, window = { border = "single" } },
        list = { selection = { preselect = false, auto_insert = false } },
      },
      signature = { enabled = true, window = { border = "single" } },
      appearance = { nerd_font_variant = "mono" },
    },
  },
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
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = { "nvim-lua/plenary.nvim", "MunifTanjim/nui.nvim" },
    cmd = "Neotree",
    keys = {
      { "<M-t>", "<cmd>Neotree left toggle<cr>", desc = "Tree" },
      { "<S-M-G>", "<cmd>Neotree float git_status toggle<cr>", desc = "Tree git status" },
      { "<S-M-B>", "<cmd>Neotree float buffers toggle<cr>", desc = "Tree buffers" },
      { "<S-M-T>", "<cmd>Neotree float filesystem toggle<cr>", desc = "Tree filesystem" },
    },
    init = function()
      -- Replaces netrw: open the tree when nvim starts on a directory.
      vim.api.nvim_create_autocmd("BufEnter", {
        once = true,
        callback = function(ev)
          if vim.fn.isdirectory(ev.file) == 1 then require("neo-tree") end
        end,
      })
    end,
    opts = {
      popup_border_style = "single",
      enable_diagnostics = true,
      default_component_configs = {
        indent = { indent_marker = "│", last_indent_marker = "└", expander_collapsed = "▸", expander_expanded = "▾" },
        modified = { symbol = "●" },
        git_status = {
          symbols = {
            added = "+", modified = "~", deleted = "✗", renamed = "→",
            untracked = "?", ignored = "·", unstaged = "!", staged = "✓", conflict = "⊘",
          },
        },
      },
      event_handlers = {
        { event = "neo_tree_buffer_enter", handler = function() vim.wo.relativenumber = true end },
      },
      git_status_async = true,
      git_status_async_options = { batch_size = 250, batch_delay = 10, max_lines = 100000 },
      filesystem = {
        async_directory_scan = "always",
        use_libuv_file_watcher = false,
        follow_current_file = { enabled = true },
        hijack_netrw_behavior = "open_current",
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = true,
          always_show = { ".gitignore" },
          hide_by_name = { ".DS_Store", "thumbs.db", ".git" },
        },
      },
      buffers = { follow_current_file = { enabled = true }, group_empty_dirs = true, show_unloaded = true },
    },
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
