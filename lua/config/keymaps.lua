local map = vim.keymap.set
local tabline = require("ui.tabline")
local pick = require("ui.pick")

map("t", "<Esc><leader>", "<C-\\><C-n>", { nowait = true, desc = "Terminal normal mode" })
map("n", "q", "<C-v>", { desc = "Visual block" })
map("i", "<S-Tab>", "<C-d>", { desc = "Dedent line" })
map("i", "<C-Down>", "<Home>", { desc = "Line start" })
map("i", "<C-Up>", "<End>", { desc = "Line end" })
map("n", "<C-a>", "gg<S-v>G", { desc = "Select all" })
map("n", "<F3>", "gg=G<C-o>", { desc = "Reindent file" })
map("n", "sv", "<cmd>vsplit<cr><C-w>w", { desc = "Vertical split" })
map("n", "zh", "<C-w>h", { desc = "Window left" })
map("n", "zk", "<C-w>k", { desc = "Window up" })
map("n", "zj", "<C-w>j", { desc = "Window down" })
map("n", "zl", "<C-w>l", { desc = "Window right" })
map({ "n", "v" }, "<C-c>", '"+y', { desc = "Copy to clipboard" })
map("n", "Y", '"+yy', { desc = "Yank line to nvim and the system clipboard" })
map("x", "Y", '"+y', { desc = "Yank selection to nvim and the system clipboard" })
map("i", "<C-H>", "<C-w>", { desc = "Delete word before cursor" })
map("i", "<C-Z>", "<C-O>u", { desc = "Undo" })
local function undo(key)
  local out = vim.trim(vim.fn.execute("normal! " .. vim.v.count1 .. key))
  local what, side, seq, ago = out:match("^(.-); (%a+) #(%d+)%s+(.*)$")
  if not what then return vim.api.nvim_echo({ { out, "AosDim" } }, false, {}) end
  local tone = what:find("more") and "AosDone" or (what:find("fewer") or what:find("less")) and "AosFailed" or "AosRunning"
  vim.api.nvim_echo({
    { key == "u" and "↶ undo  " or "↷ redo  ", "AosArg" }, { what, tone }, { "  ·  ", "AosFaint" },
    { side .. " ", "AosDim" }, { "#" .. seq, "AosId" }, { "  ·  ", "AosFaint" }, { ago, "AosSha" },
  }, false, {})
end
map("n", "u", function() undo("u") end, { desc = "Undo" })
map("n", "<C-r>", function() undo("\18") end, { desc = "Redo" })
map("n", "<C-Z>", function() undo("u") end, { desc = "Undo" })
map("i", "<C-Y>", "<C-O><C-R>", { desc = "Redo" })
map("i", "<C-S>", "<Esc><cmd>w<cr>a", { desc = "Save" })
map("v", "<C-S>", "<Esc><cmd>w<cr>gv", { desc = "Save" })
map("n", "<C-S>", "<cmd>w<cr>", { desc = "Save" })
map("n", "<C-m-k>", "<cmd>m .-2<cr>==", { desc = "Move line up" })
map("n", "<C-m-j>", "<cmd>m .+1<cr>==", { desc = "Move line down" })
map("v", "<C-m-j>", ":m '>+1<cr>gv=gv", { desc = "Move selection down" })
map("v", "<C-m-k>", ":m '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Buffers (tabline)
map("n", "<Tab>", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "<S-Tab>", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
for i = 1, 5 do map("n", "<leader>" .. i, function() tabline.go(i) end, { desc = "Buffer " .. i }) end
map("n", "<leader>0", function() tabline.go(-1) end, { desc = "Last buffer" })
map("n", "<C-Q>", "<cmd>bdelete!<cr>", { desc = "Close buffer" })
map("n", "db", "<cmd>bdelete<cr>", { desc = "Close buffer" })
map("n", "dlb", function() tabline.close_side("left") end, { desc = "Close left buffers" })
map("n", "drb", function() tabline.close_side("right") end, { desc = "Close right buffers" })

-- Pickers
map("n", "\\\\", pick.buffers, { desc = "Buffers" })
map("n", ";t", pick.help, { desc = "Help tags" })
map("n", ";e", pick.diagnostics, { desc = "Diagnostics" })
map("n", ";f", function() pick.files() end, { desc = "Find files" })
map("n", ";r", function() pick.grep() end, { desc = "Live grep" })
map("n", ";;", pick.resume, { desc = "Resume search" })

map("n", "<M-t>", function() require("ui.tree").toggle() end, { desc = "Tree" })
map("n", "<S-M-T>", function() require("ui.tree").toggle(true) end, { desc = "Tree float" })
map("n", "<S-M-B>", function() require("ui.tree").toggle(true, "buffers") end, { desc = "Tree buffers" })

-- Tools
map({ "n", "t" }, "<m-->", require("ui.term").toggle, { desc = "Terminal" })
map("n", "<S-M-G>", function() require("git.scm").toggle() end, { desc = "Source Control" })
map("n", "<leader>f", function() require("core.format").format() end, { desc = "Format buffer" })
map("n", "<leader>qs", function() _G.AosSession(false) end, { desc = "Restore session" })
map("n", "<leader>ql", function() _G.AosSession(true) end, { desc = "Restore last session" })
