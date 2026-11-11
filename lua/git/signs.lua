-- VS Code quick diff against the index: gutter hunks, peek/stage/revert/unstage, line and file blame,
-- and the branch status segment. Everything refreshes when the gitdir changes (commits made outside nvim).
local M = {}
local repo = require("git.repo")
local api = vim.api
local ns = api.nvim_create_namespace("git.signs")
local blame_ns = api.nvim_create_namespace("git.blame")
local bufs = {} -- buf -> { buf, root, rel, index = text | nil, hunks }
local dirs, waiting = {}, {} -- dir -> { root, gitdir } | false
local stats, watchers = {}, {}
local indices = { result_type = "indices", algorithm = "histogram" }
local fast = { result_type = "indices" }
-- Same cap as LSP and treesitter: past it every edit's re-diff costs over 50 ms (1.4 MiB: ~210 ms).
local MAX_BYTES = 512 * 1024

local function say(msg, hl) api.nvim_echo({ { msg, hl or "AosDim" } }, false, {}) end

-- Index text as { lines, eol, cr }: a missing final newline and CRLF endings survive a round trip.
-- Like nvim's 'fileformat' detection, an unterminated last line doesn't count, and mixed endings stay in the text.
local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then lines[#lines] = nil end
  local ended = eol and #lines or #lines - 1
  local cr = ended > 0
  for i = 1, ended do
    if lines[i]:sub(-1) ~= "\r" then cr = false break end
  end
  for i = 1, cr and ended or 0 do lines[i] = lines[i]:sub(1, -2) end
  return { lines = lines, eol = eol, cr = cr }
end

-- Diff input: always newline-terminated; with_eol puts a change of the final newline back.
local function join(t) return #t.lines == 0 and "" or table.concat(t.lines, "\n") .. "\n" end

-- 'eol' keeps what was read from disk; 'fixeol' adds the newline once the buffer is modified or written.
local function buf_eol(buf)
  local bo = vim.bo[buf]
  return bo.eol or bo.fixeol and not bo.binary and (bo.modified or vim.b[buf].git_written == true)
end

-- `cr`: the index copy's line endings, which lines added from the buffer take on.
local function buf_text(buf, cr)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then lines = {} end
  return { lines = lines, eol = buf_eol(buf), cr = cr }
end

-- join() hides a change of the final newline alone; like VS Code, it becomes a change of the last line.
local function with_eol(hunks, old, new)
  local last = hunks[#hunks]
  if old.eol == new.eol or #old.lines == 0 or #new.lines == 0 then return hunks end
  if last and (last[2] > 0 and last[1] + last[2] - 1 or last[1]) >= #old.lines then return hunks end
  hunks[#hunks + 1] = { #old.lines, 1, #new.lines, 1 }
  return hunks
end

-- Histogram costs ~10x Myers on big files (500 KiB: 23 ms vs 2 ms), so past 128 KiB the gutter uses Myers.
local function diff(old, new)
  local a, b = join(old), join(new)
  return with_eol(vim.text.diff(a, b, #b > 128 * 1024 and fast or indices) --[[@as integer[][] ]], old, new)
end

local function slice(lines, start, count) return count > 0 and vim.list_slice(lines, start, start + count - 1) or {} end

local function side(out, sign, lines, cr, noeol)
  for i, l in ipairs(lines) do out[#out + 1] = sign .. l .. (cr and not (noeol and i == #lines) and "\r" or "") end
  if noeol and #lines > 0 then out[#out + 1] = "\\ No newline at end of file" end
end

-- One zero-context hunk; c = { old_start, old_count, new_start, new_count }, where a count of 0 means "after start".
-- The + start is where the lines land after the earlier hunks of this patch only (delta), not in `new`.
-- Appending after an old last line that lacks its newline rewrites that line, so git adds the newline; deleting the
-- last lines of a file whose new end lacks one rewrites the line above, so git drops it.
local function hunk_lines(out, c, old, new, delta)
  local start, olds, news, new_last = c[1], slice(old.lines, c[1], c[2]), slice(new.lines, c[3], c[4]), c[3] + c[4] - 1
  if c[2] == 0 and c[1] > 0 and c[1] == #old.lines and not old.eol then
    olds, news = { old.lines[c[1]] }, vim.list_extend({ old.lines[c[1]] }, news)
  elseif c[4] == 0 and c[3] > 0 and c[3] == #new.lines and c[1] + c[2] - 1 == #old.lines and not new.eol then
    start, new_last = c[1] - 1, c[3]
    olds, news = vim.list_extend({ old.lines[start] }, olds), { new.lines[c[3]] }
  end
  local pos = (#olds > 0 and start - 1 or start) + delta
  local at_end = (#olds > 0 and start + #olds - 1 or start) >= #old.lines
  out[#out + 1] = ("@@ -%d,%d +%d,%d @@"):format(start, #olds, #news > 0 and pos + 1 or pos, #news)
  side(out, "-", olds, old.cr, at_end and not old.eol)
  side(out, "+", news, new.cr, at_end and new_last >= #new.lines and not new.eol)
end

local quotes = { ["\\"] = "\\\\", ['"'] = '\\"', ["\t"] = "\\t", ["\n"] = "\\n" }

-- Git's C-quoting; unquoted, git apply reads whatever follows a tab as a timestamp.
local function quote(path)
  if not path:find('[\t\n"\\]') then return path end
  return '"' .. path:gsub('[\\"\t\n]', quotes) .. '"'
end

-- Minimal unified patch turning `old` into `old` + only `changes` (for git apply --unidiff-zero).
local function patch(rel, old, new, changes)
  table.sort(changes, function(a, b) return a[1] < b[1] end)
  local a, b = quote("a/" .. rel), quote("b/" .. rel)
  local out, delta = { ("diff --git %s %s"):format(a, b), "--- " .. a, "+++ " .. b }, 0
  for _, c in ipairs(changes) do
    hunk_lines(out, c, old, new, delta)
    delta = delta + c[4] - c[2]
  end
  return table.concat(out, "\n") .. "\n"
end

-- Buffer lines a hunk covers; a deletion sits on the line above it.
local function span(h)
  if h[4] == 0 then return math.max(h[3], 1), math.max(h[3], 1) end
  return h[3], h[3] + h[4] - 1
end

local function hunk_at(hunks, lnum)
  for i, h in ipairs(hunks) do
    local a, b = span(h)
    if lnum >= a and lnum <= b then return h, i end
  end
end

-- VS Code's intersectDiffWithRange: equal-sized changes map line by line, others keep the whole old side.
local function intersect(h, l1, l2)
  local a, b = span(h)
  if l2 < a or l1 > b then return nil end
  if h[4] == 0 then return h end
  local s, e = math.max(l1, h[3]), math.min(l2, h[3] + h[4] - 1)
  if h[2] == 0 then return { h[1], 0, s, e - s + 1 } end
  if h[2] == h[4] then return { h[1] + s - h[3], e - s + 1, s, e - s + 1 } end
  return { h[1], h[2], s, e - s + 1 }
end

-- Gutter -------------------------------------------------------------------------------------

-- Drawn by the statuscolumn (M.column) in its own cell, so diagnostic signs never hide a hunk.
local gutter = {} -- buf -> { [lnum] = "%#GitAdd#▎" }

-- Conflict blocks (<<<<<<< … >>>>>>>) get a red bar over whatever hunk they sit in.
local function mark_conflicts(buf, rows)
  local inside = false
  for l, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    inside = inside or text:find("^<<<<<<<") ~= nil
    if inside then rows[l] = "%#GitDelete#▎%*" end
    if text:find("^>>>>>>>") then inside = false end
  end
end

local function place(buf, hunks, conflict)
  local rows, last = {}, api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local kind = h[2] == 0 and "GitAdd" or h[4] == 0 and "GitDelete" or "GitChange"
    local text = kind ~= "GitDelete" and "▎" or h[3] == 0 and "▔" or "▁"
    local first, final = span(h)
    for l = math.min(first, last), math.min(final, last) do rows[l] = "%#" .. kind .. "#" .. text .. "%*" end
  end
  if conflict then mark_conflicts(buf, rows) end
  gutter[buf] = rows
  pcall(api.nvim__redraw, { buf = buf, statuscolumn = true })
end

function M.column()
  local rows = vim.v.virtnum == 0 and gutter[api.nvim_get_current_buf()]
  return rows and rows[vim.v.lnum] or " "
end

local function update(buf)
  local st = bufs[buf]
  if not st or not api.nvim_buf_is_valid(buf) then return end
  st.hunks = st.index and not vim.b[buf].git_gutter_off and diff(st.index, buf_text(buf)) or {}
  place(buf, st.hunks, st.conflict)
end

local refresh_status
local reloads = {}

local function on_git_change(root)
  for _, loc in pairs(dirs) do
    if loc and loc.root == root then refresh_status(loc) break end
  end
  local pending, at = {}, 1
  for buf, st in pairs(bufs) do if st.root == root then pending[#pending + 1] = buf end end
  reloads[root] = (reloads[root] or 0) + 1
  local generation = reloads[root]
  local function batch()
    if reloads[root] ~= generation then return end
    local started = vim.uv.hrtime()
    while at <= #pending and vim.uv.hrtime() - started < 2000000 do
      local buf = pending[at]
      at = at + 1
      if api.nvim_buf_is_valid(buf) then M.reload(buf) end
    end
    if at <= #pending then vim.defer_fn(batch, 1) end
  end
  batch()
end

local change_timers = {}

-- `only`: react to that entry name alone (packed-refs in a linked worktree's busy common dir).
local function watch(path, root, only)
  if watchers[path] then return end
  change_timers[root] = change_timers[root] or assert(vim.uv.new_timer())
  local w, timer = assert(vim.uv.new_fs_event()), change_timers[root]
  local ok = w:start(path, {}, function(err, name)
    if err or (name and name:match("%.lock$")) or (only and name ~= only) then return end
    timer:start(120, 0, vim.schedule_wrap(function() on_git_change(root) end))
  end)
  if not ok then return w:close() end
  watchers[path] = w
end

-- A push from a shell only rewrites refs/remotes/<upstream>, below the (non-recursive) gitdir watch. While that dir
-- is missing (refs packed), the nearest parent and packed-refs are watched; the status refresh their events trigger
-- calls this again, which arms the precise watch once the dir exists.
local function watch_upstream(loc, upstream)
  local want = vim.fs.dirname(loc.common .. "/refs/remotes/" .. upstream)
  local dir = want
  while #dir > #loc.common and not vim.uv.fs_stat(dir) do dir = vim.fs.dirname(dir) end
  watch(dir, loc.root)
  if dir ~= want then watch(loc.common, loc.root, "packed-refs") end
end

local function resolved(dir, ok, out)
  local root, gitdir, common = unpack(vim.split(vim.trim(out), "\n"))
  dirs[dir] = ok and common and { root = root, gitdir = gitdir, common = common } or false
  if dirs[dir] then watch(gitdir, root) end
  for _, cb in ipairs(waiting[dir]) do cb(dirs[dir] or nil) end
  waiting[dir] = nil
end

-- Async, cached repo lookup for a directory: cb({ root, gitdir, common } | nil).
local function locate(dir, cb)
  if dirs[dir] ~= nil then return cb(dirs[dir] or nil) end
  if waiting[dir] then return table.insert(waiting[dir], cb) end
  waiting[dir] = { cb }
  local args = { "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" }
  repo.run(args, dir, function(ok, out) resolved(dir, ok, out) end, { feature = "repo lookup" })
end

-- The index copy, raw; mid-merge a conflicted path has no stage 0, so diff against ours (stage 2) like VS Code.
-- Any failure tries stage 2, since git's "not at stage 0" is translated under other locales.
local function read_index(root, rel, cb)
  local opts = { binary = true, feature = "gutter" }
  repo.run({ "show", ":" .. rel }, root, function(ok, out, _, cut)
    if ok or cut then return cb(ok and out or nil, false) end
    repo.run({ "show", ":2:" .. rel }, root, function(ours_ok, ours) cb(ours_ok and ours or nil, ours_ok) end, opts)
  end, opts)
end

local function track(buf, loc, file, cb)
  local rel = repo.relative(loc.root, file)
  read_index(loc.root, rel, function(text, conflict)
    if not api.nvim_buf_is_valid(buf) then return end
    bufs[buf] = { buf = buf, root = loc.root, rel = rel, index = text and split(text), conflict = conflict, hunks = {} }
    update(buf)
    if cb then cb() end
  end)
end

-- Re-reads the index copy of the buffer's file (untracked files get no signs), then rediffs.
function M.reload(buf, cb)
  local path = api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" or vim.b[buf].bigfile then return end
  local stat = vim.uv.fs_stat(path)
  vim.b[buf].git_gutter_off = stat and stat.size > MAX_BYTES or nil
  local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
  if not dir then return end
  locate(dir, function(loc)
    if loc and api.nvim_buf_is_valid(buf) then track(buf, loc, dir .. "/" .. vim.fs.basename(path), cb) end
  end)
end

-- Status segment ----------------------------------------------------------------------------

-- One status run per repo at a time; a request meanwhile runs once after it. A failed or cut run keeps the last state.
refresh_status = function(loc)
  if loc.pending then loc.again = true return end
  loc.pending = true
  repo.status(loc.root, function(s)
    loc.pending = nil
    if s then stats[loc.root] = s end
    if s and s.upstream then watch_upstream(loc, s.upstream) end
    vim.cmd.redrawtabline()
    if loc.again then loc.again = nil refresh_status(loc) end
  end)
end

-- Files created or deleted outside nvim touch neither HEAD nor the index, so poll while focused.
local poll = assert(vim.uv.new_timer())

local function poll_status()
  local loc = dirs[vim.fn.getcwd()]
  if not loc or loc.pending or repo.is_slow(loc.root, "status") then return end
  refresh_status(loc)
end

local function polling(on)
  if not on then return poll:stop() end
  poll:start(2000, 2000, vim.schedule_wrap(poll_status))
end

local function cwd_status()
  local cwd = vim.fn.getcwd()
  if dirs[cwd] == nil then locate(cwd, function(loc) if loc then refresh_status(loc) end end) end
  return dirs[cwd] and stats[dirs[cwd].root] or nil
end

function M.branch()
  local s = cwd_status()
  return s and (s.branch or (s.oid or ""):sub(1, 7)) or nil
end

-- VS Code's status bar: "main*+ ↑1↓2" (* unstaged, + staged, ! conflicts); a short sha when detached.
function M.status_text()
  local s = cwd_status()
  if not s then return nil end
  local text = M.branch() .. (#s.changes > 0 and "*" or "") .. (#s.staged > 0 and "+" or "") .. (#s.conflicts > 0 and "!" or "")
  local sync = (s.ahead > 0 and "↑" .. s.ahead or "") .. (s.behind > 0 and "↓" .. s.behind or "")
  return sync ~= "" and text .. " " .. sync or text
end

local function refresh_cwd()
  for dir, loc in pairs(dirs) do
    if loc == false then dirs[dir] = nil end
  end
  locate(vim.fn.getcwd(), function(loc) if loc then refresh_status(loc) end end)
end

-- Hunks: navigation, text object, stage/revert/unstage ----------------------------------------

---@return table?, integer
local function current()
  local buf = api.nvim_get_current_buf()
  local st = bufs[buf]
  if not st then return say("○ not tracked by git"), buf end
  update(buf)
  return st, buf
end

function M.nav(dir)
  local st = current()
  if not st then return end
  if #st.hunks == 0 then return say(vim.b.git_gutter_off and "○ gutter off · big file" or "○ no hunks") end
  local lnum, n, target = vim.fn.line("."), #st.hunks, nil
  for i = dir > 0 and 1 or n, dir > 0 and n or 1, dir do
    local start = span(st.hunks[i])
    if not target and (dir > 0 and start > lnum or dir < 0 and start < lnum) then target = i end
  end
  target = target or (dir > 0 and 1 or n)
  api.nvim_win_set_cursor(0, { span(st.hunks[target]), 0 })
  api.nvim_echo({ { "◆ hunk ", "AosDim" }, { ("%d/%d"):format(target, n), "AosSha" } }, false, {})
  return target
end

function M.select()
  local st = current()
  local h = st and hunk_at(st.hunks, vim.fn.line("."))
  if not h then return end
  local a, b = span(h)
  vim.cmd(("normal! %dGV%dG"):format(a, b))
end

-- Hunks under the cursor, or every part of a hunk inside l1..l2 (Stage/Revert Selected Ranges).
local function targets(st, l1, l2, lnum)
  if not l1 then return { (hunk_at(st.hunks, lnum)) } end
  local out = {}
  for _, h in ipairs(st.hunks) do out[#out + 1] = intersect(h, l1, l2) end
  return out
end

-- Zero-context hunks can't tell that the index moved (pure additions have no '-' lines to check),
-- so stage and unstage run one at a time per buffer, each building its patch from a fresh index read.
-- A reload that never calls back (repo lookup cut, buffer turned big) frees the buffer after 3 s; once the
-- operation has started, only its own token frees it (local writes always call back).
local busy = {}

local function release(token)
  if busy[token.buf] == token then busy[token.buf] = nil end
end

local function exclusive(buf, fn)
  if busy[buf] then return say("◆ still applying the last change") end
  local token = { buf = buf }
  busy[buf] = token
  vim.defer_fn(function()
    if busy[buf] ~= token or token.started then return end
    busy[buf] = nil
    say("○ skipped · git did not answer within 3 s")
    M.reload(buf)
  end, 3000)
  M.reload(buf, function()
    if busy[buf] ~= token then return end
    token.started = true
    fn(bufs[buf], token)
  end)
end

local function free(token, msg)
  release(token)
  say(msg)
end

local function apply(st, token, text, args, cb)
  local cmd = vim.list_extend({ "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn" }, args)
  repo.run(cmd, st.root, function(ok, _, err)
    release(token)
    if ok then return cb() end
    say("✗ " .. vim.trim(err), "AosFailed")
    M.reload(st.buf)
  end, { stdin = text })
end

local function stage_now(st, token, l1, l2, lnum, cb)
  local buf = token.buf
  if not st.index then return free(token, "○ not in the index: <leader>hS stages the file") end
  local changes = targets(st, l1, l2, lnum)
  if #changes == 0 then return free(token, "○ no hunk here") end
  apply(st, token, patch(st.rel, st.index, buf_text(buf, st.index.cr), changes), {}, function()
    say(("✓ staged %d %s"):format(#changes, #changes == 1 and "hunk" or "hunks"), "AosDone")
    M.reload(buf, cb)
  end)
end

local function conflicted(st)
  if st.conflict then say("○ conflicted · resolve the markers, then <leader>hS marks it resolved") end
  return st.conflict
end

function M.stage(l1, l2, cb)
  local st, buf = current()
  local lnum = vim.fn.line(".")
  if st and not conflicted(st) then exclusive(buf, function(fresh, token) stage_now(fresh, token, l1, l2, lnum, cb) end) end
end

function M.revert(l1, l2)
  local st, buf = current()
  if not st or not st.index then return end
  local changes = targets(st, l1, l2, vim.fn.line("."))
  table.sort(changes, function(a, b) return a[3] > b[3] end)
  -- Re-setting undolevels closes the undo block, so the revert is its own undo step.
  vim.bo[buf].undolevels = vim.bo[buf].undolevels
  for _, c in ipairs(changes) do
    local first = c[4] > 0 and c[3] or c[3] + 1
    api.nvim_buf_set_lines(buf, first - 1, first - 1 + c[4], false, slice(st.index.lines, c[1], c[2]))
    local at_end = c[1] + math.max(c[2], 1) - 1 >= #st.index.lines
    if at_end and buf_eol(buf) ~= st.index.eol then vim.bo[buf].eol, vim.bo[buf].fixeol = st.index.eol, st.index.eol end
  end
  update(buf)
  if #changes > 0 then say(("✓ reverted %d %s"):format(#changes, #changes == 1 and "hunk" or "hunks"), "AosDone") end
end

function M.stage_buffer()
  local st, buf = current()
  if not st then return end
  if vim.bo[buf].modified then vim.cmd("silent write") end
  repo.run({ "add", "--", st.rel }, st.root, function(ok, _, err)
    if not ok then return say("✗ " .. vim.trim(err), "AosFailed") end
    say("✓ staged " .. st.rel, "AosDone")
    M.reload(buf)
  end)
end

-- Buffer line -> index line, through the unstaged hunks above it.
local function to_index(hunks, lnum)
  local delta = 0
  for _, h in ipairs(hunks) do
    local a, b = span(h)
    if lnum < a then break end
    if lnum <= b then return h[1] end
    delta = delta + h[2] - h[4]
  end
  return lnum + delta
end

local function unstage_from(st, token, head, orig, lnum)
  local buf = token.buf
  local function done(msg)
    return function(ok, _, err)
      release(token)
      if ok == false then return say("✗ " .. vim.trim(err), "AosFailed") end
      say(msg, "AosDone")
      M.reload(buf)
    end
  end
  if not head then return repo.run({ "rm", "--cached", "-q", "--", st.rel }, st.root, done("✓ unstaged " .. st.rel)) end
  local base = split(head)
  local staged = diff(base, st.index)
  if #staged == 0 and orig then
    return repo.run({ "reset", "-q", "--", orig, st.rel }, st.root, done(("✓ unstaged rename %s → %s"):format(orig, st.rel)))
  end
  if #staged == 0 then return free(token, "○ nothing staged in " .. st.rel) end
  local h = hunk_at(staged, to_index(st.hunks, lnum)) or staged[#staged]
  apply(st, token, patch(st.rel, base, st.index, { h }), { "--reverse" }, done("✓ unstaged hunk"))
end

local function staged_orig(s, rel)
  for _, e in ipairs(s and s.staged or {}) do
    if e.path == rel and e.orig then return e.orig end
  end
end

local function show_head(st, path, cb)
  local opts = { binary = true, feature = "unstage" }
  repo.run({ "show", "HEAD:" .. path }, st.root, function(ok, out, _, cut) cb(ok and out or nil, cut) end, opts)
end

-- HEAD's copy of the file, following a staged rename: cb(text, orig, cut); text is nil for a file new in the index,
-- and `cut` means git was too slow to tell, so nothing may be unstaged.
local function head_text(st, cb)
  show_head(st, st.rel, function(text, cut)
    if text or cut then return cb(text, nil, cut) end
    repo.status(st.root, function(s)
      local orig = staged_orig(s, st.rel)
      if not orig then return cb(nil, nil, not s) end
      show_head(st, orig, function(old, old_cut) cb(old, orig, old_cut) end)
    end)
  end)
end

function M.unstage()
  local st, buf = current()
  local lnum = vim.fn.line(".")
  if not st or conflicted(st) then return end
  exclusive(buf, function(fresh, token)
    if not fresh.index then return free(token, "○ nothing staged in " .. fresh.rel) end
    head_text(fresh, function(head, orig, cut)
      if cut then return free(token, "○ skipped · git did not answer within 3 s") end
      unstage_from(fresh, token, head, orig, lnum)
    end)
  end)
end

-- Keys of this module's own popups (plain data for the hotkey help); each popup binds exactly these.
local KEYS = {
  peek = { section = "Hunk peek", keys = {
    { "s", "stage hunk" }, { "x", "revert hunk" }, { "]h", "next hunk" }, { "[h", "previous hunk" },
    { "q", "close" }, { "<Esc>", "close" },
  } },
  column = { section = "Blame column", keys = { { "<CR>", "show the line's commit" }, { "q", "close" } } },
  commit = { section = "Blame commit", keys = { { "q", "close" }, { "<Esc>", "close" } } },
}
M.keys = { KEYS.peek, KEYS.column, KEYS.commit }

local function bind(buf, section, actions)
  for _, k in ipairs(section.keys) do
    vim.keymap.set("n", k[1], actions[k[1]], { buffer = buf, nowait = true, desc = k[2] })
  end
end

-- " s stage hunk · … · q/<Esc> close ": neighbours with the same description share one entry.
local function footer(section)
  local parts = {}
  for _, k in ipairs(section.keys) do
    local last = parts[#parts]
    if last and last.desc == k[2] then last.lhs = last.lhs .. "/" .. k[1] else parts[#parts + 1] = { lhs = k[1], desc = k[2] } end
  end
  return " " .. table.concat(vim.tbl_map(function(p) return p.lhs .. " " .. p.desc end, parts), " · ") .. " "
end

-- Peek: the hunk's old and new lines in a float under it, with its own stage/revert/move keys --

local peek_win

local function close_peek()
  if peek_win and api.nvim_win_is_valid(peek_win) then api.nvim_win_close(peek_win, true) end
  peek_win = nil
end

local function peek_lines(st, buf, h)
  local old, new = slice(st.index.lines, h[1], h[2]), slice(api.nvim_buf_get_lines(buf, 0, -1, false), h[3], h[4])
  return vim.list_extend(vim.list_extend({}, old), new), #old
end

local function peek_buffer(src, lines, removed)
  local pbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  for i = 1, #lines do
    local del = i <= removed
    api.nvim_buf_set_extmark(pbuf, ns, i - 1, 0, {
      virt_text = { { del and "- " or "+ ", del and "GitDelete" or "GitAdd" } }, virt_text_pos = "inline",
      line_hl_group = del and "GitDeleteLine" or "DiffAdd",
    })
  end
  vim.bo[pbuf].modifiable, vim.bo[pbuf].bufhidden = false, "wipe"
  local lang = vim.treesitter.language.get_lang(vim.bo[src].filetype)
  if lang then pcall(vim.treesitter.start, pbuf, lang) end
  return pbuf
end

-- Runs `fn` back in the source window, then peeks again at the nearest remaining hunk.
local function peek_after(win, fn)
  return function()
    close_peek()
    api.nvim_set_current_win(win)
    fn(function()
      local st = bufs[api.nvim_get_current_buf()]
      if st and #st.hunks > 0 and not hunk_at(st.hunks, vim.fn.line(".")) then M.nav(1) end
      if st and #st.hunks > 0 then M.peek() end
    end)
  end
end

local function peek_keys(pbuf, win)
  bind(pbuf, KEYS.peek, {
    s = peek_after(win, function(cb) M.stage(nil, nil, cb) end),
    x = peek_after(win, function(cb) M.revert() cb() end),
    ["]h"] = peek_after(win, function() M.nav(1) M.peek() end),
    ["[h"] = peek_after(win, function() M.nav(-1) M.peek() end),
    q = close_peek, ["<Esc>"] = close_peek,
  })
end

function M.peek()
  local st, buf = current()
  if not st or not st.index then return end
  local h, i = hunk_at(st.hunks, vim.fn.line("."))
  if not h then return say("○ no hunk here") end
  close_peek()
  local lines, removed = peek_lines(st, buf, h)
  local win, pbuf = api.nvim_get_current_win(), peek_buffer(buf, lines, removed)
  local _, bottom = span(h)
  peek_win = api.nvim_open_win(pbuf, true, {
    relative = "win", win = win, bufpos = { bottom - 1, 0 }, row = 1, col = 0, style = "minimal",
    width = math.max(api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 2, 20), height = math.min(#lines, 20),
    title = (" ❯ hunk %d/%d "):format(i, #st.hunks), title_pos = "left",
    footer = footer(KEYS.peek), footer_pos = "right",
  })
  peek_keys(pbuf, win)
  local pwin = peek_win
  api.nvim_create_autocmd("WinLeave", {
    buffer = pbuf, once = true,
    callback = vim.schedule_wrap(function() if api.nvim_win_is_valid(pwin) then api.nvim_win_close(pwin, true) end end),
  })
end

-- Blame --------------------------------------------------------------------------------------

local blame = { on = false, seq = 0 }
local zero = ("0"):rep(40)

local function parse_blame(out)
  local commits, lines, cur = {}, {}, nil
  for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
    local sha, final = l:match("^(%x+) %d+ (%d+)")
    if sha and #sha == 40 then
      cur = commits[sha] or { sha = sha }
      commits[sha], lines[tonumber(final)] = cur, cur
    elseif cur and l:sub(1, 1) ~= "\t" then
      local k, v = l:match("^(%S+) (.*)$")
      if k and not cur[k] then cur[k] = v end
    end
  end
  return lines
end

local function ago(t)
  local d = os.time() - t
  for _, u in ipairs({ { 31536000, "y" }, { 2592000, "mo" }, { 604800, "w" }, { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if d >= u[1] then return ("%d%s ago"):format(math.floor(d / u[1]), u[2]) end
  end
  return "just now"
end

-- The buffer as blame --contents input, in the index copy's line endings (else CRLF files blame as uncommitted).
local function contents(buf)
  local lines, nl = buf_text(buf).lines, bufs[buf].index and bufs[buf].index.cr and "\r\n" or "\n"
  return #lines == 0 and "" or table.concat(lines, nl) .. nl
end

local function blame_args(st, extra)
  return vim.list_extend(vim.list_extend({ "blame", "--porcelain" }, extra), { "--contents", "-", "--", st.rel })
end

local function show_line_blame(buf, lnum, c)
  if not c or not api.nvim_buf_is_valid(buf) then return end
  local text = c.sha == zero and "You · uncommitted"
    or ("%s · %s · %s"):format(c.author or "?", ago(tonumber(c["author-time"]) or 0), vim.fn.strcharpart(c.summary or "", 0, 60))
  api.nvim_buf_clear_namespace(buf, blame_ns, 0, -1)
  api.nvim_buf_set_extmark(buf, blame_ns, lnum - 1, 0, { virt_text = { { "  " .. text, "AosFaint" } }, virt_text_pos = "eol", hl_mode = "combine" })
end

local function line_blame()
  local buf = api.nvim_get_current_buf()
  local st, lnum = bufs[buf], vim.fn.line(".")
  if not blame.on or not st or api.nvim_get_mode().mode ~= "n" or blame.at == buf .. ":" .. lnum then return end
  blame.seq, blame.at = blame.seq + 1, buf .. ":" .. lnum
  local seq = blame.seq
  local function done(ok, out, _, cut)
    if seq ~= blame.seq or cut then return end
    show_line_blame(buf, lnum, ok and parse_blame(out)[lnum] or { sha = zero })
  end
  blame.job = repo.run(blame_args(st, { "-L", lnum .. "," .. lnum }), st.root, done, { stdin = contents(buf), feature = "line blame" })
end

local function stop_line_blame()
  blame.at, blame.seq = nil, blame.seq + 1
  if blame.job and not blame.job:is_closing() then blame.job:kill(15) end
end

local function clear_line_blame(ev)
  if blame.at and blame.at == ev.buf .. ":" .. vim.fn.line(".") and ev.event == "CursorMoved" then return end
  stop_line_blame()
  api.nvim_buf_clear_namespace(ev.buf, blame_ns, 0, -1)
end

function M.toggle_blame()
  stop_line_blame()
  blame.on = not blame.on
  for _, b in ipairs(api.nvim_list_bufs()) do api.nvim_buf_clear_namespace(b, blame_ns, 0, -1) end
  say(blame.on and "● line blame on" or "○ line blame off", blame.on and "AosDone" or "AosDim")
  line_blame()
end

-- Full-file blame split ---------------------------------------------------------------------

local split_state -- { win, buf, src, swin }

local function age_hl(c)
  if c.sha == zero then return "AosRunning" end
  local days = (os.time() - (tonumber(c["author-time"]) or 0)) / 86400
  for i, limit in ipairs({ 7, 30, 180, 730 }) do
    if days < limit then return "GitBlameAge" .. (i - 1) end
  end
  return "GitBlameAge4"
end

local function blame_row(c)
  if c.sha == zero then return ("%-7s %-14s %s"):format("·······", "You", "uncommitted") end
  local author = vim.fn.strcharpart(c.author or "?", 0, 14)
  return ("%s %s%s %s"):format(c.sha:sub(1, 7), author, (" "):rep(14 - vim.fn.strchars(author)), os.date("%Y-%m-%d", tonumber(c["author-time"]) or 0))
end

local COLUMN_OPTS = {
  number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0", wrap = false,
  winfixwidth = true, cursorline = true, list = false, statuscolumn = "",
}

local function paint_row(s, l)
  local c, row = s.lines[l], api.nvim_buf_get_lines(s.buf, l - 1, l, false)[1]
  api.nvim_buf_clear_namespace(s.buf, blame_ns, l - 1, l)
  if not c or not row then return end
  local run = s.lines[l - 1] and s.lines[l - 1].sha == c.sha
  api.nvim_buf_set_extmark(s.buf, blame_ns, l - 1, 0, { end_col = #"▎", hl_group = age_hl(c) })
  api.nvim_buf_set_extmark(s.buf, blame_ns, l - 1, #"▎", { end_col = #row, hl_group = run and "AosFaint" or "AosDim" })
  if not run then api.nvim_buf_set_extmark(s.buf, blame_ns, l - 1, #"▎", { end_col = row:find(" ", 1, true) - 1, hl_group = age_hl(c) }) end
end

-- 'modifiable' set from another buffer fires OptionSet in the column's context, where the tabline would redraw.
local function set_rows(s, from, to, rows)
  local ei = vim.o.eventignore
  vim.opt.eventignore:append("OptionSet")
  vim.bo[s.buf].modifiable = true
  local ok, err = pcall(api.nvim_buf_set_lines, s.buf, from, to, false, rows)
  vim.bo[s.buf].modifiable = false
  vim.o.eventignore = ei
  assert(ok, err)
end

local function render_range(s, blamed, from, to)
  local rows = {}
  for l = from, to do
    s.lines[l], s.done[l] = blamed[l], true
    rows[#rows + 1] = blamed[l] and "▎" .. blame_row(blamed[l]) or ""
  end
  set_rows(s, from - 1, to, rows)
  for l = from, math.min(to + 1, s.count) do paint_row(s, l) end
end

local function pause_note(s, from)
  s.paused = true
  local row = math.max(from, vim.fn.getwininfo(s.swin)[1].topline)
  local note = { { "○ blame paused · slow repo", "AosDim" } }
  api.nvim_buf_set_extmark(s.buf, blame_ns, row - 1, 0, { virt_text = note, virt_text_pos = "overlay" })
end

-- The not yet blamed part of the visible source lines ± one screen: one blame call never covers more.
local function wanted(s)
  local info = vim.fn.getwininfo(s.swin)[1]
  local h = info.botline - info.topline + 1
  local a, b = math.max(1, info.topline - h), math.min(s.count, info.botline + h)
  while a <= b and s.done[a] do a = a + 1 end
  while b >= a and s.done[b] do b = b - 1 end
  if a <= b then return a, b end
end

-- Blames what scrolled into view; a run for a range the view left is killed first.
local function fill_split(s)
  if not s or split_state ~= s or s.paused or s.failed or s.contents == "" then return end
  if not api.nvim_win_is_valid(s.swin) or not bufs[s.src] then return end
  local from, to = wanted(s)
  if not from or (s.want and s.want[1] <= from and s.want[2] >= to) then return end
  if s.job then s.job:kill(15) end
  local st, seq = bufs[s.src], s.seq + 1
  s.seq, s.want = seq, { from, to }
  s.job = repo.run(blame_args(st, { "-L", from .. "," .. to }), st.root, function(ok, out, err, cut)
    if split_state ~= s or seq ~= s.seq or not api.nvim_buf_is_valid(s.buf) then return end
    s.job, s.want = nil, nil
    if cut then return pause_note(s, from) end
    if not ok then s.failed = true return say("✗ " .. vim.trim(err), "AosFailed") end
    render_range(s, parse_blame(out), from, to)
    fill_split(s)
  end, { stdin = s.contents, feature = "file blame" })
end

-- The source changed: keep the column as long as the source and re-blame from the visible lines out.
local function rerun_split()
  local s = split_state
  if not s or not api.nvim_win_is_valid(s.win) or not bufs[s.src] then return end
  if s.job then s.job:kill(15) end
  s.count, s.contents, s.lines, s.done = api.nvim_buf_line_count(s.src), contents(s.src), {}, {}
  s.seq, s.job, s.want, s.failed = s.seq + 1, nil, nil, nil
  local have = api.nvim_buf_line_count(s.buf)
  local keep = s.contents == "" and 0 or math.min(have, s.count)
  set_rows(s, keep, have, vim.fn["repeat"]({ "" }, s.count - keep))
  fill_split(s)
end

local function show_commit()
  local s = split_state
  local c = s and s.lines[vim.fn.line(".")]
  if not c or c.sha == zero then return say("○ not committed yet") end
  local st = bufs[s.src]
  repo.run({ "show", "--stat", "--patch", c.sha, "--", c.filename or st.rel }, st.root, function(ok, out)
    if not ok then return end
    local buf = api.nvim_create_buf(false, true)
    local lines = vim.split(out:gsub("\n$", ""), "\n", { plain = true })
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype, vim.bo[buf].modifiable, vim.bo[buf].bufhidden = "git", false, "wipe"
    local w, h = math.min(120, vim.o.columns - 8), math.min(#lines, vim.o.lines - 6)
    local win = api.nvim_open_win(buf, true, {
      relative = "editor", row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2), width = w, height = h,
      title = (" ❯ show · %s · %s "):format(c.sha:sub(1, 7), st.rel), title_pos = "left", footer = footer(KEYS.commit), footer_pos = "right",
    })
    local close = function() api.nvim_win_close(win, true) end
    bind(buf, KEYS.commit, { q = close, ["<Esc>"] = close })
  end, { feature = "blame commit" })
end

-- The column is the last window: show the source in it instead (quitting nvim here would trip E37/E173).
local function reuse_column(s)
  api.nvim_win_set_buf(s.win, api.nvim_buf_is_valid(s.src) and s.src or api.nvim_create_buf(true, false))
  for opt in pairs(COLUMN_OPTS) do vim.wo[s.win][0][opt] = vim.go[opt] end
  vim.wo[s.win][0].winbar, vim.wo[s.win][0].scrollbind, vim.wo[s.win][0].cursorbind = vim.go.winbar, false, false
end

local function close_split()
  local s = split_state
  split_state = nil
  if not s then return end
  if s.job then s.job:kill(15) end
  if api.nvim_win_is_valid(s.swin) then vim.wo[s.swin][0].scrollbind, vim.wo[s.swin][0].cursorbind = false, false end
  pcall(api.nvim_del_augroup_by_name, "GitBlameSplit")
  if api.nvim_win_is_valid(s.win) and not pcall(api.nvim_win_close, s.win, true) then reuse_column(s) end
end

local scroll_timer = assert(vim.uv.new_timer())

local function split_autocmds(src, swin, bwin)
  local group = api.nvim_create_augroup("GitBlameSplit", {})
  local au = function(ev, opts) api.nvim_create_autocmd(ev, vim.tbl_extend("force", { group = group }, opts)) end
  au("WinClosed", { pattern = { tostring(bwin), tostring(swin) }, callback = vim.schedule_wrap(close_split) })
  -- :q in the source window takes the column with it before Vim decides whether this is the last window.
  au("QuitPre", { callback = function() if api.nvim_get_current_win() == swin then close_split() end end })
  au("BufWinEnter", { callback = function(ev)
    if api.nvim_get_current_win() == swin and ev.buf ~= src then vim.schedule(close_split) end
  end })
  au({ "BufWritePost", "TextChanged", "InsertLeave" }, { buffer = src, callback = rerun_split })
  au({ "WinScrolled", "WinResized" }, { callback = function()
    scroll_timer:start(80, 0, vim.schedule_wrap(function() fill_split(split_state) end))
  end })
end

local function open_split(src, swin)
  local bbuf = api.nvim_create_buf(false, true)
  vim.bo[bbuf].bufhidden, vim.bo[bbuf].filetype = "wipe", "gitblame"
  local bwin = api.nvim_open_win(bbuf, false, { split = "left", win = swin, width = 36 })
  for opt, val in pairs(COLUMN_OPTS) do vim.wo[bwin][0][opt] = val end
  vim.wo[bwin][0].winbar = vim.wo[swin].winbar ~= "" and "%#AosPrompt#❯ %#AosArg#blame" or ""
  split_state = { win = bwin, buf = bbuf, src = src, swin = swin, lines = {}, done = {}, seq = 0 }
  for _, w in ipairs({ bwin, swin }) do vim.wo[w][0].scrollbind, vim.wo[w][0].cursorbind = true, true end
  bind(bbuf, KEYS.column, { ["<CR>"] = show_commit, q = close_split })
  split_autocmds(src, swin, bwin)
end

function M.blame_file()
  if split_state then return close_split() end
  local st, buf = current()
  if not st then return end
  if not st.index then return say("○ not in the index: nothing to blame") end
  local swin = api.nvim_get_current_win()
  open_split(buf, swin)
  rerun_split()
  api.nvim_win_call(swin, function() vim.cmd("syncbind") end)
end

-- Setup --------------------------------------------------------------------------------------

local timers = {}
local function debounced(ev)
  local buf = ev.buf
  timers[buf] = timers[buf] or vim.uv.new_timer()
  timers[buf]:start(150, 0, vim.schedule_wrap(function() update(buf) end))
end

local function range()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  return math.min(a, b), math.max(a, b)
end

local function keymaps()
  local map = vim.keymap.set
  map({ "n", "x", "o" }, "]h", function() M.nav(1) end, { desc = "Next hunk" })
  map({ "n", "x", "o" }, "[h", function() M.nav(-1) end, { desc = "Prev hunk" })
  map({ "o", "x" }, "ih", ":<C-u>lua require('git.signs').select()<CR>", { silent = true, desc = "Hunk" })
  map("n", "<leader>hp", M.peek, { desc = "Peek hunk" })
  map("n", "<leader>hs", function() M.stage() end, { desc = "Stage hunk" })
  map("x", "<leader>hs", function() M.stage(range()) end, { desc = "Stage selected lines" })
  map("n", "<leader>hS", M.stage_buffer, { desc = "Stage buffer" })
  map("n", "<leader>hr", function() M.revert() end, { desc = "Revert hunk" })
  map("x", "<leader>hr", function() M.revert(range()) end, { desc = "Revert selected lines" })
  map("n", "<leader>hu", M.unstage, { desc = "Unstage hunk" })
  map("n", "<leader>gB", M.toggle_blame, { desc = "Toggle line blame" })
  map("n", "<leader>gL", M.blame_file, { desc = "Blame file" })
end

function M.setup()
  keymaps()
  local group = api.nvim_create_augroup("GitSigns", {})
  local au = function(ev, cb, opts) api.nvim_create_autocmd(ev, vim.tbl_extend("force", { group = group, callback = cb }, opts or {})) end
  au({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, function(ev)
    vim.b[ev.buf].git_written = ev.event == "BufWritePost" or nil
    M.reload(ev.buf)
  end)
  au({ "TextChanged", "InsertLeave" }, debounced)
  au({ "BufWritePost", "FocusGained", "DirChanged", "ShellCmdPost" }, refresh_cwd)
  au("FocusGained", function() polling(true) end)
  au("FocusLost", function() polling(false) end)
  polling(true)
  au("CursorHold", line_blame)
  au({ "CursorMoved", "InsertEnter", "BufLeave" }, clear_line_blame)
  au("BufWipeout", function(ev)
    if timers[ev.buf] then timers[ev.buf]:close() end
    timers[ev.buf], bufs[ev.buf], gutter[ev.buf] = nil, nil, nil
  end)
end

return M
