# Neovim Configuration Documentation

## Overview
This is a performance-focused Neovim configuration built with Lazy.nvim, emphasizing fast startup times and stable workflow. The config is optimized for development with comprehensive LSP support, intelligent completion, and minimal visual clutter.

## Architecture

### Core Files
- `init.lua` - Main entry point, loads config modules
- `lua/config/lazy.lua` - Lazy.nvim bootstrap and core settings (28 lines of optimized vim.opt)
- `lua/config/keymaps.lua` - Global keybindings and shortcuts
- `lua/helpers/keymap.lua` - Keymap utility functions

### Directory Structure
```
~/.config/nvim/
├── init.lua                                    # Entry point
├── lua/
│   ├── config/
│   │   ├── lazy.lua                           # Core settings + Lazy.nvim setup
│   │   └── keymaps.lua                        # Global keybindings
│   ├── helpers/
│   │   ├── keymap.lua                         # Keymap helpers
│   │   └── icons.lua                          # Icon definitions
│   ├── plugins/
│   │   ├── init.lua                           # Global dependencies
│   │   ├── aesthetics/                        # UI & visual plugins
│   │   ├── editor_utils/                      # Editor enhancement plugins
│   │   ├── language_server_protocols/         # LSP & completion
│   │   └── gits/                              # Git integration
│   └── snippets/
│       ├── cpp.lua                            # C++ snippets
│       └── rust.lua                           # Rust snippets
├── lazy-lock.json                             # Plugin version lock
└── CLAUDE.md                                  # This file
```

## Performance Profile

### Fast Startup Strategy
- **Lazy loading**: Most plugins load on events/commands/keys
- **Minimal core**: Only plenary.nvim and nui.nvim load at startup
- **Optimized settings**: Essential vim.opt configurations in lua/config/lazy.lua:28-94

### Plugin Loading Pattern
```lua
-- Event-driven
BufReadPost     → bufferline, illuminate
VeryLazy        → avante (AI assistant)
LspAttach       → lspsaga, signature

-- Key-driven  
<leader>e       → neo-tree
za, zR, zM      → nvim-ufo (folding)
<C-A-o>         → zen-mode

-- Command-driven
:Telescope      → telescope
:Trouble        → trouble

-- Filetype-driven
markdown        → markdown-preview
tact            → tact.vim
```

## Core Settings (lua/config/lazy.lua:28-94)

### Performance Optimizations
- `updatetime = 200` - Fast CursorHold events
- `timeoutlen = 300` - Quick key sequence timeout
- `pumheight = 10` - Limit completion popup size
- `undolevels = 5000` - Reasonable undo history

### Editor Behavior
- **Leader key**: `<Space>`
- **Indentation**: 2 spaces, smart indent
- **Search**: Case-insensitive with smart case
- **Folding**: UFO-nvim with level 99
- **Clipboard**: Linux xsel integration

## Plugin Categories

### Essential Core (Always Active)
```lua
"nvim-lua/plenary.nvim"     -- Lua utilities
"MunifTanjim/nui.nvim"      -- UI components
```

### LSP Stack (Medium Impact)
- **nvim-lspconfig** - Core LSP functionality
- **mason.nvim** - Language server management (18+ servers)
- **nvim-cmp** - Completion engine with multiple sources
- **nvim-treesitter** - Syntax highlighting (20+ languages)
- **none-ls.nvim** - Formatting (stylua, black, prettier, gofumpt)

### Editor Enhancements (Low Impact)
- **telescope.nvim** - Fuzzy finder (lazy-loaded)
- **neo-tree.nvim** - File explorer (lazy-loaded)
- **leap.nvim** - Advanced motion
- **nvim-ufo** - Code folding enhancement
- **bufferline** - Buffer tabs
- **toggleterm** - Terminal integration

### AI & Completion (High Impact)
- **avante.nvim** - AI coding assistant (Gemini provider, separate windows, project indexing)
- **cmp-tabnine** - TabNine completion (max 10 results)
- **copilot.lua** - DISABLED for performance

### Aesthetics (Minimal Impact)
- **kanagawa.nvim** - Active colorscheme (no italics)
- **lualine.nvim** - Status line
- **nvim-web-devicons** - File icons
- **indent-blankline** - Indent guides

## Key Mappings

### Global Shortcuts (lua/config/keymaps.lua)
```vim
" Core Navigation
q                   → Visual block mode (remapped from <C-v>)
zh/zk/zj/zl        → Window navigation
sv                 → Vertical split

" Editing
<C-a>              → Select all
<F3>               → Reformat entire file
<C-c>              → Copy to system clipboard
<C-s>              → Save file
<C-z>              → Undo
<C-y>              → Redo
<C-m-j>/<C-m-k>    → Move lines up/down

" Terminal
<Esc><leader>      → Exit terminal mode

" Markdown
<leader>p          → Markdown preview
```

### Plugin-Specific Keys
```vim
<leader>e          → Neo-tree toggle
<C-A-o>           → Zen mode
za/zR/zM          → UFO folding
<A-->             → ToggleTerm
<A-x>             → LSP signature toggle
```

## Language Support

### LSP Servers (via Mason)
- **Web**: typescript, html, css, tailwindcss, svelte
- **System**: lua_ls, bashls, jsonls, yamlls
- **Compiled**: rust_analyzer, clangd, gopls
- **Data**: sqlls, taplo (TOML)
- **Mobile**: kotlin_language_server
- **Blockchain**: solidity

### Formatters (via none-ls)
- **Lua**: stylua
- **Python**: black
- **JavaScript/TypeScript**: prettier
- **Go**: gofumpt

### Linters
- **Solidity**: solhint (via nvim-lint)

## Performance Recommendations

### Current Bottlenecks
1. **Avante AI assistant** - Heavy VeryLazy loading
2. **TabNine completion** - External service calls
3. **Treesitter auto-install** - 20+ language parsers
4. **Mason auto-install** - 18+ language servers

### Optimization Options
```lua
-- Reduce Treesitter languages to only used ones
ensure_installed = { "lua", "javascript", "typescript", "rust", "go" }

-- Disable unused Mason servers
-- Remove servers for languages you don't use

-- Consider disabling TabNine if not needed
-- Heavy resource usage for AI completion

-- Lazy-load Avante more aggressively
-- Only when AI assistance is explicitly needed
```

### Current Config Strengths
- Excellent lazy-loading strategy
- Minimal startup plugins (only 2 core deps)
- Event-driven plugin activation
- Optimized vim.opt settings
- Clean separation of concerns

## Workflow Commands

### Development
```vim
:Mason              → Manage language servers
:Lazy               → Plugin management
:Telescope          → Fuzzy find files/text
:Trouble            → View diagnostics
:MarkdownPreview    → Preview markdown files
```

### AI Assistance
```vim
<leader>ac          → Open chat window (primary)
<leader>aa          → Ask AI in floating window
<leader>an          → New chat session
<leader>ae          → Edit selection with AI
<leader>ar          → Refresh context
<leader>at          → Toggle sidebar
<leader>af          → Focus chat window

# Project Context Commands
@file              → Include current file (works)
@diagnostics       → Include error context (works)
@codebase          → Project context (limited - see notes)
```

### Git
```vim
:DiffviewOpen       → Git diff viewer
:Gitsigns           → Git line indicators (auto)
```

## Maintenance

### Plugin Updates
```bash
# Update all plugins
nvim +Lazy sync +qa

# Check plugin status
nvim +Lazy +qa
```

### LSP Management
```bash
# Update language servers
nvim +Mason +qa
```

### Performance Monitoring
- Startup time: Use `nvim --startuptime startup.log`
- Plugin impact: `:Lazy profile`
- LSP status: `:LspInfo`

## Notes
- Configuration prioritizes stability and speed over features
- AI completion available but resource-aware (TabNine limited to 10 results)
- Clipboard integration optimized for Linux (xsel)
- Folding enhanced with UFO for better code navigation
- Git integration lightweight but functional
- Aesthetic plugins kept minimal to reduce visual noise