return {
  "nvim-telescope/telescope.nvim",
  cmd = "Telescope",
  init = function()
    -- Line numbers in the preview (right) panel
    vim.api.nvim_create_autocmd("User", {
      pattern = "TelescopePreviewerLoaded",
      callback = function()
        vim.wo.number = true
      end,
    })
  end,
  keys = {
    { "\\\\", function() require("telescope.builtin").buffers() end, desc = "Buffers" },
    { ";t", function() require("telescope.builtin").help_tags() end, desc = "Help tags" },
    { ";e", function() require("telescope.builtin").diagnostics() end, desc = "Diagnostics" },
  },
  opts = {
    defaults = {
      mappings = { n = { ["q"] = "close" } },
      file_ignore_patterns = { ".git/", ".cache", "%.o", "%.a", "%.out", "%.class", "%.pdf", "%.mkv", "%.mp4", "%.zip", "node_modules/" },
    },
  },
}
