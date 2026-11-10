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

local function say(msg, hl) api.nvim_echo({ { msg, hl or "AosDim" } }, false, {}) end

-- Index text as { lines, eol, cr }: a missing final newline and CRLF endings survive a round trip.
local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then lines[#lines] = nil end
  local cr = #lines > 0
  for _, l in ipairs(lines) do
    if l:sub(-1) ~= "\r" then cr = false break end
  end
  if cr then lines = vim.tbl_map(function(l) return l:sub(1, -2) end, lines) end
  return { lines = lines, eol = eol, cr = cr }
end

-- Diff input: always newline-terminated, so a missing final newline never makes a hunk of its own.
local function join(t) return #t.lines == 0 and "" or table.concat(t.lines, "\n") .. "\n" end

-- `cr`: the index copy's line endings, which lines added from the buffer take on.
local function buf_text(buf, cr)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then lines = {} end
  return { lines = lines, eol = vim.bo[buf].eol or vim.bo[buf].fixeol, cr = cr }
end

local function slice(lines, start, count) return count > 0 and vim.list_slice(lines, start, start + count - 1) or {} end

local function side(out, sign, lines, cr, noeol)
  for _, l in ipairs(lines) do out[#out + 1] = sign .. l .. (cr and "\r" or "") end
  if noeol and #lines > 0 then out[#out + 1] = "\\ No newline at end of file" end
end

-- One zero-context hunk; c = { old_start, old_count, new_start, new_count }, where a count of 0 means "after start".
-- The + start is where the lines land after the earlier hunks of this patch only (delta), not in `new`.
-- Appending after an old last line that lacks its newline rewrites that line, so git adds the newline.
local function hunk_lines(out, c, old, new, delta)
  local olds, news = slice(old.lines, c[1], c[2]), slice(new.lines, c[3], c[4])
  if c[2] == 0 and c[1] > 0 and c[1] == #old.lines and not old.eol then
    olds = { old.lines[c[1]] }
    news = vim.list_extend({ olds[1] }, news)
  end
  local pos = (#olds > 0 and c[1] - 1 or c[1]) + delta
  local at_end = (#olds > 0 and c[1] + #olds - 1 or c[1]) >= #old.lines
  out[#out + 1] = ("@@ -%d,%d +%d,%d @@"):format(c[1], #olds, #news > 0 and pos + 1 or pos, #news)
  side(out, "-", olds, old.cr, at_end and not old.eol)
  side(out, "+", news, new.cr, at_end and c[3] + c[4] - 1 >= #new.lines and not new.eol)
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

local function place(buf, hunks)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local last = api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local kind = h[2] == 0 and "GitAdd" or h[4] == 0 and "GitDelete" or "GitChange"
    local text = kind ~= "GitDelete" and "▎" or h[3] == 0 and "▔" or "▁"
    local first, final = span(h)
    for l = math.min(first, last), math.min(final, last) do
      api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { sign_text = text, sign_hl_group = kind, priority = 5 })
    end
  end
end

local function update(buf)
  local st = bufs[buf]
  if not st or not api.nvim_buf_is_valid(buf) then return end
  st.hunks = st.index and vim.text.diff(join(st.index), join(buf_text(buf)), indices) or {}
  place(buf, st.hunks)
end

local refresh_status

local function on_git_change(root)
  for _, loc in pairs(dirs) do
    if loc and loc.root == root then refresh_status(loc) break end
  end
  for buf, st in pairs(bufs) do
    if st.root == root then M.reload(buf) end
  end
end

local change_timers = {}

local function watch(path, root)
  if watchers[path] then return end
  change_timers[root] = change_timers[root] or assert(vim.uv.new_timer())
  local w, timer = assert(vim.uv.new_fs_event()), change_timers[root]
  local ok = w:start(path, {}, function(err, name)
    if err or (name and name:match("%.lock$")) then return end
    timer:start(120, 0, vim.schedule_wrap(function() on_git_change(root) end))
  end)
  if not ok then return w:close() end
  watchers[path] = w
end

-- A push from a shell only rewrites refs/remotes/<upstream>, below the (non-recursive) gitdir watch.
local function watch_upstream(loc, upstream)
  local dir = vim.fs.dirname(loc.common .. "/refs/remotes/" .. upstream)
  while #dir > #loc.common and not vim.uv.fs_stat(dir) do dir = vim.fs.dirname(dir) end
  watch(dir, loc.root)
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
  repo.run(args, dir, function(ok, out) resolved(dir, ok, out) end)
end

local function track(buf, loc, file, cb)
  local rel = repo.relative(loc.root, file)
  repo.show_raw(loc.root, "", rel, function(text)
    if not api.nvim_buf_is_valid(buf) then return end
    bufs[buf] = { buf = buf, root = loc.root, rel = rel, index = text and split(text), hunks = {} }
    update(buf)
    if cb then cb() end
  end)
end

-- Re-reads the index copy of the buffer's file (untracked files get no signs), then rediffs.
function M.reload(buf, cb)
  local path = api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" or vim.b[buf].bigfile then return end
  local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
  if not dir then return end
  locate(dir, function(loc)
    if loc and api.nvim_buf_is_valid(buf) then track(buf, loc, dir .. "/" .. vim.fs.basename(path), cb) end
  end)
end

-- Status segment ----------------------------------------------------------------------------

refresh_status = function(loc)
  repo.status(loc.root, function(s)
    stats[loc.root] = s or false
    if s and s.upstream then watch_upstream(loc, s.upstream) end
    vim.cmd.redrawtabline()
  end)
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
  if #st.hunks == 0 then return say("○ no hunks") end
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
local busy = {}

local function exclusive(buf, fn)
  if busy[buf] then return say("◆ still applying the last change") end
  busy[buf] = true
  M.reload(buf, function() fn(bufs[buf]) end)
end

local function free(buf, msg)
  busy[buf] = nil
  say(msg)
end

local function apply(st, text, args, cb)
  local cmd = vim.list_extend({ "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn" }, args)
  repo.run(cmd, st.root, function(ok, _, err)
    busy[st.buf] = nil
    if ok then return cb() end
    say("✗ " .. vim.trim(err), "AosFailed")
    M.reload(st.buf)
  end, { stdin = text })
end

local function stage_now(st, buf, l1, l2, lnum, cb)
  if not st.index then return free(buf, "○ not in the index: <leader>hS stages the file") end
  local changes = targets(st, l1, l2, lnum)
  if #changes == 0 then return free(buf, "○ no hunk here") end
  apply(st, patch(st.rel, st.index, buf_text(buf, st.index.cr), changes), {}, function()
    say(("✓ staged %d %s"):format(#changes, #changes == 1 and "hunk" or "hunks"), "AosDone")
    M.reload(buf, cb)
  end)
end

function M.stage(l1, l2, cb)
  local st, buf = current()
  local lnum = vim.fn.line(".")
  if st then exclusive(buf, function(fresh) stage_now(fresh, buf, l1, l2, lnum, cb) end) end
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

local function unstage_from(st, buf, head, lnum)
  local done = function(ok, _, err)
    busy[buf] = nil
    if ok == false then return say("✗ " .. vim.trim(err), "AosFailed") end
    say("✓ unstaged hunk", "AosDone")
    M.reload(buf)
  end
  if not head then return repo.run({ "rm", "--cached", "-q", "--", st.rel }, st.root, done) end
  local base = split(head)
  local staged = vim.text.diff(join(base), join(st.index), indices) --[[@as integer[][] ]]
  if #staged == 0 then return free(buf, "○ nothing staged in " .. st.rel) end
  local h = hunk_at(staged, to_index(st.hunks, lnum)) or staged[#staged]
  apply(st, patch(st.rel, base, st.index, { h }), { "--reverse" }, done)
end

local function staged_orig(s, rel)
  for _, e in ipairs(s and s.staged or {}) do
    if e.path == rel and e.orig then return e.orig end
  end
end

-- HEAD's copy of the file, following a staged rename; nil for a file that is new in the index.
local function head_text(st, cb)
  repo.show_raw(st.root, "HEAD", st.rel, function(text)
    if text then return cb(text) end
    repo.status(st.root, function(s)
      local orig = staged_orig(s, st.rel)
      if not orig then return cb(nil) end
      repo.show_raw(st.root, "HEAD", orig, cb)
    end)
  end)
end

function M.unstage()
  local st, buf = current()
  local lnum = vim.fn.line(".")
  if not st then return end
  exclusive(buf, function(fresh)
    if not fresh.index then return free(buf, "○ nothing staged in " .. fresh.rel) end
    head_text(fresh, function(head) unstage_from(fresh, buf, head, lnum) end)
  end)
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
  local keys = {
    s = peek_after(win, function(cb) M.stage(nil, nil, cb) end),
    x = peek_after(win, function(cb) M.revert() cb() end),
    ["]h"] = peek_after(win, function() M.nav(1) M.peek() end),
    ["[h"] = peek_after(win, function() M.nav(-1) M.peek() end),
    q = close_peek, ["<Esc>"] = close_peek,
  }
  for lhs, fn in pairs(keys) do vim.keymap.set("n", lhs, fn, { buffer = pbuf, nowait = true }) end
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
    footer = " s stage · x revert · ]h [h move · q close ", footer_pos = "right",
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
  if blame.job and not blame.job:is_closing() then blame.job:kill(15) end
  blame.job = repo.run(blame_args(st, { "-L", lnum .. "," .. lnum }), st.root, function(ok, out)
    if seq ~= blame.seq then return end
    show_line_blame(buf, lnum, ok and parse_blame(out)[lnum] or { sha = zero })
  end, { stdin = contents(buf) })
end

local function clear_line_blame(ev)
  if blame.at and blame.at == ev.buf .. ":" .. vim.fn.line(".") and ev.event == "CursorMoved" then return end
  blame.at, blame.seq = nil, blame.seq + 1
  api.nvim_buf_clear_namespace(ev.buf, blame_ns, 0, -1)
end

function M.toggle_blame()
  blame.on, blame.at = not blame.on, nil
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

local function render_split(lines, count)
  local bbuf, rows = split_state.buf, {}
  for i = 1, count do rows[i] = lines[i] and "▎" .. blame_row(lines[i]) or "" end
  vim.bo[bbuf].modifiable = true
  api.nvim_buf_set_lines(bbuf, 0, -1, false, rows)
  vim.bo[bbuf].modifiable = false
  api.nvim_buf_clear_namespace(bbuf, blame_ns, 0, -1)
  for i = 1, count do
    local c, run = lines[i], lines[i - 1] and lines[i] and lines[i - 1].sha == lines[i].sha
    if c then
      api.nvim_buf_set_extmark(bbuf, blame_ns, i - 1, 0, { end_col = #"▎", hl_group = age_hl(c) })
      api.nvim_buf_set_extmark(bbuf, blame_ns, i - 1, #"▎", { end_col = #rows[i], hl_group = run and "AosFaint" or "AosDim" })
      if not run then api.nvim_buf_set_extmark(bbuf, blame_ns, i - 1, #"▎", { end_col = rows[i]:find(" ", 1, true) - 1, hl_group = age_hl(c) }) end
    end
  end
  split_state.lines = lines
end

local function rerun_split()
  local s = split_state
  if not s or not api.nvim_win_is_valid(s.win) then return end
  local st = bufs[s.src]
  if not st then return end
  repo.run(blame_args(st, {}), st.root, function(ok, out, err)
    if not ok then return say("✗ " .. vim.trim(err), "AosFailed") end
    if split_state ~= s or not api.nvim_buf_is_valid(s.buf) then return end
    render_split(parse_blame(out), api.nvim_buf_line_count(s.src))
    api.nvim_win_call(s.swin, function() vim.cmd("syncbind") end)
  end, { stdin = contents(s.src) })
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
    api.nvim_open_win(buf, true, {
      relative = "editor", row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2), width = w, height = h,
      title = (" ❯ show · %s · %s "):format(c.sha:sub(1, 7), st.rel), title_pos = "left",
    })
    for _, lhs in ipairs({ "q", "<Esc>" }) do vim.keymap.set("n", lhs, "<cmd>close<cr>", { buffer = buf, nowait = true }) end
  end)
end

local function close_split()
  local s = split_state
  split_state = nil
  if not s then return end
  if api.nvim_win_is_valid(s.swin) then vim.wo[s.swin].scrollbind, vim.wo[s.swin].cursorbind = false, false end
  pcall(api.nvim_del_augroup_by_name, "GitBlameSplit")
  if not api.nvim_win_is_valid(s.win) then return end
  -- The source window was closed with :q and the blame column is all that is left.
  if #api.nvim_list_tabpages() == 1 and #api.nvim_tabpage_list_wins(0) == 1 then return vim.cmd("silent! quit") end
  api.nvim_win_close(s.win, true)
end

local function open_split(src, swin)
  local bbuf = api.nvim_create_buf(false, true)
  vim.bo[bbuf].bufhidden, vim.bo[bbuf].filetype = "wipe", "gitblame"
  local bwin = api.nvim_open_win(bbuf, false, { split = "left", win = swin, width = 36 })
  for opt, val in pairs({ number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0", wrap = false, winfixwidth = true, cursorline = true, list = false, statuscolumn = "" }) do
    vim.wo[bwin][opt] = val
  end
  vim.wo[bwin].winbar = vim.wo[swin].winbar ~= "" and "%#AosPrompt#❯ %#AosArg#blame" or ""
  split_state = { win = bwin, buf = bbuf, src = src, swin = swin, lines = {} }
  for _, w in ipairs({ bwin, swin }) do vim.wo[w].scrollbind, vim.wo[w].cursorbind = true, true end
  vim.keymap.set("n", "q", close_split, { buffer = bbuf, nowait = true })
  vim.keymap.set("n", "<CR>", show_commit, { buffer = bbuf, nowait = true })
  local group = api.nvim_create_augroup("GitBlameSplit", {})
  api.nvim_create_autocmd("WinClosed", { group = group, pattern = { tostring(bwin), tostring(swin) }, callback = vim.schedule_wrap(close_split) })
  api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function(ev)
    if api.nvim_get_current_win() == swin and ev.buf ~= src then vim.schedule(close_split) end
  end })
  api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "InsertLeave" }, { group = group, buffer = src, callback = rerun_split })
end

function M.blame_file()
  if split_state then return close_split() end
  local st, buf = current()
  if not st then return end
  if not st.index then return say("○ not in the index: nothing to blame") end
  open_split(buf, api.nvim_get_current_win())
  rerun_split()
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
  au({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, function(ev) M.reload(ev.buf) end)
  au({ "TextChanged", "InsertLeave" }, debounced)
  au({ "BufWritePost", "FocusGained", "DirChanged", "ShellCmdPost" }, refresh_cwd)
  au("CursorHold", line_blame)
  au({ "CursorMoved", "InsertEnter", "BufLeave" }, clear_line_blame)
  au("BufWipeout", function(ev)
    if timers[ev.buf] then timers[ev.buf]:close() end
    timers[ev.buf], bufs[ev.buf] = nil, nil
  end)
end

return M
