local map = vim.keymap.set

-- Exit terminal mode
map("t", "<Esc><leader>", "<C-\\><C-n>", { nowait = true })

-- Visual block mode
map("n", "q", "<C-v>")

-- Tab
map("i", "<S-tab>", "<C-d>")

-- Go to start and end of line in insert mode
map("i", "<C-Down>", "<Home>")
map("i", "<C-Up>", "<End>")

-- Window and file management
map("n", "<C-a>", "gg<S-v>G") -- select all
map("n", "<F3>", "gg=G<C-o>") -- reformat entire file

-- Split window vertical
map("n", "sv", ":vsplit<CR><C-w>w")

-- Move window
map("n", "zh", "<C-w>h")
map("n", "zk", "<C-w>k")
map("n", "zj", "<C-w>j")
map("n", "zl", "<C-w>l")

-- Copy to system clipboard
map("n", "<C-c>", '"+y')
map("v", "<C-c>", '"+y')

-- Deletion (C-H == C-BS)
map("i", "<C-H>", "<C-w>")

-- Undo / Redo
map("i", "<C-Z>", "<C-O>u")
map("n", "<C-Z>", "u")
map("i", "<C-Y>", "<C-O><C-R>")

-- Save
map("i", "<C-S>", "<ESC>:w<CR>a")
map("v", "<C-S>", "<ESC>:w<CR>gv")
map("n", "<C-S>", ":w<CR>")

-- Move lines up and down
map("n", "<C-m-k>", ":m .-2<CR>==")
map("v", "<C-m-j>", ":m '>+1<CR>gv=gv")
map("v", "<C-m-k>", ":m '<-2<CR>gv=gv")
map("n", "<C-m-j>", ":m .+1<CR>==")

-- Markdown preview
map("n", "<leader>p", ":MarkdownPreview<CR>")
