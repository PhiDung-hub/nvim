return {
  "akinsho/toggleterm.nvim", -- terminal toggler
  config = function()
    local status_ok, toggleterm = pcall(require, "toggleterm")
    if not status_ok then
      print("WARNING: toggle term is unavailable")
      return
    end

    toggleterm.setup({
      size = 30,
      open_mapping = [[<m-->]],
      hide_numbers = true,
      shade_filetypes = {},
      highlights = {
        NormalFloat = {
          link = 'Normal'
        },
      },
      shade_terminals = true,
      shading_factor = 4,
      start_in_insert = true,
      insert_mappings = true,
      terminal_mappings = true,
      persist_size = true,
      direction = "float",
      close_on_exit = true,
      shell = vim.o.shell,
      float_opts = {
        border = "none",
        winblend = 0,
      },
    })
  end,
}
