return {
  "lewis6991/gitsigns.nvim", -- viewing git
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    on_attach = function(buf)
      -- Large files are marked before BufReadPost, when gitsigns attaches.
      if vim.b[buf].bigfile_detected == 1 then return false end
    end,
  },
}
