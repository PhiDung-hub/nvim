# Nvim-config

Phil's Neovim 0.12 config, styled after the WezTerm Agent OS (`~/.config/wezterm/DESIGN.md`). Startup is about 13.4 ms.

## Plugins

3 upstream plugins on nvim's built-in `vim.pack`, with local lazy loading and a `:Pack` manager window; everything small or medium is local Lua.

```
vim.pack (built in)
├── lean.nvim            Lean
├── nvim-treesitter      parsers + queries
└── fff                  file/content search
```

Local replacements: completion (native LSP, buffer/path sources, snippets, docs/signatures and command-line list), plugin manager (lazy.nvim), file tree (neo-tree), git (gitsigns and more), file icons, markdown rendering, per-server LSP configs (`lsp/`), tabline/statusline, picker, LSP UI (hover, peek, finder, outline, breadcrumbs), terminal, git signs, formatting/linting, pairs and tag close, colour swatches, sessions, big-file guard, colorscheme. The plan for replacing the remaining plugins, easiest first, is in CLAUDE.md.

## Features

- Native LSP for TypeScript (`ts_ls` for TS ≤ 5, `tsc --lsp` for TS 7), Rust (rustup rust-analyzer) and Lean (lean.nvim).
- `lua/agent`: co-work with a running Claude Code / Codex session. Ask with `/btw` about a selection, hand off tasks or `@agent` comments, and review incoming edits as inline hunks.
- `lua/core/complete.lua`: ghost-text completion from a local Qwen2.5-Coder 0.5B (about 0.3 s), Copilot Free as fallback, Codex on `<M-]>`.

See CLAUDE.md for layout, dependencies and keys.
