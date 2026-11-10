-- VS Code-style Source Control in a centred popup: file list (commit box, Merge/Staged/Changes, list or tree)
-- on the left, live diff of the row under the cursor on the right (git.diff); stage/unstage/discard, commit
-- (smart, amend), push/pull/fetch and `:Git <args>`.
local repo = require("git.repo")
local icons = require("ui.icons")
local M = {}
local ns = vim.api.nvim_create_namespace("git.scm")
local busy_ns = vim.api.nvim_create_namespace("git.scm.busy")
local diff = require("git.diff")
local S = { collapsed = {}, rows = {}, draft = "", tree = false, dirs = {} }
local timer, ptimer, wtimer, btimer = vim.uv.new_timer(), vim.uv.new_timer(), vim.uv.new_timer(), vim.uv.new_timer()
local MAX_DIRS = 64

local SECTIONS = {
  { key = "conflicts", title = "Merge Changes" },
  { key = "staged", title = "Staged Changes" },
  { key = "changes", title = "Changes", always = true },
}
local LETTER_HL = { M = "AosRunning", T = "AosRunning", A = "AosDone", U = "AosDone", D = "AosFailed", R = "AosId", C = "AosId", ["!"] = "AosFailed" }
local HINTS = { " ⏎ diff · s/u stage · x discard · c commit · ⇥ fold · g? help ", " s/u stage · c commit · g? help ", " g? help " }

-- The longest key hint that fits the list's bottom border.
local function hint(width)
  for _, h in ipairs(HINTS) do
    if vim.fn.strdisplaywidth(h) + 2 <= width then return { { h, "AosFaint" } } end
  end
  return ""
end
local FLOAT_KEYS = { { "q", "close" }, { "<Esc>", "close" } }

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "git" }) end
local function visible() return S.win ~= nil and vim.api.nvim_win_is_valid(S.win) end

-- Read-only output float, ` ❯ title `; q/<Esc> closes it.
local function float(title, text)
  local lines = vim.split(vim.trim(text) ~= "" and vim.trim(text) or "✓ no output", "\n", { plain = true })
  local width, height = 20, math.min(#lines, vim.o.lines - 8)
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 2) end
  width = math.min(width, vim.o.columns - 8)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden = false, "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height, row = math.floor((vim.o.lines - height) / 3),
    col = math.floor((vim.o.columns - width) / 2), title = " ❯ " .. title .. " ", title_pos = "left", zindex = 60,
  })
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn, vim.wo[win].wrap = false, false, "no", true
  for _, k in ipairs(FLOAT_KEYS) do vim.keymap.set("n", k[1], "<cmd>close<cr>", { buffer = buf, nowait = true, desc = k[2] }) end
end

local function data(list) return vim.tbl_map(function(k) return { k[1], k[3] } end, list) end

local function fail(what, err) float(what .. " · failed", "✗ " .. what .. "\n\n" .. err) end

local function paused() return S.err and (S.err:find("timed out", 1, true) or S.err:find("paused", 1, true)) end

local function current_root()
  local file = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == "" and file ~= "" then return repo.root(file) end
  return repo.root(vim.fn.getcwd())
end

-- Rendering ----------------------------------------------------------------------------------

local function line(ctx, chunks, row, right)
  local text, l = "", #ctx.lines
  for _, c in ipairs(chunks) do
    if c[2] then ctx.hls[#ctx.hls + 1] = { l, #text, #text + #c[1], c[2] } end
    text = text .. c[1]
  end
  ctx.lines[l + 1], ctx.rows[l + 1], ctx.right[l + 1] = text, row or {}, right
end

local function name_hl(e) return e.letter == "D" and "AosScmDeleted" or LETTER_HL[e.letter] end

local function file_row(ctx, sec, e, depth)
  local name = vim.fs.basename(e.path)
  local icon, ihl = icons.get_icon(name, nil, { default = true })
  local label = name
  if e.orig then label = (vim.fs.dirname(e.orig) == vim.fs.dirname(e.path) and vim.fs.basename(e.orig) or e.orig) .. " → " .. name end
  local dir = vim.fs.dirname(e.path)
  line(ctx, {
    { string.rep("  ", depth + 1) }, { icon .. " ", ihl }, { label, name_hl(e) },
    { not ctx.tree and dir ~= "." and "  " .. dir or "", "AosDim" },
  }, { kind = "file", section = sec, entries = { e }, entry = e }, { e.letter, LETTER_HL[e.letter] })
end

local function child(node, name)
  local path = node.path and node.path .. "/" .. name or name
  node.dirs[name] = node.dirs[name] or { name = name, path = path, dirs = {}, files = {}, all = {} }
  return node.dirs[name]
end

local function build(entries)
  local top = { dirs = {}, files = {}, all = entries }
  for _, e in ipairs(entries) do
    local node, dir = top, vim.fs.dirname(e.path)
    for part in (dir == "." and "" or dir):gmatch("[^/]+") do
      node = child(node, part)
      table.insert(node.all, e)
    end
    table.insert(node.files, e)
  end
  return top
end

-- A folder holding only one folder is drawn as one row (`a/b/c`), like VS Code's compact folders.
local function only_dir(node)
  local name = next(node.dirs)
  if #node.files == 0 and name and next(node.dirs, name) == nil then return node.dirs[name] end
end

local function render_node(ctx, sec, node, depth)
  local names = vim.tbl_keys(node.dirs)
  table.sort(names)
  for _, name in ipairs(names) do
    local d, label = node.dirs[name], name
    while only_dir(d) do
      d = only_dir(d)
      label = label .. "/" .. d.name
    end
    local key = sec .. ":" .. d.path
    line(ctx, { { string.rep("  ", depth + 1) .. (S.collapsed[key] and "▸ " or "▾ "), "AosDim" }, { label, "AosArg" } },
      { kind = "dir", section = sec, key = key, entries = d.all })
    if not S.collapsed[key] then render_node(ctx, sec, d, depth + 1) end
  end
  for _, e in ipairs(node.files) do file_row(ctx, sec, e, depth) end
end

local function section(ctx, sec)
  local list = S.status[sec.key]
  if #list == 0 and not sec.always then return end
  local folded = S.collapsed[sec.key]
  line(ctx, { { folded and "▸ " or "▾ ", "AosDim" }, { sec.title, "Bold" } },
    { kind = "header", section = sec.key, key = sec.key, entries = list }, { tostring(#list), "AosDim" })
  if folded then return end
  if ctx.tree then return render_node(ctx, sec.key, build(list), 0) end
  for _, e in ipairs(list) do file_row(ctx, sec.key, e, 0) end
end

local function head_name(s)
  if s.branch then return s.branch end
  return s.oid and s.oid ~= "(initial)" and s.oid:sub(1, 8) or "HEAD"
end

local function header(ctx)
  local s, chunks = S.status, {}
  if s then
    vim.list_extend(chunks, { { s.branch and " " or " detached ", s.branch and "AosId" or "AosSha" }, { head_name(s), s.branch and "AosId" or "AosSha" } })
    if s.upstream then vim.list_extend(chunks, { { ("  ↑%d ↓%d"):format(s.ahead or 0, s.behind or 0), "AosSha" }, { "  " .. s.upstream, "AosDim" } }) end
  end
  line(ctx, chunks, { kind = "head" })
end

-- The running push/pull/fetch and its seconds after the header, redrawn each second without a re-render.
local function busy_mark()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, busy_ns, 0, -1)
  if not S.busy then return end
  local text = ("  ◆ %s %ds"):format(S.busy.label, math.floor((vim.uv.now() - S.busy.at) / 1000))
  vim.api.nvim_buf_set_extmark(S.buf, busy_ns, 0, 0, { virt_text = { { text, "AosRunning" } }, virt_text_pos = "eol" })
end

local function message_row(ctx)
  local first = S.draft:match("^[^\n]*")
  if first == "" then
    local where = S.status.branch and ("'%s'"):format(S.status.branch) or "detached HEAD"
    return line(ctx, { { "❯ ", "AosPrompt" }, { ("Message (⏎ commit on %s)"):format(where), "AosFaint" } }, { kind = "message" })
  end
  line(ctx, { { "❯ ", "AosPrompt" }, { first }, { S.draft:find("\n") and " …" or "", "AosDim" } }, { kind = "message" })
end

local function contents()
  local ctx = { lines = {}, rows = {}, right = {}, hls = {}, tree = S.tree }
  if not S.root then
    line(ctx, { { "○ ", "AosDim" }, { "not a git repository", "AosDim" } })
    line(ctx, { { "  " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~"), "AosArg" } })
    line(ctx, { { "  :Git init", "AosFaint" } })
    return ctx
  end
  header(ctx)
  if not S.status then
    if paused() then
      line(ctx, { { "○ status paused", "AosSha" } })
      line(ctx, { { "  slow repo", "AosDim" } })
      return ctx
    end
    line(ctx, { { S.err and "✗ " .. vim.trim(S.err):gsub("\n.*", "") or "◆ git status", S.err and "AosFailed" or "AosRunning" } })
    return ctx
  end
  message_row(ctx)
  line(ctx, { { "" } }, { kind = "blank" })
  for _, sec in ipairs(SECTIONS) do section(ctx, sec) end
  return ctx
end

local function ident(row)
  if not row then return end
  return row.entry and row.section .. ":" .. row.entry.path or row.key or row.kind
end

local function find_row(rows, id, path)
  local by_path
  for i, row in ipairs(rows) do
    if id and ident(row) == id then return i end
    if path and not by_path and row.entry and row.entry.path == path then by_path = i end
  end
  return by_path
end

local function first_file(rows)
  for i, row in ipairs(rows) do
    if row.kind == "file" then return i end
  end
  return 1
end

local function has_changes(s) return s and #s.changes + #s.staged + #s.conflicts > 0 end

local function listed(key)
  for _, r in ipairs(S.rows) do
    if r.entry and key == S.root .. ":" .. r.section .. ":" .. r.entry.path then return true end
  end
end

-- The diff's file left its section (staged or reverted outside nvim): show where it went, else that it is clean.
local function follow()
  local path = diff.path()
  if not path or not S.status then return end
  for _, sec in ipairs(SECTIONS) do
    for _, e in ipairs(S.status[sec.key]) do
      if e.path == path then return diff.show(S.root, e, sec.key) end
    end
  end
  diff.message("○ " .. path .. " · no changes")
end

local function preview(focus)
  if not visible() then return end
  local row = S.rows[vim.api.nvim_win_get_cursor(S.win)[1]]
  if row and row.entry then return diff.show(S.root, row.entry, row.section, { focus = focus }) end
  if listed(diff.key()) then return diff.reload() end
  local msg = not S.root and "○ not a git repository" or not S.status and (paused() and "○ status paused · slow repo" or "◆ git status")
  diff.message(msg or has_changes(S.status) and "○ no file under the cursor" or "✓ working tree clean")
end

-- The row to land on after a redraw: a requested one (reopen, <leader>gd), else the same row, else the same
-- path in another section, else the same line.
local function landing(rows)
  local want, lnum = S.want, vim.api.nvim_win_get_cursor(S.win)[1]
  if want and S.status then S.want = nil end
  local cur = S.rows[lnum]
  local from = want or { id = ident(cur), path = cur and cur.entry and cur.entry.path, lnum = lnum }
  local i = find_row(rows, from.id, from.path)
  if want and want.focus and S.status and not i then notify("○ " .. want.path .. " · no changes") end
  return i or from.lnum and math.min(from.lnum, #rows) or first_file(rows), want and want.focus and i
end

-- Cuts `text` to `max` display cells, ending in …; returns the new text.
local function clip(text, max)
  if vim.fn.strdisplaywidth(text) <= max then return text end
  local n = vim.fn.strchars(text)
  while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, n)) > max - 1 do n = n - 1 end
  return vim.fn.strcharpart(text, 0, n) .. "…"
end

-- Long rows end in … before their right-aligned letter or count instead of running under it.
local function fit(ctx)
  local width = vim.api.nvim_win_get_width(S.win)
  for l, text in ipairs(ctx.lines) do
    local r = ctx.right[l]
    local cut = clip(text, width - (r and vim.fn.strdisplaywidth(r[1]) + 2 or 0))
    if cut ~= text then ctx.lines[l], ctx.cut[l] = cut, #cut - #"…" end
  end
  for _, h in ipairs(ctx.hls) do
    local limit = ctx.cut[h[1] + 1]
    if limit then h[2], h[3] = math.min(h[2], limit), math.min(h[3], limit) end
  end
end

local function render()
  if not visible() then return end
  local ctx = contents()
  ctx.cut = {}
  fit(ctx)
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, ctx.lines)
  vim.bo[S.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for _, h in ipairs(ctx.hls) do vim.hl.range(S.buf, ns, h[4], { h[1], h[2] }, { h[1], h[3] }) end
  for l, r in pairs(ctx.right) do vim.api.nvim_buf_set_extmark(S.buf, ns, l - 1, 0, { virt_text = { r }, virt_text_pos = "right_align" }) end
  busy_mark()
  local target, focus = landing(ctx.rows)
  S.rows = ctx.rows
  vim.api.nvim_win_set_cursor(S.win, { target, 0 })
  if focus or not vim.tbl_contains(diff.wins(), vim.api.nvim_get_current_win()) then return preview(focus) end
  if listed(diff.key()) then return diff.reload() end
  follow()
end

-- Refresh and watchers ---------------------------------------------------------------------

local watch_dirs

-- One status run at a time: a refresh asked for meanwhile runs once when it is back.
local function refresh()
  if not visible() then return end
  local root = S.root
  if not root then return render() end
  if S.inflight then S.again = true return end
  S.inflight, S.again = true, false
  repo.status(root, function(s, err)
    S.inflight = false
    if root ~= S.root then return refresh() end
    S.status, S.err = s, err
    render()
    watch_dirs()
    if S.again then refresh() end
  end)
end

M.refresh = refresh

local function schedule()
  if not visible() then return end
  timer:stop()
  timer:start(200, 0, vim.schedule_wrap(refresh))
end

-- Agents write outside nvim: a change in the root or a listed file's directory refreshes within ~1 s, at most once a second.
local function on_tree_event()
  if not visible() or wtimer:is_active() then return end
  wtimer:start(1000, 0, vim.schedule_wrap(refresh))
end

local function dir_watch(dir)
  local w = vim.uv.new_fs_event()
  local ok = w and w:start(dir, {}, function(err, name)
    if not err and name ~= ".git" then vim.schedule(on_tree_event) end
  end)
  if ok then return w end
  if w then w:close() end
end

local function close_dirs(keep)
  for dir, w in pairs(S.dirs) do
    if not (keep and keep[dir]) then
      if not w:is_closing() then w:close() end
      S.dirs[dir] = nil
    end
  end
end

watch_dirs = function()
  if not (S.root and S.status and visible()) then return end
  local want = { [S.root] = true }
  for _, sec in ipairs(SECTIONS) do
    for _, e in ipairs(S.status[sec.key]) do want[vim.fs.dirname(S.root .. "/" .. e.path)] = true end
  end
  close_dirs(want)
  local n = vim.tbl_count(S.dirs)
  for dir in pairs(want) do
    if not S.dirs[dir] and n < MAX_DIRS then S.dirs[dir], n = dir_watch(dir), n + 1 end
  end
end

local function unwatch()
  if S.watcher and not S.watcher:is_closing() then S.watcher:close() end
  S.watcher = nil
  close_dirs()
  wtimer:stop()
end

local function watch(root)
  unwatch()
  repo.run({ "rev-parse", "--absolute-git-dir" }, root, function(ok, out)
    if not ok or S.root ~= root or S.watcher or not visible() then return end
    S.watcher = vim.uv.new_fs_event()
    S.watcher:start(vim.trim(out), {}, function(err, name)
      if err or (name or ""):match("%.lock$") then return end
      vim.schedule(schedule)
    end)
  end, { feature = "status" })
end

local function set_root(root)
  if root ~= S.root then S.root, S.status, S.err = root, nil, nil end
  unwatch()
  if root then watch(root) end
end

-- Actions ------------------------------------------------------------------------------------

local function run(args, what, done)
  repo.run(args, S.root, function(ok, out, err)
    if not ok then fail(what, err ~= "" and err or out) end
    if done and ok then done(out) end
    refresh()
  end, { feature = "scm" })
end

local function paths(entries, with_orig)
  local out = { "--" }
  for _, e in ipairs(entries) do
    out[#out + 1] = e.path
    if with_orig and e.orig then out[#out + 1] = e.orig end
  end
  return out
end

local function cmd(args, entries, with_orig)
  return vim.list_extend(vim.list_extend({ "--literal-pathspecs" }, args), paths(entries, with_orig))
end

-- Rows → { section = entries } without duplicates (a header covers its whole section, a folder its files).
local function collect(rows)
  local out, seen = { conflicts = {}, staged = {}, changes = {} }, {}
  for _, row in ipairs(rows) do
    for _, e in ipairs(row.entries or {}) do
      local id = row.section .. ":" .. e.path
      if not seen[id] then table.insert(out[row.section], e) end
      seen[id] = true
    end
  end
  return out
end

local function confirm(prompt, yes, fn)
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then fn() end
  end)
end

local function has_markers(e)
  local ok, lines = pcall(vim.fn.readfile, S.root .. "/" .. e.path)
  for _, l in ipairs(ok and lines or {}) do
    if l:match("^<<<<<<< ") or l:match("^>>>>>>> ") then return true end
  end
  return false
end

local function stage(sel)
  local list = vim.list_extend(vim.list_extend({}, sel.changes), sel.conflicts)
  if #list == 0 then return notify("○ nothing to stage") end
  local marked = vim.tbl_filter(has_markers, sel.conflicts)
  if #marked == 0 then return run(cmd({ "add" }, list), "git add") end
  local what = #marked == 1 and marked[1].path or #marked .. " files"
  confirm(("Stage %s with merge conflicts?"):format(what), "Stage", function() run(cmd({ "add" }, list), "git add") end)
end

local function unstage(sel)
  if #sel.staged == 0 then return notify("○ nothing to unstage") end
  local initial = S.status.oid == "(initial)"
  local args = initial and { "rm", "--cached", "-f", "--quiet" } or { "restore", "--staged" }
  run(cmd(args, sel.staged, true), initial and "git rm --cached" or "git restore --staged")
end

-- Loaded buffers by real path: a symlinked checkout names the same file differently.
local function loaded_bufs()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if vim.api.nvim_buf_is_loaded(b) and name ~= "" then out[vim.uv.fs_realpath(name) or name] = b end
  end
  return out
end

local function buf_for(bufs, e)
  local path = S.root .. "/" .. e.path
  return bufs[vim.uv.fs_realpath(path) or path]
end

-- Discard also reverts the open editor, or a later :w would write the discarded edits back.
local function reload_bufs(list)
  local bufs = loaded_bufs()
  for _, e in ipairs(list) do
    local b = buf_for(bufs, e)
    if b then vim.api.nvim_buf_call(b, function() vim.cmd("silent edit!") end) end
  end
end

-- From a window showing it: nvim_buf_delete quietly keeps a buffer that fills the last ordinary window.
local function wipe(b)
  local w = vim.fn.win_findbuf(b)[1]
  if not w then return pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  vim.api.nvim_win_call(w, function() vim.cmd("silent! bwipeout! " .. b) end)
end

local function delete_untracked(list)
  local bufs = loaded_bufs()
  for _, e in ipairs(list) do
    local b = buf_for(bufs, e)
    local ok, err = os.remove(S.root .. "/" .. e.path)
    if not ok then fail("delete " .. e.path, err) end
    if ok and b and diff.key() == S.root .. ":changes:" .. e.path then diff.message("○ " .. e.path .. " deleted") end
    if ok and b then wipe(b) end
  end
  refresh()
end

local function discard(sel)
  local tracked, untracked = {}, {}
  for _, e in ipairs(sel.changes) do table.insert(e.letter == "U" and untracked or tracked, e) end
  if #sel.staged > 0 and #sel.changes == 0 then return notify("○ staged changes: unstage (u) first, then discard") end
  if #tracked + #untracked == 0 then return notify("○ nothing to discard") end
  local what = #tracked + #untracked == 1 and (tracked[1] or untracked[1]).path or (#tracked + #untracked) .. " files"
  local prompt = #untracked > 0 and ("Discard changes and DELETE untracked in %s? This is irreversible"):format(what)
    or ("Discard changes in %s?"):format(what)
  confirm(prompt, "Discard", function()
    if #tracked > 0 then run(cmd({ "restore", "--worktree" }, tracked), "git restore", function() reload_bufs(tracked) end) end
    if #untracked > 0 then delete_untracked(untracked) end
  end)
end

-- <C-c>, or the same key again: a running push/pull/fetch is killed after a y/n.
local function cancel()
  local b = S.busy
  if not b then return notify("○ nothing to cancel") end
  if vim.fn.confirm(("cancel %s?"):format(b.verb), "&yes\n&no", 2) ~= 1 or S.busy ~= b then return end
  b.cancelled = true
  vim.uv.kill(-b.job.pid, "sigterm")
end

local function remote(verb, label)
  if not S.root then return end
  if S.busy and S.busy.verb == verb then return cancel() end
  if S.busy then return notify("◆ " .. S.busy.label .. " already running") end
  local s, args = S.status or {}, { verb }
  if verb == "pull" then args = { "pull", "--ff-only" } end
  if verb == "push" and s.branch and not s.upstream then args = { "push", "--set-upstream", "origin", s.branch } end
  local b = { verb = verb, label = label, at = vim.uv.now() }
  S.busy = b
  busy_mark()
  btimer:start(1000, 1000, vim.schedule_wrap(busy_mark))
  b.job = repo.run(args, S.root, function(ok, out, err)
    S.busy = nil
    btimer:stop()
    busy_mark()
    if b.cancelled then
      notify("○ git " .. verb .. " cancelled")
      return refresh()
    end
    local last = vim.trim(err .. out):match("([^\n]*)$")
    if ok then notify("✓ git " .. verb .. (last ~= "" and " · " .. vim.trim(last) or "")) end
    if not ok then fail("git " .. verb, err ~= "" and err or out) end
    refresh()
  end, { feature = verb })
end

-- Commit -------------------------------------------------------------------------------------

local function do_commit(root, msg, amend, done)
  local args = { "commit", "-F", "-" }
  if amend then args[#args + 1] = "--amend" end
  repo.run(args, root, function(ok, out, err)
    if not ok then return fail("git commit", vim.trim(err .. "\n" .. out)) end
    notify("✓ " .. vim.split(vim.trim(out), "\n")[1])
    done()
    refresh()
  end, { stdin = msg, feature = "commit" })
end

local function stage_all_and_commit(root, msg, done)
  repo.run({ "add", "-A" }, root, function(ok, _, err)
    if not ok then return fail("git add -A", err) end
    do_commit(root, msg, false, done)
  end, { feature = "commit" })
end

-- VS Code's smart commit: with nothing staged, offer to stage everything first.
local function commit(root, msg, amend, done)
  if vim.trim(msg) == "" then return notify("○ empty commit message", vim.log.levels.WARN) end
  if amend then return do_commit(root, msg, true, done) end
  repo.status(root, function(s)
    if not s then return notify("✗ git status failed", vim.log.levels.ERROR) end
    if #s.conflicts > 0 then return notify("✗ resolve merge conflicts first (s on a Merge Changes row marks it resolved)", vim.log.levels.WARN) end
    if #s.staged > 0 then return do_commit(root, msg, false, done) end
    if #s.changes == 0 then return notify("○ nothing to commit") end
    confirm("Stage all changes and commit?", "Stage all and commit", function() stage_all_and_commit(root, msg, done) end)
  end)
end

local COMMIT_KEYS = {
  { "<C-s>", "submit", "commit (also :w)", { "n", "i" } },
  { "q", "close", "cancel (keeps the message as a draft)" },
  { "<Esc>", "close", "cancel (keeps the message as a draft)" },
}

local function editor(root, amend, text)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, "gitscm://" .. (amend and "amend" or "commit") .. "/" .. buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "acwrite", "wipe", false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modified, vim.bo[buf].filetype = false, "gitcommit"
  local width, height = math.min(76, vim.o.columns - 6), math.min(12, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height, row = math.floor((vim.o.lines - height) / 3), col = math.floor((vim.o.columns - width) / 2),
    title = amend and " ❯ commit --amend " or " ❯ commit ", title_pos = "left", footer = " <C-s> commit · q cancel ", footer_pos = "right",
    zindex = 45,
  })
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn, vim.wo[win].wrap = false, false, "no", true
  local function text_now() return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")) end
  local function close()
    if not amend then S.draft = text_now() end
    pcall(vim.api.nvim_win_close, win, true)
    if not visible() then return end
    vim.api.nvim_set_current_win(S.win)
    render()
  end
  local function submit()
    vim.cmd.stopinsert()
    commit(root, text_now(), amend, function()
      if not amend then S.draft = "" end
      amend = true -- the draft is spent; closing must not restore it
      close()
    end)
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
  local act = { submit = submit, close = close }
  for _, k in ipairs(COMMIT_KEYS) do vim.keymap.set(k[4] or "n", k[1], act[k[2]], { buffer = buf, nowait = true, desc = k[3] }) end
  if text == "" then vim.cmd.startinsert() end
end

function M.commit(amend)
  local root = S.root and visible() and S.root or current_root()
  if not root then return notify("○ not a git repository") end
  if not amend then return editor(root, false, S.draft) end
  repo.run({ "log", "-1", "--format=%B" }, root, function(ok, out)
    if not ok then return notify("○ nothing to amend: no commits yet") end
    editor(root, true, vim.trim(out))
  end, { feature = "commit" })
end

-- Popup ------------------------------------------------------------------------------------

local function row_at(lnum) return S.rows[lnum or vim.api.nvim_win_get_cursor(0)[1]] end

-- The popup is ~90% x 85% of the editor: the list takes 35% on the left, the diff pane the rest.
local function rects()
  local lines = vim.o.lines - vim.o.cmdheight
  local width, height = math.floor(vim.o.columns * 0.9), math.floor(lines * 0.85)
  local row, col, lw = math.floor((lines - height) / 2), math.floor((vim.o.columns - width) / 2), math.floor(width * 0.35)
  local list = { relative = "editor", row = row, col = col, width = lw - 2, height = height - 2, zindex = 40 }
  return list, { row = row, col = col + lw, width = width - lw, height = height }
end

local function focus(dir)
  local wins = vim.list_extend({ S.win }, diff.wins())
  local cur = vim.api.nvim_get_current_win()
  local i = 1
  for n, w in ipairs(wins) do
    if w == cur then i = n end
  end
  local j = dir == 0 and (i == 1 and #wins or 1) or math.max(1, math.min(#wins, i + dir))
  vim.api.nvim_set_current_win(wins[j])
end

local function open_file(e)
  local path = S.root .. "/" .. e.path
  if not vim.uv.fs_stat(path) then return notify("○ " .. e.path .. " is deleted") end
  M.close()
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local function toggle_fold(row)
  S.collapsed[row.key] = not S.collapsed[row.key] or nil
  render()
end

local function merge(e)
  local root = S.root
  M.close()
  require("git.merge").open({ root = root, path = e.path, back = function() M.open({ root = root }) end })
end

local function activate()
  local row = row_at()
  if not row then return end
  if row.kind == "message" then return M.commit(false) end
  if row.key then return toggle_fold(row) end
  if row.section == "conflicts" then return merge(row.entry) end
  if row.entry then diff.show(S.root, row.entry, row.section, { focus = true }) end
end

local function on_rows(fn)
  return function()
    if not S.status then return end
    local mode = vim.fn.mode()
    if mode:match("[vV\22]") then
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.cmd("normal! \27")
      return fn(collect(vim.list_slice(S.rows, math.min(a, b), math.max(a, b))))
    end
    fn(collect({ row_at() }))
  end
end

local function tab()
  local r = row_at()
  if r and r.key then return toggle_fold(r) end
  focus(0)
end

local help

local KEYS = {
  { "<CR>", activate, "diff (focus it) · merge editor on a conflict · fold section · edit message" },
  { "o", activate, "diff (focus it) · merge editor on a conflict" },
  { "O", function() local r = row_at() if r and r.entry then open_file(r.entry) end end, "open file (closes the popup)" },
  { "<Tab>", tab, "fold section or folder · else focus the diff" },
  { "za", function() local r = row_at() if r and r.key then toggle_fold(r) end end, "fold / unfold section or folder" },
  { "<C-l>", function() focus(1) end, "focus the diff" },
  { "s", on_rows(stage), "stage row, section, folder or selection", { "n", "x" } },
  { "u", on_rows(unstage), "unstage row, section, folder or selection", { "n", "x" } },
  { "x", on_rows(discard), "discard changes (confirm)", { "n", "x" } },
  { "S", function() if S.status then stage(S.status) end end, "stage all changes" },
  { "U", function() if S.status then unstage(S.status) end end, "unstage all" },
  { "X", function() if S.status then discard({ staged = {}, conflicts = {}, changes = S.status.changes }) end end, "discard all changes (confirm)" },
  { "c", function() M.commit(false) end, "commit (smart: offers to stage all)" },
  { "C", function() M.commit(true) end, "amend last commit" },
  { "t", function() S.tree = not S.tree render() end, "toggle list / tree view" },
  { "p", function() remote("push", "pushing") end, "push" },
  { "P", function() remote("pull", "pulling") end, "pull --ff-only" },
  { "f", function() remote("fetch", "fetching") end, "fetch" },
  { "<C-c>", cancel, "cancel the running push / pull / fetch (also p / P / f again)" },
  { "r", function() refresh() end, "refresh" },
  { "q", function() M.close() end, "close" },
  { "<Esc>", function() M.close() end, "close" },
  { "g?", function() help() end, "this help" },
}

M.keys = {
  { section = "Source Control", keys = data(KEYS) },
  { section = "Commit editor", keys = data(COMMIT_KEYS) },
  { section = "Git output", keys = FLOAT_KEYS },
}

help = function()
  local lines = {}
  for _, sec in ipairs({ M.keys[1], diff.keys[1], require("git.merge").keys[1], M.keys[2], M.keys[3] }) do
    lines[#lines + 1] = "❯ " .. sec.section
    for _, k in ipairs(sec.keys) do lines[#lines + 1] = ("  %-11s %s"):format(k[1], k[2]) end
  end
  float("git keys", table.concat(lines, "\n"))
end

local function make_buf()
  S.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.buf].filetype = "gitscm"
  vim.b[S.buf].completion = false
  for _, k in ipairs(KEYS) do vim.keymap.set(k[4] or "n", k[1], k[2], { buffer = S.buf, nowait = true, desc = k[3] }) end
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = S.buf,
    callback = function()
      ptimer:stop()
      ptimer:start(60, 0, vim.schedule_wrap(function() preview(false) end))
    end,
  })
end

local function win_opts(w)
  local wo = vim.wo[w]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.list, wo.spell = false, false, "no", "0", false, false
  wo.cursorline, wo.wrap, wo.foldenable, wo.statuscolumn, wo.winbar = true, false, false, "", ""
end

function M.close()
  local win = S.win
  if not win then return end
  S.win = nil
  if vim.api.nvim_win_is_valid(win) then
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local row = S.rows[lnum]
    S.last = { id = ident(row), path = row and row.entry and row.entry.path, lnum = lnum }
    pcall(vim.api.nvim_win_close, win, true)
  end
  timer:stop()
  ptimer:stop()
  diff.close()
  unwatch()
  if S.origin and vim.api.nvim_win_is_valid(S.origin) then vim.api.nvim_set_current_win(S.origin) end
end

-- opts.path: land on that file's row and focus its diff (<leader>gd).
function M.open(opts)
  opts = opts or {}
  M.close()
  S.origin = vim.api.nvim_get_current_win()
  local root = opts.root or current_root()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then make_buf() end
  set_root(root)
  local list, rect = rects()
  S.win = vim.api.nvim_open_win(S.buf, true, vim.tbl_extend("force", list, {
    title = { { " ❯ ", "AosPrompt" }, { "git status ", "AosArg" } }, title_pos = "left",
    footer = hint(list.width), footer_pos = "right",
  }))
  win_opts(S.win)
  diff.attach(rect, { close = M.close, focus = focus, refresh = refresh })
  S.want = opts.path and { id = "changes:" .. opts.path, path = opts.path, focus = true } or S.last or {}
  render()
  refresh()
end

function M.toggle()
  if visible() then return M.close() end
  M.open()
end

-- <leader>gd: the popup on the current file's diff (Index ↔ Working Tree, else HEAD ↔ Index).
function M.diff_current()
  local file = vim.api.nvim_buf_get_name(0)
  local root = file ~= "" and vim.bo.buftype == "" and repo.root(file)
  if not root then return notify("○ not a file in a git repository") end
  M.open({ root = root, path = repo.relative(root, file) })
end

-- Shell-like words: '…' literal, "…" with \" \\ \$ \` escapes, \x outside quotes.
local function dquoted(s, i)
  local out = {}
  while i <= #s and s:sub(i, i) ~= '"' do
    local esc = s:sub(i, i) == "\\" and s:sub(i + 1, i + 1):match('["\\$`]')
    out[#out + 1] = esc or s:sub(i, i)
    i = i + (esc and 2 or 1)
  end
  return table.concat(out), i + 1
end

local function segment(s, i)
  local c = s:sub(i, i)
  if c == '"' then return dquoted(s, i + 1) end
  if c == "\\" then return s:sub(i + 1, i + 1), i + 2 end
  if c == "'" then
    local j = s:find("'", i + 1, true) or #s + 1
    return s:sub(i + 1, j - 1), j + 1
  end
  local j = s:find("[%s'\"\\]", i) or #s + 1
  return s:sub(i, j - 1), j
end

local function words(s)
  local out, i = {}, s:find("%S")
  while i do
    local word, seg = {}, nil
    while i <= #s and not s:sub(i, i):match("%s") do
      seg, i = segment(s, i)
      word[#word + 1] = seg
    end
    out[#out + 1] = table.concat(word)
    i = s:find("%S", i)
  end
  return out
end

-- `:Git <args>`: any git command, async, output in a float.
local function passthrough(args)
  local root = S.root and visible() and S.root or current_root() or vim.fn.getcwd()
  local title = "git " .. table.concat(args, " ")
  repo.run(args, root, function(ok, out, err)
    local text = vim.trim(out .. (err ~= "" and "\n" .. err or ""))
    if ok and text == "" then notify("✓ " .. title) else float(title, (ok and "" or "✗ failed\n\n") .. text) end
    if args[1] == "init" and visible() then set_root(repo.root(root) or S.root) end
    refresh()
  end, { feature = "git " .. args[1] })
end

local function is_popup(w)
  return w == S.win or vim.tbl_contains(diff.wins(), w)
end

local function close_if_left()
  local w = vim.api.nvim_get_current_win()
  if visible() and not is_popup(w) and vim.api.nvim_win_get_config(w).relative == "" then M.close() end
end

function M.setup()
  vim.api.nvim_create_user_command("Git", function(o)
    local args = words(o.args)
    if #args == 0 then return M.toggle() end
    passthrough(args)
  end, { nargs = "*", desc = "Source Control popup, or run git <args>" })
  vim.keymap.set("n", "<leader>gg", M.toggle, { desc = "Source Control" })
  vim.keymap.set("n", "<leader>gd", M.diff_current, { desc = "Diff current file" })
  vim.keymap.set("n", "<leader>gc", function() M.commit(false) end, { desc = "Git commit" })
  local group = vim.api.nvim_create_augroup("GitScm", {})
  local events = { "BufWritePost", "FocusGained", "ShellCmdPost", "TermLeave", "FileChangedShellPost", "DirChanged" }
  vim.api.nvim_create_autocmd(events, { group = group, callback = schedule })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not visible() then return end
      local list, rect = rects()
      vim.api.nvim_win_set_config(S.win, vim.tbl_extend("force", list, { footer = hint(list.width), footer_pos = "right" }))
      diff.resize(rect)
      render()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(a)
      if S.win and is_popup(tonumber(a.match)) then vim.schedule(M.close) end
    end,
  })
  -- Landing in an ordinary window (e.g. <C-w>p) closes the popup; other floats (commit, pickers) stack on it.
  -- Deferred: closing a stacked float passes through the window below before focus is handed back.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function() vim.schedule(close_if_left) end,
  })
end

return M
