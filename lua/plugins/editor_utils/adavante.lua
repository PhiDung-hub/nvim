return {
  "yetone/avante.nvim",
  event = "VeryLazy",
  version = false, -- Never set this value to "*"! Never!
  opts = {
    -- General provider settings
    providers = {
      -- Gemini specific settings
      gemini = {
        -- endpoint = "https://generativelanguage.googleapis.com",
        model = "gemini-2.5-flash-preview-05-20", -- your desired model (or use gpt-4o, etc.)
        timeout = 30000, -- Timeout in milliseconds, increase this for reasoning models
        temperature = 0,
        max_tokens = 8192, -- Increase this to include reasoning tokens (for reasoning models)
      },
    },
    -- Project-wide context and indexing
    rules = {
      project_dir = ".avante/rules", -- Project-specific rules directory
      global_dir = vim.fn.expand("~/.config/avante/rules"), -- Global rules directory
    },
    -- Window behavior for separate window mode
    windows = {
      position = "right", -- Can be "left", "right", "top", "bottom"
      width = 35, -- Width percentage of screen
      wrap = true,
      sidebar_header = {
        enabled = true,
        align = "center",
      },
      -- Enable separate window mode
      edit = {
        border = "rounded",
        start_insert = true,
      },
      ask = {
        border = "rounded",
        start_insert = true,
        floating = true, -- Open ask window as floating
      },
    },
    -- Chat history and persistence
    history = {
      max_tokens = 4096,
      storage_path = vim.fn.stdpath("state") .. "/avante",
    },
    -- Enhanced prompt logging for consistent chat
    prompt_logger = {
      enabled = true,
      log_dir = vim.fn.stdpath("cache") .. "/avante_prompts",
      max_files = 50, -- Keep last 50 conversation logs
    },
    -- Behavior settings
    behaviour = {
      auto_suggestions = false, -- Disable auto suggestions for performance
      auto_set_highlight_group = true,
      auto_set_keymaps = true,
      auto_apply_diff_after_generation = false,
      support_paste_from_clipboard = true,
    },
    -- File selector for project indexing
    file_selector = {
      provider = "telescope", -- Use telescope for better file selection
    },
  },
  -- Build command (set BUILD_FROM_SOURCE=true to build locally)
  build = "make BUILD_FROM_SOURCE=true",
  -- Example build command for Windows:
  -- build = "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "stevearc/dressing.nvim",
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    --- The below dependencies are optional,
    "echasnovski/mini.pick", -- for file_selector provider mini.pick
    "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
    "hrsh7th/nvim-cmp", -- autocompletion for avante commands and mentions
    "ibhagwan/fzf-lua", -- for file_selector provider fzf
    "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
    "zbirenbaum/copilot.lua", -- for providers='copilot'
    {
      -- support for image pasting
      "HakonHarnes/img-clip.nvim",
      event = "VeryLazy",
      opts = {
        -- recommended settings
        default = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          drag_and_drop = {
            insert_mode = true,
          },
          -- required for Windows users
          use_absolute_path = true,
        },
      },
    },
    {
      -- Make sure to set this up properly if you have lazy=true
      "MeanderingProgrammer/render-markdown.nvim",
      opts = {
        file_types = { "markdown", "Avante" },
      },
      ft = { "markdown", "Avante" },
    },
  },
}
