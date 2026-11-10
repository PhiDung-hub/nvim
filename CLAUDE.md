# Neovim Configuration

Neovim 0.12 config on **lazy.nvim**. Twelve upstream plugins (plus copilot-language-server from Mason and a local llama.cpp server); everything small or medium is rewritten locally in `lua/core`, `lua/ui` and `lua/agent`. Startup is about 12 ms headless.

## Design

One look with WezTerm/Agent OS. The guideline lives in `~/.config/wezterm/DESIGN.md`, and that file wins. `lua/design.lua` is its token block copied verbatim; `colors/agentos.lua` paints from it.
- The chrome follows the state colours: green done/running, yellow attention/waiting, blue ids/Codex, magenta shas/times/Claude, cyan args/paths/active tab, red failed, dim for idle or unknown. Code uses Tokyo Night syntax hues.
- Square `single` borders only (`winborder`). Content windows leave the background unpainted so WezTerm's wallpaper shows; floats and menus draw `ground`. Floats are titled ` ❯ verb `.
- Rows read `glyph · id · text`, using the glyphs ✓ ◆ ○ ● ✗ ! ? ❯ ⎿ ▸ ▾.
- One top bar like the WezTerm tab bar (`laststatus=0`, `showtabline=2`): buffers on the left as ` ● 1:name ` (active, solid cyan), ` ○ 2:name ` or ` ! n:name ` (pending agent hunks); solid segments on the right for mode, diagnostics, agent, hunks, branch and line:col.
- Shared highlight groups are `Aos*`: `AosSeg<Color>` for segments, `AosAgent*` for review hunks.

## Layout

```
init.lua                 options → lazy → autocmds → core → tabline → keymaps → agent
colors/agentos.lua       colorscheme from lua/design.lua
lua/design.lua           Agent OS tokens (verbatim from DESIGN.md)
lua/plugins.lua          the only lazy spec
lua/config/              options, lazy bootstrap, autocmds (reload, bigfile, sessions, indent guides), keymaps
lua/core/lsp.lua         native vim.lsp.config/enable, LSP keymaps, diagnostics
lua/core/treesitter.lua  FileType → vim.treesitter.start + indentexpr (size-guarded)
lua/core/format.lua      external formatters + LSP fallback, solhint diagnostics
lua/core/edit.lua        autopairs, tag auto-close, #rrggbb swatches
lua/core/git.lua         index-diff signs, branch for the tabline
lua/ui/pick.lua          fuzzy picker with optional preview pane; also vim.ui.select
lua/ui/lsp.lua           LSP/syntax UI: hover, peek, finder, outline, breadcrumbs, rename, calls, inspect
lua/ui/tabline.lua       buffers + status segments
lua/ui/term.lua          float terminal
lua/agent/               Claude/Codex co-working (below)
```

## Plugins (lua/plugins.lua)

12 upstream plugins (lazy.nvim included). Lua sizes exclude tests; "native" = prebuilt or downloaded binary.

```
lazy.nvim                       plugin manager                    13.4k Lua · needs git
├── blink.cmp  v1.*             completion menu (lsp/path/buffer)  14.7k Lua + native libblink_cmp_fuzzy.so
├── nvim-lspconfig              server defaults only (lsp/*.lua)   49.9k Lua (data; ~20 configs used)
│   └── lean.nvim               Lean LSP + infoview, *.lean        15.1k Lua · needs lean/lake (elan)
├── mason.nvim                  installer, on :Mason only          15.0k Lua · bin/ prepended to PATH
├── nvim-treesitter  main       parser install + queries + indent   4.6k Lua + queries · needs tree-sitter CLI ≥0.26, cc
│   └── render-markdown.nvim    in-buffer markdown, ft=markdown    10.9k Lua · uses markdown/markdown_inline parsers
├── neo-tree.nvim  v3.x         file tree, cmd/keys                23.8k Lua
│   ├── plenary.nvim            plenary.job/async (hard require)   13.1k Lua
│   ├── nui.nvim                windows/popups (hard require)       6.9k Lua
│   └── nvim-web-devicons       file icons (also optional for fff, render-markdown)  2.5k Lua
└── fff  v0.11.0                file/content search, keys          10.2k Lua + native libfff_nvim.so (download_or_build)
```

Hard edges: neo-tree → plenary, nui, devicons; lean.nvim → nvim-lspconfig (spec dependency). Soft edges (`pcall`): fff → devicons/plenary.filetype, render-markdown → devicons. Nothing else requires another plugin.

External tools outside lazy: language servers and formatters in `~/.local/share/nvim/mason/bin` (copilot-language-server, lua-language-server, pyright, ruff, rust-analyzer fallback, stylua, prettierd, taplo, yaml/json/html/css/svelte/tailwind/emmet/bash/prisma servers…), rustup `rust-analyzer`, TypeScript 7 `tsc`, `llama-server` + model in `~/.local/share/llama`, `codex`, `wezterm`, `rg`, `git`, `wl-copy`/`xsel`, `solhint`, `forge`.

### Replacement plan (next local rewrites, easiest first)

| # | Plugin(s) | Local replacement | Effort | Notes |
|---|---|---|---|---|
| 1 | nvim-web-devicons | `ui/icons.lua`: extension/filename → glyph + colour table | small | fff and render-markdown already `pcall` it; neo-tree needs a shim or goes with step 3 |
| 2 | render-markdown | `ui/markdown.lua`: extmarks for headings, code blocks, lists, checkboxes, tables | medium | parsers already installed |
| 3 | neo-tree + nui + plenary | `ui/tree.lua`: libuv scan, git status from `core/git`, split sidebar | medium | removes three plugins at once |
| 4 | fff | `ui/pick` + `rg --files` / `rg --vimgrep`, frecency from `v:oldfiles` | medium | loses fff's native scorer |
| 5 | mason | `:Tools` installing via npm/cargo/pip into one bin dir | medium | keep the existing bin dir on PATH |
| 6 | nvim-lspconfig | inline the ~20 used configs as `lsp/<name>.lua` | small, data | `vim.lsp.config` reads `lsp/` from the runtimepath |
| 7 | lazy.nvim | `vim.pack` (built into nvim 0.12) | medium | lockfile and lazy-loading move to local code |
| 8 | blink.cmp | native `vim.lsp.completion` + small path/buffer sources | large | fuzzy ranking is the hard part |
| — | nvim-treesitter, lean.nvim | keep | — | queries/parser builds and the Lean infoview are too large to own |

Replaced locally already: bufferline/lualine → `ui/tabline`; telescope → `ui/pick`; lspsaga → `ui/lsp`; toggleterm → `ui/term`; gitsigns → `core/git`; conform/nvim-lint → `core/format`; autopairs/ts-autotag/colorizer → `core/edit` (tag rename is native LSP linked editing, colours inside CSS/Tailwind come from native LSP documentColor); bigfile/persistence → `config/autocmds`; indent-blankline → `listchars` leadmultispace; kanagawa → `colors/agentos`; codecompanion → `lua/agent` + `core/complete`.

Dropped: which-key, todo-comments (the treesitter `comment` parser highlights TODO/NOTE), rainbow-delimiters, friendly-snippets, mason-lspconfig, mason-tool-installer, ts-context-commentstring (JSX `{/* */}` comes from nvim-treesitter's query metadata).

## LSP (lua/core/lsp.lua)

- Always enabled: `ts_ls`, `tsc`, `rust_analyzer`, `emmet_ls`, `tailwindcss`, `svelte`, `jsonls`, `html`, `cssls`, `ruff`, `solidity_ls_nomicfoundation`, `move_analyzer`. Lean goes through lean.nvim (`vim.g.lean_config`; it has no `setup()`).
- Enabled only when the binary exists: pyright, clangd, bashls, lua_ls, taplo, yamlls, prismals.
- **TypeScript routing:** a root with `node_modules/typescript/lib/tsserver.js` (TS ≤ 5) uses `ts_ls`. Any other root uses `tsc --lsp --stdio`, TypeScript 7's native server, preferring the project's local binary. The global TypeScript here is 7.x and ships no tsserver.js, which is why `ts_ls` alone failed.
- **Rust:** rustup's `~/.cargo/bin/rust-analyzer` (matches the toolchain; Mason's standalone build may not), with clippy checks.
- `move_analyzer` needs a `Move.toml` (`workspace_required`).
- UI lives in `lua/ui/lsp.lua` (replaces lspsaga), all floats titled ` ❯ verb `:
  - `K` hover · `gd` definition (several → previewed list) · `gp` peek: editable float, `<CR>` opens it, `q` closes
  - `gf` finder: definitions ◆, implementations ◇ and references ● in one previewed list; a location keeps its strongest kind
  - `<leader>o` outline sidebar (right, follows the cursor and the focused LSP buffer, previews on move, closes when last)
  - breadcrumbs winbar ` ❯ dir/file › ◇ Class › ƒ method ` in LSP buffers (documentSymbol, refreshed 350 ms after edits)
  - `gr` rename float (name preselected; typing replaces) · `<leader>li`/`<leader>lo` incoming/outgoing calls · `<leader>ca` code action
  - `<leader>i` inspect: treesitter captures, semantic tokens, syntax and extmark groups with resolved colours, plus the node path · `<leader>I` syntax tree
  - `]d`/`[d` jump and show the diagnostics float · `<leader>lh` inlay hints
- `vim.ui.select` goes through `ui/pick`. Prompt floats set `vim.b.completion = false`, or blink.cmp's buffer keymaps shadow their `<CR>`/`<Down>`/`<Up>`.
- TypeScript 7's `tsc --lsp` returns no definition at a `new Class()` call site (only an implementation); the finder shows what the server returns.

## Agent co-working (lua/agent)

Attach nvim to a running Claude Code / Codex session, or start one in a split.
- `transport.lua` uses `wezterm cli list` and identifies agents by title, with `ps` on the pane's tty as fallback. Busy state comes from Agent OS's `~/.local/state/wezterm-agent-dashboard/events.jsonl` tail (observed) or the title spinner (guess). It sends with `send-text` (bracketed paste, then `\r`). It never presses Enter while the agent is `waiting` on a prompt.
- `review.lua` keeps a per-buffer base (the last accepted state). Every reload from disk is diffed against it and drawn inline: tinted new lines with a `▌` sign, removed lines as virtual lines, and a `● agent · +n −m` note. A human save accepts what is on screen.
- `view.lua` mirrors the agent pane's screen in a right split (`wezterm cli get-text`, 700 ms while visible).

```
<leader>aa attach / start     <leader>ab /btw about selection (n/v)    <leader>at task on selection
<leader>ae add selection      <leader>ac @agent comments (buffer)      <leader>aC (project)
<leader>av live view          <leader>af focus agent pane              <leader>al changes picker
]a / [a  next/prev hunk       <leader>ay / aY keep hunk / all          <leader>ar / aR undo hunk / all
:Agent [attach|spawn claude|codex|view|changes|comments|detach]  :'<,'>AgentAsk  :'<,'>AgentTask
```

## AI completion (lua/core/complete.lua)

Ghost text tagged with its source (`● local` green, `● copilot` dim, `● codex` blue); a higher-ranked source never gets replaced by a lower one (codex > local > copilot).
- **Local (default as-you-type):** Qwen2.5-Coder 0.5B Q8 via llama.cpp `llama-server /infill` on `127.0.0.1:18080`, installed in `~/.local/share/llama` (`bin/` + the `.gguf`, ~560 MB). Started on first insert, 6 threads, 24 tokens, 100 ms debounce. Measured in nvim: server up in 0.7 s, warm suggestions 0.23–0.35 s, about 0.6 GB RSS. One server per machine: a second nvim's server fails to bind and reuses the first; it dies with the nvim that owns it, and the next request restarts it. A suggestion that hits the token limit drops its unfinished last line. Override with `vim.g.complete_local_bin` / `vim.g.complete_local_model`.
- **Copilot (fallback):** `copilot-language-server` (Mason) answers `textDocument/inlineCompletion` when the local server is missing, loading or failing. Sign in once with `:LspCopilotSignIn`.
- **Codex (on demand):** `<M-]>` starts one `codex app-server` (ChatGPT login) and runs a fresh ephemeral read-only turn (`gpt-6-luna`, effort low, no tools): 2.5–7 s. An error pauses it for 5 min. Override the model with `vim.g.complete_codex_model`.
- `:Complete auto|copilot|codex|off`: `auto` = local then Copilot; `copilot`/`codex` use only that source as you type.
- Insert keys: `<Tab>` accept (literal Tab when nothing is shown), `<M-]>` ask Codex now, `<C-]>` dismiss. Normal-mode `<Tab>` still cycles buffers.

## Keys (lua/config/keymaps.lua)

`q` visual block · `zh/zj/zk/zl` windows · `sv` vsplit · `<C-a>` select all · `<F3>` reindent · `<C-c>` copy · `<C-s>` save · `<C-z>/<C-y>` undo/redo · `<C-m-j/k>` move lines · `<Tab>/<S-Tab>` buffers · `<leader>1-5`/`<leader>0` go to buffer · `<C-q>`/`db` close · `dlb`/`drb` close left/right · `\\` buffers · `;t` help · `;e` diagnostics · `;f`/`;r`/`;;` fff · `<M-t>` tree · `<m-->` terminal · `<leader>f` format · `<leader>qs`/`<leader>ql` sessions · `<leader>p` markdown render.

## Behaviour notes

- Format-on-save is **off** (conform never had it on). `:FormatToggle` turns it on.
- `autoread` + `config/autocmds.lua` checks the current file every second and on focus. While an agent is attached, every visible buffer is checked every 2 s.
- Big files (≥ 1.5 MiB) are decided on every read: no treesitter, LSP, swap or undo. Treesitter highlighting also stops above 512 KiB.

## Gotchas

- **nvim-treesitter is on `main`** (needs the tree-sitter CLI ≥ 0.26 and a C compiler). Parsers install to `~/.local/share/nvim/site/parser`, which must win on the runtimepath. The missing check uses `get_installed()`, because nvim's bundled lua/markdown parsers lag the queries (`Invalid field name "operator"`). Stale master-era `.so` files may still sit in `~/.local/share/nvim/lazy/nvim-treesitter/parser/`; they are dead weight.
- Never `git stash` to compare against an old config: starting nvim on the old spec makes lazy re-clone the old plugins and rewrite `lazy-lock.json`. Run `nvim --headless "+Lazy! restore" +qa` and `"+Lazy! clean"` to recover.
- Solidity/Move servers are not Mason-managed; `nomicfoundation-solidity-language-server` and `move-analyzer` must be on PATH.

## Maintenance

```bash
nvim --headless "+Lazy! sync" +qa     # update plugins
nvim --headless "+Lazy! clean" +qa    # drop plugins no longer in the spec
nvim --headless "+TSUpdate" +qa       # update parsers after a treesitter bump
nvim --startuptime /tmp/st.log +qa    # profile startup
```
