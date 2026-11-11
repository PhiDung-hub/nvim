vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.g.markdown_recommended_style = 0
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1

local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
if not vim.env.PATH:find(mason_bin, 1, true) then vim.env.PATH = mason_bin .. ":" .. vim.env.PATH end

local opt = vim.opt
opt.autowrite = true
opt.autoread = true
opt.confirm = true
opt.undofile = true
opt.undolevels = 5000
opt.updatetime = 200
opt.timeoutlen = 300
opt.mouse = "a"
opt.splitbelow = true
opt.splitright = true
opt.winminwidth = 5
opt.wrap = false
opt.scrolloff = 10
opt.sidescrolloff = 5
opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize" }
opt.shortmess:append({ W = true, I = true, c = true })
opt.grepprg = "rg --vimgrep"
opt.grepformat = "%f:%l:%c:%m"
opt.inccommand = "nosplit"
opt.wildmode = "longest:full,full"
opt.formatoptions = "jcroqlnt"
opt.conceallevel = 3
opt.spelllang = { "en" }

opt.tabstop = 2
opt.softtabstop = 2
opt.shiftwidth = 2
opt.shiftround = true
opt.expandtab = true
opt.smartindent = true
opt.ignorecase = true
opt.smartcase = true

opt.termguicolors = true
opt.number = true
opt.relativenumber = true
opt.signcolumn = "yes"
opt.statuscolumn = "%C%s%l %{%v:lua.require'git.signs'.column()%} "
opt.cursorline = true
opt.showmode = false
opt.laststatus = 0
opt.showtabline = 2
opt.ruler = false
opt.pumheight = 10
-- Square lines on the cells' outer edge: `single` draws mid-cell and leaves half a cell of ground outside it.
opt.winborder = "🭽,▔,🭾,▕,🭿,▁,🭼,▏"
opt.list = true
-- Indent guides without a plugin.
opt.listchars = { tab = "▏ ", leadmultispace = "▏ ", trail = "·", nbsp = "␣", extends = "…", precedes = "…" }
opt.fillchars = { eob = " ", fold = " ", foldopen = "▾", foldclose = "▸", foldsep = " ", foldinner = " ", diff = "╌" }

opt.foldcolumn = "1"
opt.foldlevel = 99
opt.foldlevelstart = 99
opt.foldmethod = "expr"
opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt.foldtext = ""

-- Wayland: nvim's own detection picks wl-copy; xsel only sees the XWayland clipboard there.
if not (vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1) then
  vim.g.clipboard = {
    name = "xsel",
    copy = { ["+"] = "xsel --clipboard --input", ["*"] = "xsel --input" },
    paste = { ["+"] = "xsel --clipboard --output", ["*"] = "xsel --output" },
    cache_enabled = 0,
  }
end

vim.filetype.add({ extension = { mdx = "lsp_markdown", move = "move" } })
vim.cmd.colorscheme("wezterm")
