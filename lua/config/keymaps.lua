-- Add any additional keymaps here
local M = require("helpers.keymap")

local nnoremap = M.nnoremap
local vnoremap = M.vnoremap
local inoremap = M.inoremap
-- local tnoremap = M.tnoremap

-- Exit terminal mode
-- tnoremap("<Esc><leader>", "<C-\\><C-n>")
vim.keymap.set("t", "<Esc><leader>", "<C-\\><C-n>", { nowait = true, noremap = true })

-- Visual block mode
nnoremap("q", "<C-v>")

-- Tab
inoremap("<S-tab>", "<C-d>")

-- Go to start and end of line in insert mode.
inoremap("<C-Down>", "<Home>")
inoremap("<C-Up>", "<End>")

-- window and file management
nnoremap("<C-a>", "gg<S-v>G") -- select all
nnoremap("<F3>", "gg=G<C-o>") -- reformat entire file with F3

-- Split window vertical
nnoremap("sv", ":vsplit<CR><C-w>w")

-- Move window
nnoremap("zh", "<C-w>h")
nnoremap("zk", "<C-w>k")
nnoremap("zj", "<C-w>j")
nnoremap("zl", "<C-w>l")

-- Copy and paste
-- This option is set in window terminal and directly affect neovim
nnoremap("<C-c>", '"+y')
vnoremap("<C-c>", '"+y')

-- Deletion
inoremap("<C-H>", "<C-w>") -- C-H == C-BS https://www.reddit.com/r/neovim/comments/okbag3/comment/h58k9p7/?utm_source=share&utm_medium=web2x&context=3

-- Do, undo.
inoremap("<C-Z>", "<C-O>u")
nnoremap("<C-Z>", "u")
inoremap("<C-Y>", "<C-O><C-R>")

-- press Ctrl-S to save
inoremap("<C-S>", "<ESC>:w<CR>a")
vnoremap("<C-S>", "<ESC>:w<CR>gv")
nnoremap("<C-S>", ":w<CR>")

-- Move lines up and down
nnoremap("<C-m-k>", ":m .-2<CR>==")
vnoremap("<C-m-j>", ":m '>+1<CR>gv=gv")
vnoremap("<C-m-k>", ":m '<-2<CR>gv=gv")
nnoremap("<C-m-j>", ":m .+1<CR>==")

-- Using Markdown Preview
nnoremap("<leader>p", ":MarkdownPreview<CR>")

-- Avante AI shortcuts
nnoremap("<leader>ac", "<Plug>(AvanteChat)")    -- Open chat window (primary)
nnoremap("<leader>aa", "<Plug>(AvanteAsk)")     -- Ask AI in floating window
nnoremap("<leader>an", "<Plug>(AvanteAskNew)")  -- New chat session
nnoremap("<leader>ae", "<Plug>(AvanteEdit)")    -- Edit selection with AI
nnoremap("<leader>ar", "<Plug>(AvanteRefresh)") -- Refresh context
nnoremap("<leader>at", "<Plug>(AvanteToggle)")  -- Toggle sidebar
nnoremap("<leader>af", "<Plug>(AvanteFocus)")   -- Focus chat window
