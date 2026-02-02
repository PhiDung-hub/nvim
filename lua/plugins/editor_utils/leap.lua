return {
  url = "https://codeberg.org/andyg/leap.nvim", -- vim motion
  enable = true,
  dependencies = {
    "tpope/vim-repeat", -- modern '.' repeat command
  },
  config = function()
    local status, leap = pcall(require, "leap")
    if not status then
      print("leap.nvim not found")
      return
    end

    -- Sneak-style mappings (replaces add_default_mappings)
    vim.keymap.set({'n', 'x', 'o'}, 's',  '<Plug>(leap-forward)')
    vim.keymap.set({'n', 'x', 'o'}, 'S',  '<Plug>(leap-backward)')
    vim.keymap.set({'n', 'x', 'o'}, 'gs', '<Plug>(leap-from-window)')
  end,
}
