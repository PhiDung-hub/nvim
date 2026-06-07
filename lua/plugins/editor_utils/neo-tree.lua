return {
  "nvim-neo-tree/neo-tree.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  keys = {
    { "<M-t>", "<cmd>Neotree left toggle<cr>", desc = "NeoTree toggle" },
    { "<S-M-G>", "<cmd>Neotree float git_status toggle<cr>", desc = "NeoTree git status" },
    { "<S-M-B>", "<cmd>Neotree float buffers toggle<cr>", desc = "NeoTree buffers" },
    { "<S-M-T>", "<cmd>Neotree float filesystem toggle<cr>", desc = "NeoTree filesystem" },
  },
  opts = {
    -- Relative line numbers inside the tree window
    event_handlers = {
      {
        event = "neo_tree_buffer_enter",
        handler = function()
          vim.cmd("setlocal relativenumber")
        end,
      },
    },
    -- Stream git markers in small async batches so huge repos never block
    git_status_async = true,
    git_status_async_options = { batch_size = 250, batch_delay = 10, max_lines = 100000 },
    filesystem = {
      -- "always" = open via :Neotree asynchronously ("auto" blocks on large trees)
      async_directory_scan = "always",
      use_libuv_file_watcher = false,
      follow_current_file = { enabled = true },
      hijack_netrw_behavior = "open_default",
      filtered_items = {
        hide_dotfiles = false,
        hide_gitignored = true,
        always_show = { ".gitignore" },
        hide_by_name = { ".DS_Store", "thumbs.db", ".git" },
      },
    },
    buffers = {
      follow_current_file = { enabled = true },
      group_empty_dirs = true,
      show_unloaded = true,
    },
  },
}
