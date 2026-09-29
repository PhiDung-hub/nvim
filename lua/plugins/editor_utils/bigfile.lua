local filesize_mib = 2

return {
  "LunarVim/bigfile.nvim",
  event = "BufReadPre",
  opts = {
    -- The plugin rounds bytes to MiB, so 2 starts at about 1.5 MiB.
    filesize = filesize_mib,
    -- Keep matchparen enabled globally; its built-in feature would leave it
    -- disabled after the large file is closed. Empty filetype also excludes ibl.
    features = { "lsp", "treesitter", "syntax", "vimopts", "filetype" },
  },
  config = function(_, opts)
    local group = vim.api.nvim_create_augroup("BigfileRecheck", { clear = true })

    -- bigfile.nvim caches its first size decision per buffer. Clear a small
    -- file's decision before rereading it if an external write made it large.
    vim.api.nvim_create_autocmd("BufReadPre", {
      group = group,
      callback = function(event)
        if vim.b[event.buf].bigfile_detected ~= 0 then return end
        local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(event.buf))
        if stat and stat.size >= (filesize_mib - 0.5) * 1024 * 1024 then
          vim.b[event.buf].bigfile_detected = nil
          vim.b[event.buf].bigfile_grew = true
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      callback = function(event)
        local buf = event.buf
        if not vim.b[buf].bigfile_grew then return end
        vim.b[buf].bigfile_grew = nil
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].bigfile_detected ~= 1 then return end
          for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
            vim.lsp.buf_detach_client(buf, client.id)
          end
          pcall(vim.treesitter.stop, buf)
          local gitsigns = package.loaded.gitsigns
          if gitsigns then gitsigns.detach(buf) end
        end)
      end,
    })

    require("bigfile").setup(opts)
  end,
}
