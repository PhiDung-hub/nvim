-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local lazyrepo = "https://github.com/folke/lazy.nvim.git"
    local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out,                            "WarningMsg" },
            { "\nPress any key to exit..." },
        }, true, {})
        vim.fn.getchar()
        os.exit(1)
    end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- This file is automatically loaded by plugins.config
local opt = vim.opt

-- General settings
opt.autowrite = true           -- Enable auto write
opt.conceallevel = 3           -- Hide * markup for bold and italic
opt.confirm = true             -- Confirm to save changes before exiting modified buffer
opt.formatoptions = "jcroqlnt" -- tcqj
opt.grepformat = "%f:%l:%c:%m"
opt.grepprg = "rg --vimgrep"
opt.inccommand = "nosplit"         -- preview incremental substitute
opt.laststatus = 0
opt.list = true                    -- Show some invisible characters (tabs...
opt.mouse = "a"                    -- Enable mouse mode
opt.number = true                  -- Print line number
opt.winblend = 0
opt.pumblend = 10                  -- Popup blend
opt.pumheight = 10                 -- Maximum number of entries in a popup
opt.relativenumber = true          -- Relative line numbers
opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize" }
opt.shiftround = true              -- Round indent
opt.shortmess:append({ W = true, I = true, c = true })
opt.showmode = false               -- Dont show mode since we have a statusline
opt.signcolumn = "yes"             -- Always show the signcolumn, otherwise it would shift the text each time
opt.spelllang = { "en" }
opt.splitbelow = true              -- Put new windows below current
opt.splitright = true              -- Put new windows right of current
opt.timeoutlen = 300
opt.undofile = true                -- maintain undo history between sessions
opt.undolevels = 5000
opt.updatetime = 200               -- Save swap file and trigger CursorHold
opt.wildmode = "longest:full,full" -- Command-line completion mode
opt.winminwidth = 5                -- Minimum window width
opt.hidden = true                  -- hide abandoned buffer

-- Fix markdown indentation settings
vim.g.markdown_recommended_style = 0

-- Encodings
vim.scriptencoding = "utf-8"
opt.encoding = "utf-8"
vim.bo.fileencoding = "utf-8"

local TAB_SIZE = 2
-- Editing settings
opt.tabstop = TAB_SIZE                       -- using space`s
opt.softtabstop = TAB_SIZE                   -- treat tab in editting as single character
opt.shiftwidth = TAB_SIZE                    -- width of A LEVEL OF INDENTATION
opt.smarttab = true                          -- insert Tab in a blank line will be determined by other places. Backspasce delete shiftwidth
opt.autoindent = true                        -- New line inherit indentation of previous lines
opt.smartindent = true                       -- Smart indentation when start a new line (for C-like programs).
opt.expandtab = true                         -- Use space to insert a tab
opt.wrap = false                             -- Wrap line when go beyond certain number of characters
opt.backspace = { "start", "eol", "indent" } -- Allow backspacing over everything in insert mode
opt.scrolloff = 10                           -- scroll editor when there is x lines left
opt.sidescrolloff = 5
opt.sidescroll = 5
opt.completeopt = "menu,menuone,noselect,noinsert"
opt.termguicolors = true -- True color support

-- Search
opt.ignorecase = true -- case-insensitive search
opt.smartcase = true  -- switch between case-sensitive whenever uppercase letter present
opt.incsearch = true  -- incremental search (Default = ON)
opt.hlsearch = true   -- Enable search highlighting (Default = ON)

-- Current line
opt.cursorline = true             -- Enable highlight cursor line
opt.cursorlineopt = "number,line" -- Include number & whole line
vim.report = 5

vim.filetype.add({
    extension = {
        mdx = "lsp_markdown",
    },
    filename = {},
    pattern = {},
})

-- For UFO-nvim (folding)
opt.foldcolumn = "1"
opt.foldlevel = 99
opt.foldlevelstart = 99
opt.foldenable = true

-- Define the clipboard settings for WSL
vim.g.clipboard = {
    name = "Linux-Clipboard",
    copy = {
        ['+'] = 'xsel --clipboard --input',
        ['*'] = 'xsel --input',
    },
    paste = {
        ['+'] = 'xsel --clipboard --output',
        ['*'] = 'xsel --output',
    },
    cache_enabled = 0,
}

vim.g.latex_view_method = "zathura"
vim.g.latex_view_general_viewer = "zathura"
vim.g.latex_view_general_options = "--synctex-forward %l:1:%f %s"
vim.g.latex_view_general_options_latexmk = "--synctex=1"

require("lazy").setup({
    spec = {
        { import = "plugins" },
        { import = "plugins.editor_utils" },
        { import = "plugins.language_server_protocols" },
        { import = "plugins.language_server_protocols.3rd_party_plugins" },
        { import = "plugins.gits" },
        { import = "plugins.aesthetics" },
        { import = "plugins.aesthetics.color_schemes" },
    },
})
