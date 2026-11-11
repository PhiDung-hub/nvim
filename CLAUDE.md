# Neovim Configuration

Neovim 0.12 config on nvim's built-in **vim.pack** (local lazy-loading in `config/pack.lua`). Three upstream plugins (plus language servers installed by `:Tools` and a local llama.cpp server); everything small or medium is rewritten locally in `lua/core`, `lua/ui` and `lua/agent`. Startup is about 13.4 ms headless.

## Design

One look with WezTerm/Agent OS. The guideline lives in `~/.config/wezterm/DESIGN.md`, and that file wins. `lua/design.lua` is its token block copied verbatim; `colors/agentos.lua` paints from it.
- The chrome follows the state colours: green done/running, yellow attention/waiting, blue ids/Codex, magenta shas/times/Claude, cyan args/paths/active tab, red failed, dim for idle or unknown. Code uses Tokyo Night syntax hues.
- Square `single` borders only (`winborder`). Content windows leave the background unpainted so WezTerm's wallpaper shows; floats and menus draw `ground`. Floats are titled ` ❯ verb `.
- Rows read `glyph · id · text`, using the glyphs ✓ ◆ ○ ● ✗ ! ? ❯ ⎿ ▸ ▾.
- One top bar like the WezTerm tab bar (`laststatus=0`, `showtabline=2`): buffers on the left, each padded one cell: the focus tab (only while the nvim pane has focus; an unfocused pane shows it as a plain tab) is a cyan-tinted band (`TabLineSel`, cyan blended 22% into ground) ` ● 2:name line:col ` that keeps its colours (cyan bold `● 2:`, coloured icon, bold `text` name, yellow `+`, magenta position), never inverted; others read ` 2:name ` or ` ! n:name ` (pending agent hunks), cyan on `surface`, divided by faint `│` (no divider beside the focus block). Each tab carries its file icon, the name widened with parent dirs when two tabs share it (`a/init.lua`), `+` unsaved, a lock when read-only, and `✗n`/`!n` diagnostics; the focus tab adds `line:charcol` (absolute line, column in characters). Right side: mode, the current file's icon · filetype · language servers (Copilot omitted; `lsp off` for a big file) · non-utf-8/non-unix flags, diagnostics, AI, agent, branch, and `totalL pct%`.
- Shared highlight groups are `Aos*`: `AosSeg<Color>` for segments, `AosAgent*` for review hunks.

## Layout

```
init.lua                 options → pack → autocmds → core → tabline → keymaps → agent
colors/agentos.lua       colorscheme from lua/design.lua
lua/design.lua           Agent OS tokens (verbatim from DESIGN.md)
lua/plugins.lua          the only plugin spec (lazy.nvim-style tables)
lua/config/              options, pack (vim.pack + lazy loading), autocmds (reload, bigfile, sessions, indent guides), keymaps, commands
lsp/<name>.lua           one config per server (local copies of nvim-lspconfig's, trimmed)
lua/core/cmp.lua         native insert completion (first InsertEnter), buffer/path sources, ghost preview, docs and signatures
lua/core/lsp.lua         which servers to enable, TypeScript routing, LSP keymaps, diagnostics
lua/core/treesitter.lua  FileType → vim.treesitter.start + indentexpr (size-guarded)
lua/core/format.lua      external formatters + LSP fallback, solhint diagnostics
lua/core/edit.lua        autopairs, tag auto-close, #rrggbb swatches
lua/ui/tree.lua          async file tree (sidebar/float): capped libuv reads, git, diagnostics, watches
lua/ui/pick.lua          fuzzy picker with optional preview pane; also vim.ui.select
lua/ui/lsp.lua           LSP/syntax UI: hover, peek, finder, outline, breadcrumbs, rename, calls, inspect
lua/ui/fix.lua           quick fix: cursor-line hint, apply/pick with diff preview, fix-all, Codex/agent fallback
lua/ui/tabline.lua       buffers + status segments
lua/ui/term.lua          float terminal
lua/ui/pack.lua          :Pack / :Lazy manager window
lua/ui/tools.lua         :Tools / :Mason installer for the language servers and formatters
lua/ui/cmdline.lua       centred command line (ext_cmdline float, ghost completion, local list below)
lua/ui/icons.lua         file glyphs + Aos colours; lua/nvim-web-devicons.lua forwards to it for fff
lua/ui/markdown.lua      in-buffer markdown rendering (extmarks from the markdown parsers)
lua/agent/               Claude/Codex co-working (below)
lua/git/                 VS Code-style git (below): repo, signs, scm, diff, merge, graph, branch
```

## Plugins (lua/plugins.lua)

3 upstream plugins, managed by `vim.pack` (installs to `~/.local/share/nvim/site/pack/core/opt`, lockfile `nvim-pack-lock.json`). Lua sizes exclude tests; "native" = prebuilt or downloaded binary.

```
vim.pack (built in)             plugin manager + config/pack.lua lazy loading · needs git
├── lean.nvim                   Lean LSP + infoview, *.lean        15.1k Lua · ships its own lsp/leanls.lua · needs lean/lake (elan)
├── nvim-treesitter  main       parser install + queries + indent   4.6k Lua + queries · needs tree-sitter CLI ≥0.26, cc
└── fff  v0.11.0                file/content search, keys          10.2k Lua + native libfff_nvim.so (download_or_build)
```

Soft edges (`pcall`): fff → devicons shim/plenary.filetype; without plenary it uses `vim.filetype.match` and extension fallbacks. No remaining plugin requires nui or plenary.

External tools: language servers and formatters installed by `:Tools` into `~/.local/share/nvim/mason/bin` (copilot-language-server, lua-language-server, pyright, ruff, rust-analyzer fallback, stylua, prettierd, taplo, yaml/json/html/css/svelte/tailwind/emmet/bash/prisma servers…), rustup `rust-analyzer`, TypeScript 7 `tsc`, `llama-server` + model in `~/.local/share/llama`, `codex`, `wezterm`, `rg`, `git`, `wl-copy`/`xsel`, `solhint`, `forge`.

### Replacement plan (next local rewrites, easiest first)

| # | Plugin(s) | Local replacement | Effort | Notes |
|---|---|---|---|---|
| 1 ✓ done | neo-tree + nui + plenary | `ui/tree.lua`: async libuv tree, `git.repo` status, sidebar/float | medium | six upstream plugins remain |
| 2 | fff | `ui/pick` + `rg --files` / `rg --vimgrep`, frecency from `v:oldfiles` | medium | loses fff's native scorer |
| 3 ✓ done | mason | `ui/tools.lua` `:Tools` (alias `:Mason`): fixed list of 21 tools via npm, pip venv, cargo or GitHub releases into the same `mason/` dir | medium | three upstream plugins remain |
| 4 ✓ done | lazy.nvim | `vim.pack` + `config/pack.lua` + `ui/pack.lua` | medium | lazy loading, build hooks, :Pack window |
| 5 ✓ done | blink.cmp | `core/cmp.lua`: native `vim.lsp.completion`, capped buffer/path sources, docs/signatures; cmdline list in `ui/cmdline` | large | native fuzzy matching and snippets |
| — | nvim-treesitter, lean.nvim | keep | — | queries/parser builds and the Lean infoview are too large to own |

Replaced locally already: neo-tree + nui + plenary → `ui/tree`; nvim-web-devicons → `ui/icons` + shim; render-markdown → `ui/markdown`; nvim-lspconfig → `lsp/*.lua` (dropped helper commands: LspPyrightSetPythonPath, LspClangdShowSymbolInfo, rust-analyzer code-lens runSingle); bufferline/lualine → `ui/tabline`; telescope → `ui/pick`; lspsaga → `ui/lsp`; toggleterm → `ui/term`; gitsigns/neo-tree git float → `lua/git`; conform/nvim-lint → `core/format`; autopairs/ts-autotag/colorizer → `core/edit` (tag rename is native LSP linked editing, colours inside CSS/Tailwind come from native LSP documentColor); bigfile/persistence → `config/autocmds`; indent-blankline → `listchars` leadmultispace; kanagawa → `colors/agentos`; codecompanion → `lua/agent` + `core/complete`; mason → `ui/tools`; blink.cmp → native completion + `core/cmp` + `ui/cmdline`.

Dropped: which-key, todo-comments (the treesitter `comment` parser highlights TODO/NOTE), rainbow-delimiters, friendly-snippets, mason-lspconfig, mason-tool-installer, ts-context-commentstring (JSX `{/* */}` comes from nvim-treesitter's query metadata).

## Plugin manager (lua/config/pack.lua, lua/ui/pack.lua)

- `lua/plugins.lua` keeps lazy.nvim-style specs: `"owner/repo"`, `version` (semver, e.g. `"1.x"`) / `tag` / `branch`, `lazy = false`, `event` (`"BufReadPre *.lean"` takes a pattern), `ft`, `cmd`, `keys` (`{ lhs, rhs, desc, mode }`), `init`, `opts` (→ `require(main).setup`), `config`, `build` (`":Cmd"` or a function, run on vim.pack's `PackChanged` install/update).
- `vim.pack.add` installs everything at startup but loads nothing (`load` is a no-op); `lazy = false` or a spec without triggers is `packadd`ed during init. Triggers: one-shot autocmds (the event is replayed for augroups the plugin created), stub user commands (re-run with range/bang/args, completion loads first), stub keymaps, and a `package.loaders` searcher so `require` of an unloaded plugin's module loads it (for example, loading fff on its first `require`). Builtins gzip/matchit/netrw/tar/tohtml/tutor/zip are disabled.
- `:Pack` (alias `:Lazy`): centred ` ❯ pack ` window, loaded/not-loaded sections with version, rev, load time and reason or triggers. `U` update (vim.pack's review buffer; `:w` applies), `S` sync without review, `u` update the plugin under the cursor, `l` load it, `C` remove plugins on disk that left the spec, `R` restore the lockfile revisions, `L` the update log, `⏎` details (src, path, version, triggers, build), `q` close.
- Startup is about 13.4 ms headless, median of 5 (16.2 ms on lazy.nvim + blink + mason).

## LSP (lsp/*.lua + lua/core/lsp.lua)

- Each server's whole config (cmd, filetypes, root logic, settings, user commands like `:LspCopilotSignIn`) lives in `lsp/<name>.lua`; nvim 0.12 reads it from the runtimepath. `core/lsp.lua` only decides what to enable and routes TypeScript. `leanls` comes from lean.nvim's own `lsp/leanls.lua`. rust_analyzer needs `cargo` on PATH to find a root (as upstream).

- Always enabled: `ts_ls`, `tsc`, `rust_analyzer`, `emmet_ls`, `tailwindcss`, `svelte`, `jsonls`, `html`, `cssls`, `ruff`, `solidity_ls_nomicfoundation`, `move_analyzer`. Lean goes through lean.nvim (`vim.g.lean_config`; it has no `setup()`).
- Enabled only when the binary exists: pyright, clangd, bashls, lua_ls, taplo, yamlls, prismals.
- **TypeScript routing:** a root with `node_modules/typescript/lib/tsserver.js` (TS ≤ 5) uses `ts_ls`. Any other root uses `tsc --lsp --stdio`, TypeScript 7's native server, preferring the project's local binary. The global TypeScript here is 7.x and ships no tsserver.js, which is why `ts_ls` alone failed.
- **Rust:** rustup's `~/.cargo/bin/rust-analyzer` (matches the toolchain; the `:Tools` standalone build may not), with clippy checks.
- `move_analyzer` needs a `Move.toml` (`workspace_required`).
- UI lives in `lua/ui/lsp.lua` (replaces lspsaga), all floats titled ` ❯ verb `:
  - `K` hover (own request: blank lines and stacked rules collapsed to one faint `─` divider, 1-cell padding; markdown rules and code-fence borders use the `Whitespace` guide colour) · `gd` definition (several → previewed list) · `gp` peek: editable float, `<CR>` opens it, `q` closes
  - `gf` finder: definitions ◆, implementations ◇ and references ● in one previewed list; a location keeps its strongest kind
  - `<leader>o` outline sidebar (right, follows the cursor and the focused LSP buffer, previews on move, closes when last)
  - breadcrumbs winbar ` ❯ dir/file › ◇ Class › ƒ method ` in LSP buffers (documentSymbol, refreshed 350 ms after edits)
  - `gr` rename float (name preselected; typing replaces) · `<leader>li`/`<leader>lo` incoming/outgoing calls
  - Quick fix (`ui/fix.lua`): resting on a line with diagnostics shows ` ◆ <fix> +n  ⎵.` in the focused window only (quickfix-only request, 150 ms debounce), scoped like the key: the diagnostic under the cursor, else the whole line. `<leader>.` / `<C-.>` (n/v; a charwise selection is sent exactly) applies the one preferred (or only) quickfix, never a suppression (`Disable…`, `noqa`), else opens ` ❯ quick fix ` with a diff preview (resolved lazily), AI items first when no fix exists; an edit listed before the buffer changed is refused; `<leader>ca` always opens the full list. `<leader>cf` runs every `source.fixAll`, then preferred quickfixes one at a time, as one undo step. With diagnostics, the list offers `✦ Ask Codex to fix` (one read-only turn on the shared app-server, JSON line-range reply, previewed, 30 s timeout) and `✦ Ask <agent> to fix` when one is attached. `]d`/`[d` floats get a `⎵. quick fix · n available` footer.
  - `<C-.>` needs WezTerm to encode it under xterm modifyOtherKeys (nvim sends `CSI >4;2m`; kitty keyboard is off). nvim decodes `CSI 27;5;46~` and `CSI 46;5u` as `<C-.>`; a physical press is untested, `<leader>.` always works. rustc/clippy diagnostics stay stale until save, so fix-all skips any whose line changed during the run.
  - `<leader>i` inspect: treesitter captures, semantic tokens, syntax and extmark groups with resolved colours, plus the node path · `<leader>I` syntax tree
  - `]d`/`[d` jump and show the diagnostics float · `<leader>lh` inlay hints
- `vim.ui.select` goes through `ui/pick`. Prompt floats set `vim.b.completion = false`; native completion and its buffer keymaps skip them.
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

## Git (lua/git)

All git work is async through `git/repo.lua` (run, root, porcelain-v2 status, `show rev:path`, `show_raw` for CRLF). Every view is a centred popup (~90%×85%, ` ❯ … ` titles); `q`/`<Esc>` closes it and returns to the original window.
- **Gutter** (`signs.lua`): hunks against the index drawn by `statuscolumn` in their own cell after the line number (`▎` green added / yellow changed, `▁`/`▔` red deleted), so diagnostic signs never hide them. Refreshes on edits, saves and `.git` changes (fs_event on HEAD/index/refs; agents commit outside nvim).
- **Source Control** `<leader>gg` / `:Git` / `<S-M-G>`: list (branch ↑↓, commit box, Merge/Staged/Changes, VS Code letters; long names end in `…` before the letter) beside a live diff of the row (side by side ≥ 120 cols, else inline; a rename titles the left side with the old path). List: `<CR>` diff, or the merge editor on a Merge Changes row, `s`/`u`/`x` stage/unstage/discard (row, section header or visual), `S`/`U`/`X` all, `c` commit (offers stage-all; refuses unresolved conflicts), `C` amend, `t` tree, `p`/`P`/`f` push/pull --ff-only/fetch (header shows `◆ pushing 12s`; the same key again or `<C-c>` asks, then kills its process group), `O` open file, `g?` help. Diff pane: `s`/`x` stage/revert hunk (saves first; `x` re-reads the index and refuses a hunk that changed), `u` unstage on staged diffs, `]c`/`[c`, `<leader>gd` side-by-side ↔ inline. `<leader>gd` opens it on the current file, `<leader>gc` the commit editor, `:Git <args>` runs git (shell-style quoting) into a float.
- **Live list**: fs_event on the gitdir, the repo root and every listed file's directory (≤ 64), plus FocusGained; worktree events refresh at most once a second, one `git status` in flight at a time. A diff whose file left its section follows it (or shows `○ no changes`). A status cut off at 3 s shows `○ status paused · slow repo`.
- **Merge editor** `<CR>` on a conflict row / `:GitMerge [path]` / `<leader>gm`: header (`! n conflicts left`, then `✓ all conflicts resolved · s mark resolved`; merge/rebase/cherry-pick and what current/incoming mean, e.g. during a rebase current = upstream, incoming = your commit), Incoming `:3` │ Current `:2` on top (changed lines tinted, scrolled to the conflict), the real working file as the editable Result below. `co`/`ct`/`cb`/`c0` accept current/incoming/both/none (one undo step), `]x`/`[x`, `gb` base `:1` pane, `s` save + `git add` (refused while any marker line remains, stray ones included), `<Tab>` next pane, `q`/`<Esc>` back to where it opened. diff3/zdiff3, bare markers and CRLF work; a side holding a bare `=======` (setext heading) is split by matching `:2`/`:3`, and outside the popup that conflict is refused (`:GitMerge`); delete/modify and binary conflicts offer keep ours / keep theirs / delete instead.
- **Conflict markers in any buffer** (CodeLens-style): a ` Accept Current co · Accept Incoming ct · Accept Both cb · Compare ␣gm ` line above each `<<<<<<<`, current/base/incoming tints, and `co`/`ct`/`cb`/`c0`/`]x`/`[x` mapped buffer-locally only while markers exist (they shadow `c` + motion, e.g. `ct`, meanwhile).
- **Graph** `<leader>gl` / `:GitGraph`: own lane layout from `git log --topo-order` (branches, remotes, tags, HEAD), ref chips, 400 commits per page. `<CR>`/`<Tab>` expand files, `<CR>` on a file → side-by-side diff in the popup, `K` details, `y` sha, `c` checkout (via `git switch`), `/` filter, `b` all ↔ HEAD.
- **Branches** `<leader>gb` / `:GitBranch [name]` or click the branch segment: create, create from…, local (↑↓, date), remote (tracking), tags.
- **Hunks**: `]h`/`[h`, `ih`, `<leader>hp` peek (`s`/`x`/`]h`/`[h` inside), `<leader>hs` stage hunk (visual: selected lines), `<leader>hS` stage buffer, `<leader>hr` revert hunk, `<leader>hu` unstage. **Blame**: `<leader>gB` line blame (eol, unsaved edits mapped), `<leader>gL` file blame split (`<CR>` commit diff).
- Branch segment `main*+ ↑1↓2`: `*` unstaged, `+` staged, ↑↓ vs upstream, short sha when detached.
- Every git read runs under `repo.run`'s 3 s cap with a feature name (`status`, `diff`, `stage`, `merge`, …); a cut-off pauses that feature for the repo for 10 min with one notice.
- Limits: no merge editor for nested (recursive-merge, longer) markers; side panes sync to a conflict by matching its text, so an all-empty side lands just past the line before it.
- **3 s rule:** every git read goes through `repo.run` (killed at 3 s, feature paused 10 min, one `○ git <feature> paused` notice); no `run_sync`, and `repo.root` is a filesystem walk (`.git` dir/file, `GIT_DIR`/`GIT_WORK_TREE`, core.worktree/bare, HEAD validated, stops at a mount; same answer as `rev-parse --show-toplevel`). Writes (apply/commit/add/switch) are never killed (index.lock) but say `◆ git <op> still running…` past 3 s; push/pull/fetch cap at 60 s. Diff pane: past 128 KiB it drops histogram/linematch (Myers), past 512 KiB no filetype, past 40M hunks × lines inline only (side by side is ~3 ms per million), past 3 MiB it shows `○ <path> · too large to diff here` and `⏎` opens `git diff` as text (a refresh keeps its cursor, and skips it when unchanged). The gutter uses Myers past 128 KiB and turns off past 512 KiB (`b:git_gutter_off`).

## AI completion (lua/core/complete.lua)

Ghost text tagged with its source (`● local` green, `● copilot` dim, `● codex` blue); a higher-ranked source never gets replaced by a lower one (codex > local > copilot).
- **Local (default as-you-type):** Qwen2.5-Coder 0.5B Q8 via llama.cpp `llama-server /infill` on `127.0.0.1:18080`, installed in `~/.local/share/llama` (`bin/` + the `.gguf`, ~560 MB). Started on first insert, 6 threads, 24 tokens, 100 ms debounce. Measured in nvim: server up in 0.7 s, warm suggestions 0.23–0.35 s, about 0.6 GB RSS. One server per machine: a second nvim's server fails to bind and reuses the first; it dies with the nvim that owns it, and the next request restarts it. A suggestion that hits the token limit drops its unfinished last line. Override with `vim.g.complete_local_bin` / `vim.g.complete_local_model`.
- **Copilot (fallback):** `copilot-language-server` (`:Tools`) answers `textDocument/inlineCompletion` when the local server is missing, loading or failing. Sign in once with `:LspCopilotSignIn`.
- **Codex (on demand):** `<M-]>` starts one `codex app-server` (ChatGPT login) and runs a fresh ephemeral read-only turn (`gpt-6-luna`, effort low, no tools): 2.5–7 s. An error pauses it for 5 min. Override the model with `vim.g.complete_codex_model`.
- `:Complete auto|copilot|codex|off`: `auto` = local then Copilot; `copilot`/`codex` use only that source as you type.
- Insert keys (owned by `core/cmp.lua`): with the native completion menu open, `<Tab>`/`<S-Tab>` (also `<Down>`/`<Up>`, `<C-n>`/`<C-p>`) select the next/previous item (nothing is preselected) and the selected item previews as ghost text; `<CR>` confirms it (with nothing selected `<CR>` is a newline). AI ghost text is hidden while the menu is open. With the menu closed, `<Tab>` jumps to the next snippet field, else accepts AI ghost text, else inserts a tab; `<S-Tab>` goes to the previous snippet field, else unindents. `<C-e>` cancels the menu; `<C-b>`/`<C-f>` scroll its docs. The cmdline list opens below the centred prompt: `<Tab>`/`<S-Tab>` select, `<CR>` accepts only a selected item and runs the line, `<C-l>` accepts ghost text. `<M-]>` ask Codex now, `<C-]>` dismiss. Normal-mode `<Tab>` still cycles buffers.

## Keys (lua/config/keymaps.lua)

`q` visual block · `zh/zj/zk/zl` windows · `sv` vsplit · `<C-a>` select all · `<F3>` reindent · `<C-c>` copy · `y` yanks inside nvim only, `Y` (line, or a visual selection) also copies to the system clipboard · `<C-s>` save · `u`/`<C-r>`/`<C-z>`/`<C-y>` undo/redo (message recoloured: ↶/↷ cyan, change count green/red/yellow, `#seq` blue, age magenta) · `<C-m-j/k>` move lines · `<Tab>/<S-Tab>` buffers · `<leader>1-5`/`<leader>0` go to buffer · `<C-q>`/`db` close · `dlb`/`drb` close left/right · `\\` buffers · `;t` help · `;e` diagnostics · `;f`/`;r`/`;;` fff · `<M-t>` tree sidebar · `<S-M-T>` tree float · `<S-M-B>` buffer picker · `<m-->` terminal · `<leader>f` format · `<leader>qs`/`<leader>ql` sessions · `<leader>p` / `:Markdown` toggle markdown rendering.

Tree: `<CR>`/`l`/`o` open or fold, `h` parent/collapse, `s`/`S` splits, `t` tab, `P` preview without leaving, `a` add (`/` creates a directory), `r` rename, `d` trash (confirmation before permanent fallback), `c`/`x`/`p` copy/cut/paste, `y`/`Y` relative/absolute path, `H` gitignored, `R` refresh, `z` collapse all, `.` root here, `-` root up, `/` live filter of loaded names (Enter selects the first match and keeps tree focus; Esc clears), `g?` help, `q` close. `nvim .` replaces netrw in place without a listed directory buffer; opening a file releases that window so the next tree toggle opens a sidebar. Sessions preserve the root, presentation, width and expanded directories via `AosTreeSession` and `sessionoptions+=globals`. Sidebar width starts at 32 and is remembered for this session; the float uses ground with a square border. Scans read batches of 128, retain at most 2,000 entries per directory (plus an omitted-count row), and cut off at 3 s. Reveal validates the full path asynchronously and can retain its ancestor chain beyond the cap; the newest external directory entry can also appear beyond the cap, with omission counts adjusted. Expanded directories are rescanned after 150 ms; directory and git metadata events debounce git status for 300 ms, with one request in flight. While visible, a 400 ms asynchronous status poll covers edits in collapsed directories; porcelain parsing and indexing yield in 2 ms batches. Closing/collapsing stops their watches. Git reads share `git.repo`'s budget; staged letters carry `✓`, unstaged letters stand alone. Rename/cut uses Linux `renameat2(RENAME_NOREPLACE)` in a worker and refuses destination-buffer collisions; unsupported or cross-filesystem moves fail without an overwrite fallback.

## Commands (lua/config/commands.lua)

- `<leader>:` palette over every described normal-mode keymap and user command, most used first (counts persist in shada as `g:AOS_PALETTE`). Commands taking arguments are typed into the cmdline for you.
- `:Q :Qa :W :Wq :Wa :Wqa` typo aliases · `:LspInfo` (checkhealth vim.lsp) · `:LspRestart` · `:LspLog` · `:Format [toggle]` · `:Markdown` · `:Complete` · `:Agent`. nvim 0.12's own `:lsp enable|disable|restart|stop` also works.

## Behaviour notes

- Markdown (`ui/markdown.lua`): headings ❯…, setext too; code blocks with a border, language label, tinted body and dim line numbers (blocks of 2+ lines; floats widen to fit); bullets · ○ ◆; checkboxes ○ ✓; quotes ▏; rules; pipe tables boxed when aligned (│ overlays only when not). Renders the visible range plus a margin, debounced; the cursor line and the line being edited stay raw; hover floats render too. Skips big files.

- Format-on-save is **off** (conform never had it on). `:Format toggle` turns it on.
- `autoread` + `config/autocmds.lua` checks the current file every second and on focus. While an agent is attached, every visible buffer is checked every 2 s.
- Big files (≥ 1.5 MiB) are decided on every read: no treesitter, LSP, swap or undo. Treesitter highlighting also stops above 512 KiB.
- Anything that would block the UI over ~3 s is cut or async (git above; `<leader>aC` is async rg, 3 s, `--max-filesize 1M`, scans the repo root, never `$HOME` or an ancestor of it).
- LSP is refused above 512 KiB before any server starts (`core/lsp.lua` wraps `vim.lsp.start`, since servers receive the whole file on didOpen); a one-time `○ LSP off · big file` notice. `:let b:lsp_force = 1 | e` overrides.

## Gotchas

- **nvim-treesitter is on `main`** (needs the tree-sitter CLI ≥ 0.26 and a C compiler). Parsers install to `~/.local/share/nvim/site/parser`, which must win on the runtimepath. The missing check uses `get_installed()`, because nvim's bundled lua/markdown parsers lag the queries (`Invalid field name "operator"`).
- After changing `lua/plugins.lua`, restart nvim; vim.pack installs new plugins on startup, and `:Pack` → `C` removes ones you dropped.
- The Solidity server is not in `:Tools`; `nomicfoundation-solidity-language-server` must be on PATH. `:Tools` builds move-analyzer with cargo.
- `:Tools` (alias `:Mason`, `ui/tools.lua`): `i`/`u` install or update the row, `U` update all installed, `x` remove. Each install stages into `packages/<name>.new` and swaps in only on success, so a failed update keeps the old tool; bins are relinked in `mason/bin` and a `receipt.json` records the version.

## Maintenance

```bash
nvim --headless "+lua vim.pack.update(nil, { force = true })" +qa   # update plugins
nvim --headless "+TSUpdate" +qa       # update parsers after a treesitter bump
nvim --startuptime /tmp/st.log +qa    # profile startup
```
