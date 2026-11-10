# Nvim-config

Phil's Neovim 0.12 config, styled after the WezTerm Agent OS (`~/.config/wezterm/DESIGN.md`).

- 11 plugins on lazy.nvim; tabline, picker, git signs, formatting, pairs, sessions and terminal are local Lua.
- Native LSP for TypeScript (ts_ls for TS ≤ 5, `tsc --lsp` for TS 7), Rust (rustup rust-analyzer) and Lean (lean.nvim).
- `lua/agent`: co-work with a running Claude Code / Codex session. Ask with `/btw` about a selection, hand off tasks or `@agent` comments, and review incoming edits as inline hunks.

See CLAUDE.md for layout and keys.
