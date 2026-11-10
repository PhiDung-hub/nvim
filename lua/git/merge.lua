-- VS Code merge editor: Incoming │ Current over the editable Result (the working file), base on a toggle; and
-- CodeLens-style conflict actions in any buffer with markers. Delete/modify and binary conflicts get a choice instead.
local repo = require("git.repo")
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("git.merge")
local state = {} -- buf -> { list = conflicts, restore = fn } while the buffer has markers
local P = {} -- the open popup
local pending, tick = {}, vim.uv.new_timer()
local PICK = { current = { "current" }, incoming = { "incoming" }, both = { "current", "incoming" }, none = {} }
local LENS = { { "Accept Current", "co" }, { "Accept Incoming", "ct" }, { "Accept Both", "cb" }, { "Compare", "␣gm" } }
local TINT = {
  current = { "AosMergeCurrent", "AosMergeCurrentHead", "Current Change" },
  base = { "AosMergeBase", "AosMergeBaseHead", "Base" },
  incoming = { "AosMergeIncoming", "AosMergeIncomingHead", "Incoming Change" },
}

local HEADS = { merge = "MERGE_HEAD", ["cherry-pick"] = "CHERRY_PICK_HEAD", revert = "REVERT_HEAD" }

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "git" }) end
local function data(list) return vim.tbl_map(function(k) return { k[1], k[3] } end, list) end
local function open() return P.wins ~= nil end
local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

-- Parsing ------------------------------------------------------------------------------------

-- The label after a 7-char marker ("" when bare), or nil when `l` is not that marker.
local function label(l, ch)
  if l:sub(1, 7) ~= ch:rep(7) then return end
  local rest = l:sub(8):gsub("\r$", "")
  if rest == "" or rest:sub(1, 1) == " " then return vim.trim(rest) end
end

-- Every bare ======= is a separator candidate (a side may hold a setext underline); in diff3 it must follow the base.
local function step(out, cur, i, l)
  local ours = label(l, "<")
  if ours then return { s = i, ours = ours, seps = {} } end
  if not cur then return end
  local base = not cur.b and label(l, "|")
  if base then
    cur.b, cur.base, cur.seps = i, base, {}
    return cur
  end
  if label(l, "=") == "" then
    cur.seps[#cur.seps + 1] = i
    return cur
  end
  local theirs = #cur.seps > 0 and label(l, ">")
  if not theirs then return cur end
  cur.e, cur.theirs, cur.m = i, theirs, cur.seps[1]
  out[#out + 1] = cur
end

-- Conflicts as marker rows (1-based): s <<<<<<<, b |||||||, m =======, e >>>>>>>, plus their labels.
local function parse(lines)
  local out, cur = {}, nil
  for i, l in ipairs(lines) do
    if l:find("^[<|=>]") then cur = step(out, cur, i, l) end
  end
  return out
end

local function sides(c, lines)
  return {
    current = vim.list_slice(lines, c.s + 1, (c.b or c.m) - 1),
    base = c.b and vim.list_slice(lines, c.b + 1, c.m - 1) or {},
    incoming = vim.list_slice(lines, c.m + 1, c.e - 1),
  }
end

local function at(list, row)
  for _, c in ipairs(list) do
    if row >= c.s and row <= c.e then return c end
  end
end

-- Any conflict marker line, even one outside a complete block (a hand-deleted >>>>>>>).
local function stray(lines)
  for _, l in ipairs(lines) do
    if label(l, "<") or label(l, "|") or label(l, ">") then return true end
  end
  return false
end

local settle

local function conflicts(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local list = parse(lines)
  for _, c in ipairs(list) do settle(buf, c, lines) end
  return list, lines
end

-- Decorations --------------------------------------------------------------------------------

local function lens()
  local chunks = {}
  for i, a in ipairs(LENS) do
    if i > 1 then chunks[#chunks + 1] = { " · ", "AosFaint" } end
    vim.list_extend(chunks, { { a[1], "AosMergeAction" }, { " " .. a[2], "AosFaint" } })
  end
  return chunks
end

local function tint(buf, from, to, hl)
  for l = from, to do api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = hl }) end
end

local function head(buf, row, kind)
  api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = TINT[kind][2], virt_text = { { "  ◂ " .. TINT[kind][3], "AosFaint" } } })
end

-- Virtual lines above line 1 only show when the window scrolls into its filler (topfill).
local function show_top(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_win_call(w, function()
      if vim.fn.line("w0") == 1 and vim.fn.winsaveview().topfill == 0 then vim.fn.winrestview({ topfill = 1 }) end
    end)
  end
end

local function draw_one(buf, c)
  head(buf, c.s, "current")
  api.nvim_buf_set_extmark(buf, ns, c.s - 1, 0, { virt_lines = { lens() }, virt_lines_above = true })
  if c.s == 1 then show_top(buf) end
  tint(buf, c.s + 1, (c.b or c.m) - 1, TINT.current[1])
  if c.b then
    head(buf, c.b, "base")
    tint(buf, c.b + 1, c.m - 1, TINT.base[1])
  end
  api.nvim_buf_set_extmark(buf, ns, c.m - 1, 0, { line_hl_group = "AosMergeSep" })
  tint(buf, c.m + 1, c.e - 1, TINT.incoming[1])
  head(buf, c.e, "incoming")
end

local header, sync

local CONFLICT_KEYS -- defined with the actions below

-- Saves the buffer's own mappings of these keys and restores them when the returned function runs.
local function bind(buf, keys)
  local saved = {}
  api.nvim_buf_call(buf, function()
    for _, k in ipairs(keys) do
      local old = vim.fn.maparg(k[1], "n", false, true)
      if old.buffer == 1 then saved[#saved + 1] = old end
      vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, desc = k[3] })
    end
  end)
  return function()
    if not api.nvim_buf_is_valid(buf) then return end
    api.nvim_buf_call(buf, function()
      for _, k in ipairs(keys) do pcall(vim.keymap.del, "n", k[1], { buffer = buf }) end
      for _, old in ipairs(saved) do vim.fn.mapset(old) end
    end)
  end
end

local function has_marker(buf)
  return api.nvim_buf_call(buf, function() return vim.fn.search([[^<<<<<<<\( \|\r\=$\)]], "nw") > 0 end)
end

local function forget(buf)
  local st = state[buf]
  state[buf] = nil
  if st then st.restore() end
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

-- Redraws the conflict decorations and keeps co/ct/cb/c0/]x/[x mapped exactly while markers exist.
local function scan(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or vim.b[buf].bigfile then return end
  if not api.nvim_buf_is_loaded(buf) then return end
  local list = (state[buf] or has_marker(buf)) and conflicts(buf) or {}
  if #list == 0 then forget(buf) else
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, c in ipairs(list) do draw_one(buf, c) end
    state[buf] = state[buf] or { restore = bind(buf, CONFLICT_KEYS) }
    state[buf].list = list
  end
  if P.buf == buf then header() end
end

local function later(buf)
  pending[buf] = true
  tick:stop()
  tick:start(150, 0, vim.schedule_wrap(function()
    local bufs = pending
    pending = {}
    for b in pairs(bufs) do scan(b) end
  end))
end

-- Actions ------------------------------------------------------------------------------------

local function popup_wins()
  local out = {}
  for _, w in pairs(P.wins or {}) do
    if api.nvim_win_is_valid(w) then out[#out + 1] = w end
  end
  return out
end

-- Inside the popup every pane acts on the Result; elsewhere on the current window.
local function target()
  if open() and vim.tbl_contains(popup_wins(), api.nvim_get_current_win()) then return P.buf, P.wins.result end
  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

-- `lens`: a conflict's action line sits above row 1, so the view keeps that filler row (else it drops it).
local function centre(win, row, lens)
  api.nvim_win_set_cursor(win, { math.max(1, math.min(row, api.nvim_buf_line_count(api.nvim_win_get_buf(win)))), 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
    if vim.fn.line("w0") == 1 then vim.fn.winrestview({ topfill = lens and 1 or 0 }) end
  end)
end

local function accept(how)
  local buf, win = target()
  local list, lines = conflicts(buf)
  local c = at(list, api.nvim_win_get_cursor(win)[1])
  if not c then return notify("○ cursor is not in a conflict · ]x next") end
  if c.ambiguous then return notify("○ ambiguous ======= in this conflict · :GitMerge", vim.log.levels.WARN) end
  if not vim.bo[buf].modifiable then return notify("○ buffer is not modifiable", vim.log.levels.WARN) end
  local s, out = sides(c, lines), {}
  for _, part in ipairs(PICK[how]) do vim.list_extend(out, s[part]) end
  api.nvim_buf_set_lines(buf, c.s - 1, c.e, false, out)
  centre(win, c.s)
  scan(buf)
end

local function next_conflict(list, row, dir)
  local from, to = dir > 0 and 1 or #list, dir > 0 and #list or 1
  for i = from, to, dir do
    local s = list[i].s
    if (dir > 0 and s > row) or (dir < 0 and s < row) then return list[i] end
  end
  return list[from]
end

local function jump(dir)
  local buf, win = target()
  local c = next_conflict(conflicts(buf), api.nvim_win_get_cursor(win)[1], dir)
  if not c then return notify("✓ no conflicts left") end
  centre(win, c.s, c.s == 1)
  if P.buf == buf then sync(c) end
end

CONFLICT_KEYS = {
  { "co", function() accept("current") end, "accept current (ours)" },
  { "ct", function() accept("incoming") end, "accept incoming (theirs)" },
  { "cb", function() accept("both") end, "accept both (current, then incoming)" },
  { "c0", function() accept("none") end, "accept none (drop both sides)" },
  { "]x", function() jump(1) end, "next conflict" },
  { "[x", function() jump(-1) end, "previous conflict" },
}

-- Popup --------------------------------------------------------------------------------------

local function box(row, col, width, height)
  return { relative = "editor", row = row, col = col, width = math.max(width - 2, 1), height = math.max(height - 2, 1), zindex = 40 }
end

-- ~90% x 85%: a one-line header, the side panes on top, the Result below.
local function rects()
  local lines = vim.o.lines - vim.o.cmdheight
  local width, height = math.floor(vim.o.columns * 0.9), math.floor(lines * 0.85)
  local row, col = math.floor((lines - height) / 2), math.floor((vim.o.columns - width) / 2)
  local top = math.floor((height - 3) * 0.45)
  local panes = P.base_on and { "incoming", "base", "current" } or { "incoming", "current" }
  local out, w = { header = box(row, col, width, 3) }, math.floor(width / #panes)
  for i, name in ipairs(panes) do
    out[name] = box(row + 3, col + (i - 1) * w, i == #panes and width - (i - 1) * w or w, top)
  end
  out.result = box(row + 3 + top, col, width, height - 3 - top)
  return out
end

local function win_opts(w, number)
  local wo = vim.wo[w]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.foldenable = number, false, "no", "0", false
  wo.wrap, wo.list, wo.spell, wo.winbar, wo.statuscolumn, wo.cursorline = false, false, false, "", "", number
end

-- What "current" and "incoming" are for this operation; x: { op, ours?, theirs? } (marker labels).
local function role(x)
  local ours, theirs = x.ours or "", x.theirs or ""
  if x.op == "rebase" then return "upstream being rebased onto", "your commit being replayed" .. (theirs ~= "" and " · " .. theirs or "") end
  return ours ~= "" and ours or "HEAD", theirs ~= "" and theirs or HEADS[x.op] or "theirs"
end

header = function()
  if not (open() and api.nvim_buf_is_valid(P.header)) then return end
  local list, lines = conflicts(P.buf)
  local n = #list
  local chunks = n > 0 and { { "! " .. plural(n, "conflict") .. " left", "AosRunning" } }
    or stray(lines) and { { "! stray conflict markers", "AosRunning" } }
    or { { "✓ all conflicts resolved", "AosDone" }, { " · s mark resolved", "AosDim" } }
  local cur, inc = role(P)
  vim.list_extend(chunks, { { "  ·  " .. P.op .. " · ", "AosFaint" }, { "current = " .. cur, "AosDone" }, { " · ", "AosFaint" }, { "incoming = " .. inc, "AosId" } })
  local text, hls = " ", {}
  for _, c in ipairs(chunks) do
    hls[#hls + 1] = { #text, #text + #c[1], c[2] }
    text = text .. c[1]
  end
  vim.bo[P.header].modifiable = true
  api.nvim_buf_set_lines(P.header, 0, -1, false, { text })
  vim.bo[P.header].modifiable = false
  api.nvim_buf_clear_namespace(P.header, ns, 0, -1)
  for _, h in ipairs(hls) do vim.hl.range(P.header, ns, h[3], { 0, h[1] }, { 0, h[2] }) end
end

local function same(lines, i, want)
  for j = 1, #want do
    if lines[i + j - 1] ~= want[j] then return false end
  end
  return true
end

-- Where `want` starts in `lines`, choosing the match nearest `guess`.
local function nearest(lines, want, guess)
  local best
  for i = 1, #lines - #want + 1 do
    if same(lines, i, want) and (not best or math.abs(i - guess) < math.abs(best - guess)) then best = i end
  end
  return best
end

local function fits(name, want)
  want = vim.tbl_map(function(l) return (l:gsub("\r$", "")) end, want)
  return #want == 0 or nearest(P.text[name], want, 1) ~= nil
end

-- Several ======= candidates: the popup picks the one whose sides are found in :2/:3 (and :1); elsewhere it stays ambiguous.
settle = function(buf, c, lines)
  if #c.seps < 2 then return end
  c.ambiguous = true
  if not (open() and buf == P.buf and P.text.current) then return end
  for _, m in ipairs(c.seps) do
    c.m = m
    local s = sides(c, lines)
    if fits("current", s.current) and fits("incoming", s.incoming) and (not c.b or fits("base", s.base)) then
      c.ambiguous = nil
      return
    end
  end
  c.m = c.seps[1]
end

-- Scrolls each side pane to the conflict's text there (or just past the line before it when that side is empty).
sync = function(c)
  local lines = api.nvim_buf_get_lines(P.buf, 0, -1, false)
  local s, total = sides(c, lines), #lines
  for _, name in ipairs({ "incoming", "base", "current" }) do
    local w, text = P.wins[name], P.text[name]
    local want, skip = s[name], 0
    if #want == 0 then want, skip = { lines[c.s - 1] }, 1 end
    local row = w and api.nvim_win_is_valid(w) and #want > 0 and nearest(text, want, math.floor(c.s * #text / math.max(total, 1)))
    if row then centre(w, row + skip) end
  end
end

local function changed(base, side)
  local rows = {}
  for _, h in ipairs(vim.text.diff(base, side, { result_type = "indices", algorithm = "histogram" })) do
    rows[#rows + 1] = { h[3], h[3] + h[4] - 1, h[1], h[1] + h[2] - 1 }
  end
  return rows
end

local function lines_of(text)
  local l = vim.split(text, "\n", { plain = true })
  if l[#l] == "" then l[#l] = nil end
  return l
end

local function pane_buf(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].completion = false
  pcall(api.nvim_buf_set_name, buf, ("gitmerge://%d/%s/%s"):format(buf, name, P.path))
  local text = P.text[name]
  api.nvim_buf_set_lines(buf, 0, -1, false, #text > 0 and text or { name == "base" and "○ no common base (added on both sides)" or "" })
  vim.bo[buf].modifiable = false
  local ft = vim.filetype.match({ filename = P.path, buf = buf })
  if ft then vim.bo[buf].filetype = ft end
  if name == "base" then return buf end
  local base = P.raw.base
  for _, r in ipairs(changed(base, P.raw[name])) do tint(buf, r[1], r[2], TINT[name][1]) end
  return buf
end

local TITLES = {
  incoming = function() return { { " Incoming · ", "AosId" }, { select(2, role(P)) .. " :3 ", "AosDim" } } end,
  current = function() return { { " Current · ", "AosDone" }, { (role(P)) .. " :2 ", "AosDim" } } end,
  base = function() return { { " Base · ", "AosSha" }, { "common ancestor :1 ", "AosDim" } } end,
}
local FOOTER = " co current · ct incoming · cb both · c0 none · ]x [x · gb base · s resolved · q close "

local POPUP_KEYS

local function map_scratch(buf)
  for _, k in ipairs(vim.list_extend(vim.list_extend({}, CONFLICT_KEYS), POPUP_KEYS)) do
    vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, desc = k[3] })
  end
end

local function open_pane(name, conf)
  local buf = name == "result" and P.buf or name == "header" and P.header or pane_buf(name)
  if name ~= "result" and name ~= "header" then map_scratch(buf) end
  local extra = name == "header" and { title = { { " ❯ ", "AosPrompt" }, { "merge ", "AosArg" }, { P.path .. " ", "FloatTitle" } }, title_pos = "left" }
    or name == "result" and { title = { { " Result ", "AosMergeAction" }, { P.path .. " ", "AosDim" } }, title_pos = "left", footer = { { FOOTER, "AosFaint" } }, footer_pos = "right" }
    or { title = TITLES[name](), title_pos = "left" }
  P.wins[name] = api.nvim_open_win(buf, false, vim.tbl_extend("force", conf, extra))
  win_opts(P.wins[name], name ~= "header")
end

local function place()
  local r = rects()
  for _, name in ipairs({ "header", "incoming", "base", "current", "result" }) do
    local w, conf = P.wins[name], r[name]
    if not conf and w then
      P.wins[name] = nil
      pcall(api.nvim_win_close, w, true)
    elseif conf and w and api.nvim_win_is_valid(w) then
      api.nvim_win_set_config(w, conf)
    elseif conf then
      open_pane(name, conf)
    end
  end
end

local function release()
  local buf = P.buf
  if P.restore then P.restore() end
  if not api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].modified then vim.bo[buf].buflisted = true return end
  if P.borrowed and #vim.fn.win_findbuf(buf) == 0 then pcall(api.nvim_buf_delete, buf, {}) end
end

-- `left`: focus already went to an ordinary window; stay there.
function M.close(left)
  if not open() then return end
  local wins, origin, back = P.wins, P.origin, P.back
  P.wins = nil
  for _, w in pairs(wins) do pcall(api.nvim_win_close, w, true) end
  pcall(api.nvim_buf_delete, P.header, { force = true })
  release()
  P = {}
  if left then return end
  if origin and api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
  if back then back() end
end

local function toggle_base()
  P.base_on = not P.base_on
  place()
  local list, row = conflicts(P.buf), api.nvim_win_get_cursor(P.wins.result)[1]
  local c = at(list, row) or next_conflict(list, row, 1)
  if c then sync(c) end
end

local function cycle()
  local order = vim.tbl_filter(function(w) return w end, { P.wins.result, P.wins.incoming, P.wins.base, P.wins.current })
  local cur = api.nvim_get_current_win()
  for i, w in ipairs(order) do
    if w == cur then return api.nvim_set_current_win(order[i % #order + 1]) end
  end
  api.nvim_set_current_win(P.wins.result)
end

local function refresh_scm()
  local ok, scm = pcall(require, "git.scm")
  if ok and scm.refresh then scm.refresh() end
end

local function resolved()
  local list, lines = conflicts(P.buf)
  if #list > 0 then return notify("! " .. plural(#list, "conflict") .. " left · resolve the markers first", vim.log.levels.WARN) end
  if stray(lines) then return notify("! stray conflict markers left · remove them first", vim.log.levels.WARN) end
  local root, path = P.root, P.path
  if vim.bo[P.buf].modified then
    local ok, err = pcall(api.nvim_buf_call, P.buf, function() vim.cmd("silent write") end)
    if not ok then return notify("✗ write · " .. tostring(err):gsub("\n.*", ""), vim.log.levels.ERROR) end
  end
  local disk = vim.fn.filereadable(root .. "/" .. path) == 1 and vim.fn.readfile(root .. "/" .. path) or {}
  if stray(disk) then return notify("! " .. path .. " on disk still has conflict markers", vim.log.levels.WARN) end
  repo.run({ "--literal-pathspecs", "add", "--", path }, root, function(ok, _, err)
    if not ok then return notify("✗ git add · " .. vim.trim(err):gsub("\n.*", ""), vim.log.levels.ERROR) end
    notify("✓ " .. path .. " marked resolved")
    if P.path == path then M.close() end
    refresh_scm()
  end, { feature = "merge" })
end

POPUP_KEYS = {
  { "gb", toggle_base, "toggle the common base pane" },
  { "s", resolved, "mark resolved: save + git add (refused while markers remain)" },
  { "<Tab>", cycle, "next pane" },
  { "q", function() M.close() end, "close (focus goes back)" },
  { "<Esc>", function() M.close() end, "close (focus goes back)" },
}

M.keys = {
  { section = "Merge editor", keys = vim.list_extend(data(CONFLICT_KEYS), data(POPUP_KEYS)) },
  { section = "Conflict markers (any buffer)", keys = data(CONFLICT_KEYS) },
}

local function result_buf(path)
  local buf = vim.fn.bufadd(path)
  P.borrowed = not api.nvim_buf_is_loaded(buf)
  if not P.borrowed then
    pcall(vim.cmd.checktime, buf)
    return buf
  end
  local shm = vim.o.shortmess
  vim.opt.shortmess:append("A")
  pcall(vim.fn.bufload, buf)
  vim.o.shortmess = shm
  return buf
end

local function build(ctx, opts)
  opts.back, P.back = opts.back or P.back, nil
  M.close()
  P = { root = ctx.root, path = ctx.path, op = ctx.op, raw = ctx.raw, text = {}, wins = {}, back = opts.back, origin = api.nvim_get_current_win() }
  for name, raw in pairs(ctx.raw) do P.text[name] = lines_of(raw) end
  P.buf = result_buf(ctx.root .. "/" .. ctx.path)
  P.header = api.nvim_create_buf(false, true)
  map_scratch(P.header)
  local first = conflicts(P.buf)[1] or {}
  P.ours, P.theirs = first.ours or "", first.theirs or ""
  scan(P.buf)
  P.restore = bind(P.buf, POPUP_KEYS)
  place()
  header()
  api.nvim_set_current_win(P.wins.result)
  local list = conflicts(P.buf)
  local c = at(list, opts.row or 0) or list[1]
  if c then
    centre(P.wins.result, c.s, c.s == 1)
    sync(c)
  end
end

-- Delete/modify and binary conflicts -----------------------------------------------------------

local function chain(root, cmds, done)
  if #cmds == 0 then return done(true) end
  repo.run(cmds[1], root, function(ok, out, err)
    if not ok then return done(false, vim.trim(err ~= "" and err or out)) end
    chain(root, vim.list_slice(cmds, 2), done)
  end, { feature = "merge" })
end

local function keep(path, stage, present)
  if not present then return { { "--literal-pathspecs", "rm", "--quiet", "--", path } } end
  return { { "--literal-pathspecs", "checkout", stage, "--", path }, { "--literal-pathspecs", "add", "--", path } }
end

local function choose(ctx, opts, why)
  local root, path, st = ctx.root, ctx.path, ctx.stages
  local cur, inc = role(ctx)
  local items = {
    { "keep ours · current " .. cur .. (st[2] and "" or " (deleted)"), keep(path, "--ours", st[2]) },
    { "keep theirs · incoming " .. inc .. (st[3] and "" or " (deleted)"), keep(path, "--theirs", st[3]) },
    { "delete " .. path, { { "--literal-pathspecs", "rm", "--quiet", "-f", "--", path } } },
  }
  vim.ui.select(items, { prompt = ("merge %s · %s"):format(path, why), format_item = function(i) return i[1] end }, function(item)
    if not item then return opts.back and opts.back() end
    chain(root, item[2], function(ok, err)
      if not ok then notify("✗ " .. item[1] .. " · " .. err:gsub("\n.*", ""), vim.log.levels.ERROR) else notify("✓ " .. path .. " · " .. item[1]) end
      vim.cmd("silent! checktime")
      refresh_scm()
      if opts.back then opts.back() end
    end)
  end)
end

-- Loading ------------------------------------------------------------------------------------

local function join(n, done)
  local left = n
  return function()
    left = left - 1
    if left == 0 then done() end
  end
end

-- Nothing to show: say why, then hand back to where the editor was opened from (Source Control).
local function give_up(opts, msg, level)
  notify(msg, level)
  if opts.back then opts.back() end
end

local function paused(opts) give_up(opts, "○ merge editor paused · slow repo", vim.log.levels.WARN) end

local function operation(gitdir)
  local function has(name) return vim.uv.fs_stat(gitdir .. "/" .. name) ~= nil end
  if has("rebase-merge") or has("rebase-apply") then return "rebase" end
  if has("CHERRY_PICK_HEAD") then return "cherry-pick" end
  if has("REVERT_HEAD") then return "revert" end
  return has("MERGE_HEAD") and "merge" or "conflict"
end

local function load(ctx, opts)
  local slow, raw = false, {}
  local done = join(4, function()
    if slow then return paused(opts) end
    if raw.current:find("\0", 1, true) or raw.incoming:find("\0", 1, true) then return choose(ctx, opts, "binary file") end
    ctx.raw = raw
    build(ctx, opts)
  end)
  for stage, name in pairs({ [1] = "base", [2] = "current", [3] = "incoming" }) do
    repo.run({ "show", ":" .. stage .. ":" .. ctx.path }, ctx.root, function(ok, out, _, timed_out)
      slow = slow or timed_out
      raw[name] = ok and out:gsub("\r\n", "\n") or ""
      done()
    end, { feature = "merge", binary = true })
  end
  repo.run({ "rev-parse", "--absolute-git-dir" }, ctx.root, function(ok, out, _, timed_out)
    slow = slow or timed_out
    ctx.op = ok and operation(vim.trim(out)) or "conflict"
    done()
  end, { feature = "merge" })
end

local function stages(out)
  local st = {}
  for _, rec in ipairs(vim.split(out, "\0", { plain = true })) do
    local n = rec:match("^%d+ %x+ (%d)\t")
    if n then st[tonumber(n)] = true end
  end
  return st
end

-- opts: { root, path (relative), row (Result line to land on), back (called after closing) }.
function M.open(opts)
  local root, path = opts.root, opts.path
  repo.run({ "--literal-pathspecs", "ls-files", "-u", "-z", "--", path }, root, function(ok, out, err, timed_out)
    if timed_out then return paused(opts) end
    if not ok then return give_up(opts, "✗ git ls-files · " .. vim.trim(err), vim.log.levels.ERROR) end
    local st = stages(out)
    if not (st[1] or st[2] or st[3]) then return give_up(opts, "○ " .. path .. " has no merge conflict") end
    local ctx = { root = root, path = path, stages = st }
    if st[2] and st[3] then return load(ctx, opts) end
    repo.run({ "rev-parse", "--absolute-git-dir" }, root, function(found, dir)
      ctx.op = found and operation(vim.trim(dir)) or "conflict"
      choose(ctx, opts, st[2] and "deleted by them (incoming)" or "deleted by us (current)")
    end, { feature = "merge" })
  end, { feature = "merge" })
end

local function pick(root, row)
  repo.run({ "diff", "--name-only", "--diff-filter=U", "-z" }, root, function(ok, out, _, timed_out)
    if timed_out then return paused({}) end
    local files = vim.tbl_filter(function(f) return f ~= "" end, vim.split(ok and out or "", "\0", { plain = true }))
    if #files == 0 then return notify("✓ no merge conflicts") end
    if #files == 1 then return M.open({ root = root, path = files[1], row = row }) end
    vim.ui.select(files, { prompt = "merge editor" }, function(f) if f then M.open({ root = root, path = f }) end end)
  end, { feature = "merge" })
end

-- :GitMerge [path] / <leader>gm: the given file, else the current one when conflicted, else a pick of the conflicts.
function M.command(arg)
  arg = arg ~= "" and arg or nil
  if open() and not arg and vim.tbl_contains(popup_wins(), api.nvim_get_current_win()) then return toggle_base() end
  local file = arg and vim.fn.fnamemodify(arg, ":p") or vim.bo.buftype == "" and api.nvim_buf_get_name(0) or ""
  local root = repo.root(file ~= "" and file or vim.fn.getcwd())
  if not root then return notify("○ not a git repository") end
  if arg then return M.open({ root = root, path = repo.relative(root, file) }) end
  if file == "" then return pick(root) end
  local rel, row = repo.relative(root, file), api.nvim_win_get_cursor(0)[1]
  local marked = state[api.nvim_get_current_buf()] ~= nil
  repo.run({ "--literal-pathspecs", "ls-files", "-u", "--", rel }, root, function(ok, out, _, timed_out)
    if timed_out then return paused({}) end
    if ok and out ~= "" then return M.open({ root = root, path = rel, row = row }) end
    if marked then return notify("○ " .. rel .. " is not conflicted in git · co/ct/cb/c0 resolve its markers here") end
    pick(root)
  end, { feature = "merge" })
end

function M.setup()
  local group = api.nvim_create_augroup("GitMerge", {})
  api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufWinEnter", "FileChangedShellPost" }, {
    group = group, callback = function(a) scan(a.buf) end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, callback = function(a) later(a.buf) end })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, { group = group, callback = function(a) state[a.buf], pending[a.buf] = nil, nil end })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(a)
      if open() and vim.tbl_contains(popup_wins(), tonumber(a.match)) then vim.schedule(M.close) end
    end,
  })
  api.nvim_create_autocmd("VimResized", { group = group, callback = function() if open() then place() end end })
  -- Landing in an ordinary window (e.g. <C-w>p) closes the popup; pickers and other floats stack on it.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = vim.schedule_wrap(function()
      local w = api.nvim_get_current_win()
      if open() and not vim.tbl_contains(popup_wins(), w) and api.nvim_win_get_config(w).relative == "" then M.close(true) end
    end),
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(a)
      if not (open() and a.buf == P.buf and api.nvim_get_current_win() == P.wins.result) then return end
      local c = at((state[P.buf] or {}).list or {}, api.nvim_win_get_cursor(0)[1])
      if c and c.s ~= P.synced then P.synced = c.s sync(c) end
    end,
  })
  api.nvim_create_user_command("GitMerge", function(o) M.command(o.args) end, { nargs = "?", complete = "file", desc = "3-way merge editor" })
  vim.keymap.set("n", "<leader>gm", function() M.command() end, { desc = "Git merge editor (conflict under the cursor)" })
  for _, b in ipairs(api.nvim_list_bufs()) do scan(b) end
end

return M
