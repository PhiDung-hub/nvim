-- Source Control Graph: `git log --topo-order` laid out into coloured lanes here (no `--graph` parsing).
-- A centred popup; commits expand inline into their changed files, a file swaps the popup for a side-by-side diff.
local M = {}
local repo = require("git.repo")
local branch = require("git.branch")
local icons = require("ui.icons")
local pick = require("ui.pick")
local ns = vim.api.nvim_create_namespace("git.graph")
local fns = vim.api.nvim_create_namespace("git.graph.float")
local PAGE, RELOAD, LANES, MAX_LANES, MAX_FILES = 400, 2000, 6, 20, 500
local BUDGET, BIG_BYTES, BIG_LINES, MAX_HUNKS = 3000, 1.5 * 1024 * 1024, 50000, 2000
local FORMAT = "%H%x00%P%x00%D%x00%an%x00%at%x00%s"
local UNBORN = { "does not have any commits", "unknown revision", "bad revision 'HEAD'" }
local DIFFOPT = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:char"
local WALK = { "--branches", "--remotes", "--tags", "HEAD" }
local letter_hl = { M = "AosRunning", A = "AosDone", D = "AosFailed", R = "AosId", C = "AosId", T = "AosRunning", U = "AosDone" }
local U, D, L, R = 1, 2, 4, 8
local BOX = { [3] = "│", [12] = "─", [10] = "╭", [6] = "╮", [9] = "╰", [5] = "╯", [11] = "├", [7] = "┤", [14] = "┬", [13] = "┴", [15] = "┼" }
local S -- the open graph

local function esc(s) return (s:gsub("%%", "%%%%")) end

-- Lanes ----------------------------------------------------------------------------------------
-- S.lanes[i] is the lane in column i ({ sha = commit it waits for, color }) or false when free.
-- Packed like VS Code: a new lane takes the leftmost free column, even one freed on the same row, and gaps
-- close one column per row.

local function lane_hl(lane) return "AosGraphLane" .. lane.color end

local function new_lane(sha)
  S.color = S.color % LANES + 1
  return { sha = sha, color = S.color }
end

local function free_slot(lanes)
  local i = 1
  while lanes[i] do i = i + 1 end
  return i
end

local function link_parent(lanes, links, col, sha)
  for j = 1, #lanes do
    if j ~= col and lanes[j] and lanes[j].sha == sha then
      links[#links + 1] = { j, "join", lanes[j] }
      return
    end
  end
  local j = free_slot(lanes)
  lanes[j] = new_lane(sha)
  links[#links + 1] = { j, "start", lanes[j] }
end

-- A lane passing straight down slides one column left into a free one (╱ in the cell between) unless it
-- carries a link of this row or a link's horizontal runs through that cell.
local function collapse(lanes, links, col)
  local lo, hi, linked = col, col, { [col] = true }
  for _, l in ipairs(links) do lo, hi, linked[l[1]] = math.min(lo, l[1]), math.max(hi, l[1]), true end
  for i = 2, #lanes do
    if lanes[i] and not lanes[i - 1] and not linked[i] and i - 1 ~= col and (i - 1 >= hi or i <= lo) then
      lanes[i - 1], lanes[i] = lanes[i], false
    end
  end
end

-- Cells to a string plus merged highlight runs { start_byte, end_byte, group }.
local function join(cells)
  local parts, hls, pos = {}, {}, 0
  for i, cell in ipairs(cells) do
    parts[i] = cell[1]
    local last, n = hls[#hls], #cell[1]
    if cell[2] and last and last[3] == cell[2] and last[2] == pos then last[2] = pos + n
    elseif cell[2] then hls[#hls + 1] = { pos, pos + n, cell[2] } end
    pos = pos + n
  end
  return table.concat(parts), hls
end

-- Link endpoints as direction bits per cell plus the horizontal runs to them; nearer links come last so their
-- colour wins where runs overlap.
local function link_cells(c)
  local ends, span, at = {}, {}, 2 * c.col - 1
  table.sort(c.links, function(a, b) return math.abs(a[1] - c.col) > math.abs(b[1] - c.col) end)
  for _, l in ipairs(c.links) do
    local p = 2 * l[1] - 1
    local e = ends[p] or { bits = 0 }
    e.bits, e.lane = bit.bor(e.bits, l[2] == "end" and U or l[2] == "start" and D or U + D, p > at and L or R), l[3]
    ends[p] = e
    for q = math.min(p, at) + 1, math.max(p, at) - 1 do span[q] = l[3] end
  end
  return ends, span
end

-- Column i sits in cell 2i-1; the cell between two columns carries horizontals and ╱ slides. A horizontal
-- crossing a lane passes under it.
local function glyph(c, p, ends, span)
  if p == 2 * c.col - 1 then return c.head and "◉" or #c.parents > 1 and "○" or "●", c.head and "AosGraphHead" or lane_hl(c.node) end
  local e = ends[p]
  if e then return BOX[bit.bor(e.bits, span[p] and L + R or 0)], lane_hl(e.lane) end
  local up = p % 2 == 1 and c.before[(p + 1) / 2]
  if up and c.below[(p + 1) / 2] == up then return "│", lane_hl(up) end
  if span[p] then return "─", lane_hl(span[p]) end
  local slide = p % 2 == 0 and c.before[p / 2 + 1]
  if slide and c.below[p / 2] == slide then return "╱", lane_hl(slide) end
  return " "
end

local function hidden(c)
  local k = 0
  for i = MAX_LANES + 1, math.max(#c.before, #c.below, c.col) do
    if c.before[i] or c.below[i] or i == c.col then k = k + 1 end
  end
  return k
end

-- Past MAX_LANES the first lanes stay exact, followed by "+k" hidden lanes and the node when it is one of them.
local function draw(c)
  local n, cap = 2 * math.max(#c.before, #c.below, c.col) - 1, 2 * MAX_LANES - 1
  local ends, span = link_cells(c)
  local cells = {}
  for p = 1, math.min(n, cap) do cells[p] = { glyph(c, p, ends, span) } end
  if n > cap then cells[#cells + 1] = { " +" .. hidden(c) .. (c.col > MAX_LANES and " " or ""), "AosFaint" } end
  if c.col > MAX_LANES then cells[#cells + 1] = { glyph(c, 2 * c.col - 1, ends, span) } end
  c.art, c.art_hl = join(cells)
end

-- Places commit `c` into S.lanes: c.col, c.before/c.below (lanes above/below the row), c.links, c.art.
local function layout(c)
  local lanes, links, col = S.lanes, {}, nil
  local before = { unpack(lanes) }
  for i = 1, #lanes do
    if lanes[i] and lanes[i].sha == c.sha and col then
      links[#links + 1], lanes[i] = { i, "end", lanes[i] }, false
    elseif lanes[i] and lanes[i].sha == c.sha then
      col = i
    end
  end
  col = col or free_slot(lanes)
  local node = lanes[col] or new_lane(c.sha)
  lanes[col] = c.parents[1] and { sha = c.parents[1], color = node.color } or false
  for k = 2, #c.parents do link_parent(lanes, links, col, c.parents[k]) end
  collapse(lanes, links, col)
  while #lanes > 0 and not lanes[#lanes] do lanes[#lanes] = nil end
  c.col, c.node, c.links, c.before, c.below = col, node, links, before, { unpack(lanes) }
  draw(c)
end

-- Lanes passing below a commit, for its expanded file rows.
local function continuation(c)
  local n, cells = math.min(#c.below * 2 - 1, 2 * MAX_LANES - 1), {}
  for i = 1, n do cells[i] = { " " } end
  for i = 1, (n + 1) / 2 do
    if c.below[i] then cells[2 * i - 1] = { "│", lane_hl(c.below[i]) } end
  end
  if #c.below > MAX_LANES then cells[#cells + 1] = { " …", "AosFaint" } end
  return join(cells)
end

-- Parsing --------------------------------------------------------------------------------------

local function chip(ref)
  local name = ref:match("^HEAD %-> refs/heads/(.+)$")
  if name then return { text = " " .. name .. " ", hl = "AosSegCyan", name = name, kind = "local", head = true } end
  if ref == "HEAD" then return { text = " HEAD ", hl = "AosSegCyan", head = true } end
  name = ref:match("^refs/heads/(.+)$")
  if name then return { text = "[" .. name .. "]", hl = "AosId", name = name, kind = "local" } end
  name = ref:match("^tag: refs/tags/(.+)$")
  if name then return { text = branch.TAG .. " " .. name, hl = "AosRunning", name = name, kind = "tag" } end
  name = ref:match("^refs/remotes/(.+)$")
  if name and not name:match("/HEAD$") then return { text = name, hl = "AosSha", name = name, kind = "remote" } end
end

local function parse(line)
  local sha, parents, refs, author, time, subject = unpack(vim.split(line, "\0", { plain = true }))
  local c = { sha = sha, parents = parents == "" and {} or vim.split(parents, " ", { plain = true }), refs = {} }
  c.author, c.time, c.subject = author or "", tonumber(time) or 0, subject or ""
  for _, ref in ipairs(refs ~= "" and vim.split(refs, ", ", { plain = true }) or {}) do
    local r = chip(ref)
    if r then c.refs[#c.refs + 1] = r end
    c.head = c.head or (r and r.head)
  end
  return c
end

local function parse_files(out)
  local f, files, i = vim.split(out, "\0", { plain = true }), {}, 1
  while i < #f do
    local letter = f[i]:sub(1, 1)
    if letter == "R" or letter == "C" then
      files[#files + 1], i = { letter = letter, orig = f[i + 1], path = f[i + 2] }, i + 3
    else
      files[#files + 1], i = { letter = letter, path = f[i + 1] }, i + 2
    end
  end
  return files
end

-- `show-ref --head -d`: tip commit per walked ref, annotated tags peeled.
local function parse_tips(out)
  local tips = {}
  for sha, ref in out:gmatch("(%x+) (%S+)") do
    ref = ref:gsub("%^{}$", "")
    if ref == "HEAD" or ref:find("^refs/heads/") or ref:find("^refs/remotes/") or ref:find("^refs/tags/") then tips[ref] = sha end
  end
  return tips
end

-- Rows -----------------------------------------------------------------------------------------

local units = { { 31536000, "y" }, { 2592000, "mo" }, { 604800, "w" }, { 86400, "d" }, { 3600, "h" }, { 60, "m" } }
local function ago(t)
  local d = os.time() - t
  for _, u in ipairs(units) do
    if d >= u[1] then return ("%d%s ago"):format(math.floor(d / u[1]), u[2]) end
  end
  return "now"
end

local function add(b, text, hl)
  if hl then b.hls[#b.hls + 1] = { b.len, b.len + #text, hl } end
  b.parts[#b.parts + 1] = text
  b.len = b.len + #text
end

local function with_art(art, art_hl)
  local b = { parts = { art }, hls = vim.list_extend({}, art_hl), len = #art }
  return b
end

local function fit(text, room)
  if vim.api.nvim_strwidth(text) <= room then return text end
  return room < 1 and "" or vim.fn.strcharpart(text, 0, room - 1) .. "…"
end

-- Chips take at most half the row; the rest fold into one faint "+k" so the subject and right columns stay.
local function add_chips(b, refs, width)
  for i, r in ipairs(refs) do
    if vim.api.nvim_strwidth(table.concat(b.parts) .. r.text) >= width / 2 then
      return add(b, "+" .. (#refs - i + 1) .. " ", "AosFaint")
    end
    add(b, r.text, r.hl)
    add(b, " ")
  end
end

local function build_line(c, width)
  local b = S.filter == "" and with_art(c.art, c.art_hl) or with_art("●", { { 0, #"●", c.head and "AosGraphHead" or lane_hl(c.node) } })
  add(b, " ")
  add_chips(b, c.refs, width)
  local right = { { c.author, "AosDim" }, { ago(c.time), "AosSha" }, { c.sha:sub(1, 7), "AosGraphSha" } }
  local used = vim.api.nvim_strwidth(table.concat(b.parts))
  local function right_width() return vim.iter(right):fold(0, function(n, r) return n + 2 + vim.api.nvim_strwidth(r[1]) end) end
  while #right > 0 and width - used - right_width() < 24 do table.remove(right, 1) end
  local subject = fit(c.subject, width - used - right_width())
  add(b, subject)
  add(b, (" "):rep(math.max(width - used - vim.api.nvim_strwidth(subject) - right_width(), 0)))
  for _, r in ipairs(right) do
    add(b, "  ")
    add(b, r[1], r[2])
  end
  return table.concat(b.parts), b.hls
end

-- Cached per width and mode; relative dates refresh with `r` or a resize.
local function commit_line(c, width)
  local key = width .. (S.filter == "" and "g" or "f")
  if c.key ~= key then c.key, c.line, c.line_hl = key, build_line(c, width) end
  return c.line, c.line_hl
end

local function file_line(c, f)
  c.cont = c.cont or { continuation(c) }
  local b = with_art(c.cont[1], c.cont[2])
  add(b, "   ")
  if f.note then
    add(b, f.note[1] .. " · ", f.note[2])
    add(b, (vim.trim(f.note[3]):gsub("\n", " ")), f.note[4])
    return table.concat(b.parts), b.hls
  end
  local dir, name = f.path:match("^(.*)/([^/]*)$")
  name = name or f.path
  local icon, icon_hl = icons.get_icon(name, nil, { default = true })
  add(b, f.letter, letter_hl[f.letter] or "AosDim")
  add(b, " · ", "AosFaint")
  add(b, icon .. " ", icon_hl)
  add(b, name)
  if dir then add(b, "  " .. dir, "AosDim") end
  if f.orig then add(b, "  ← " .. f.orig, "AosDim") end
  return table.concat(b.parts), b.hls
end

local function matches(c)
  if S.filter == "" then return true end
  c.search = c.search or (c.subject .. "\0" .. c.author .. "\0" .. c.sha):lower()
  return c.search:find(S.filter, 1, true) ~= nil
end

local function note(g, hl, text) return g .. " · " .. text, { { 0, #g, hl } } end

local LOADING_FILES = { { note = { "◆", "AosRunning", "loading…", "AosDim" } } }

local function status_note(empty)
  if S.error then return note("✗", "AosFailed", (vim.trim(S.error):gsub("\n", " "))) end
  if S.slow then return note("○", "AosDim", "log paused · slow repo") end
  if S.loading then return note("◆", "AosRunning", "loading…") end
  if empty then return note("○", "AosDim", S.filter ~= "" and ("no match for " .. S.filter) or "no commits yet") end
  if not S.done then return note("▸", "AosDim", "more on scroll") end
end

-- Rebuilds the buffer from S.commits, or with `from` only the rows of commits from that index on (a page
-- appended, the rows above unchanged); highlights are drawn per visible line by the decoration provider.
local function render(from)
  if not (S and vim.api.nvim_buf_is_valid(S.buf)) then return end
  local width = vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_width(S.win) - 2 or 120
  local base, lines = from and S.body or 0, {}
  if base == 0 then S.hls, S.rows, from = {}, {}, 1 end
  local function push(row, text, hl)
    lines[#lines + 1] = text
    S.hls[base + #lines], S.rows[base + #lines] = hl, row
  end
  for i = from, #S.commits do
    local c = S.commits[i]
    if matches(c) then push({ c = c }, commit_line(c, width)) end
    local files = matches(c) and S.open[c.sha] and (S.files[c.sha] or LOADING_FILES) or {}
    for _, f in ipairs(files) do push({ c = c, f = f }, file_line(c, f)) end
  end
  S.body = base + #lines
  local text, hl = status_note(S.body == 0)
  if text then push(nil, text, hl) end
  for n = base + #lines + 1, S.total or 0 do S.hls[n], S.rows[n] = nil, nil end
  S.total = base + #lines
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, base, -1, false, lines)
  vim.bo[S.buf].modifiable = false
end

local function quiet(text) vim.api.nvim_echo({ { "○ " .. text, "AosDim" } }, false, {}) end

-- Loading --------------------------------------------------------------------------------------
-- Every read goes through `job`: one run per key, a new one kills the one it supersedes (whose callback is
-- then dropped), and repo.run cuts it at 3 s, after which that feature reports itself paused.

local function job(key, args, cb, opts)
  local s, h = S, nil
  if s.jobs[key] then pcall(s.jobs[key].kill, s.jobs[key], 15) end
  h = repo.run(args, s.root, function(...)
    if S ~= s or s.jobs[key] ~= h then return end
    s.jobs[key] = nil
    cb(...)
  end, opts)
  s.jobs[key] = h
end

local function cancel(key)
  local h = S.jobs[key]
  S.jobs[key] = nil
  if h then pcall(h.kill, h, 15) end
end

local load

-- The row under the cursor as { sha, path?, line, upto = commits loaded then }.
local function anchor()
  if not vim.api.nvim_win_is_valid(S.win) then return end
  local line = vim.api.nvim_win_get_cursor(S.win)[1]
  local row = S.rows[line]
  return row and { sha = row.c.sha, path = row.f and row.f.path, line = line, upto = #S.commits }
end

local function find_row(last)
  for i, row in ipairs(S.rows) do
    if row.c.sha == last.sha and (row.f and row.f.path) == last.path then return i end
  end
end

-- Puts the cursor back on the row it was on before a refresh or when the graph last closed. When `chase` is set,
-- pages keep loading until as many commits are back as there were then, but only for BUDGET ms in all.
local function restore()
  local last = S.restore
  if not (last and vim.api.nvim_win_is_valid(S.win)) then return end
  local i = find_row(last)
  if i then
    S.restore = nil
    return vim.api.nvim_win_set_cursor(S.win, { i, 0 })
  end
  local late = vim.uv.now() - last.started + (S.page_ms or 0) > BUDGET
  if last.chase and not late and not S.done and not S.slow and #S.commits < (last.upto or 0) + PAGE then return load() end
  S.restore = nil
  if last.chase and late then quiet("position not restored · slow repo") end
  vim.api.nvim_win_set_cursor(S.win, { math.min(last.line, vim.api.nvim_buf_line_count(S.buf)), 0 })
end

-- A later page starts where the loaded part ends instead of re-walking it with --skip: from the commits the
-- open lanes wait for plus every walked ref tip not loaded yet. None of their ancestors is loaded (topo order
-- shows a commit only after all its children), so the pages join into one valid topological order.
local function frontier()
  local seen, list = {}, {}
  local function want(sha)
    if sha and not seen[sha] and not S.loaded[sha] then seen[sha], list[#list + 1] = true, sha end
  end
  for _, lane in ipairs(S.lanes) do want(lane and lane.sha) end
  for _, sha in pairs(S.all and S.tips or {}) do want(sha) end
  return list
end

local function unborn(err) return vim.iter(UNBORN):any(function(m) return err:find(m, 1, true) end) end

local function loaded(reset, count, ok, out, err, slow)
  S.loading = false
  if slow then
    S.slow, S.reset = true, nil
    render(#S.commits + 1)
    return restore()
  end
  if reset then S.commits, S.loaded, S.lanes, S.color, S.reset = {}, {}, {}, 0, nil end
  if not ok and not unborn(err) then S.error = err end
  local n, from = 0, #S.commits + 1
  S.page_ms = vim.uv.now() - S.page_at
  for line in out:gmatch("[^\n]+") do
    local c = parse(line)
    layout(c)
    S.commits[#S.commits + 1], S.loaded[c.sha], n = c, true, n + 1
  end
  S.done = not ok or n < count
  render(not reset and from or nil)
  restore()
end

-- A refresh keeps the old rows on screen and reloads as many commits as were shown (up to RELOAD), then swaps.
function load()
  if S.loading or S.done or S.slow then return end
  local reset = S.reset
  if not reset and S.all and not S.tips then
    S.want = true
    return
  end
  local count = reset and math.max(PAGE, math.min(#S.commits, RELOAD)) or PAGE
  local args, stdin = { "log", "--topo-order", "--decorate=full", "--format=" .. FORMAT, "-n", tostring(count) }, nil
  if reset then
    vim.list_extend(args, S.all and WALK or { "HEAD" })
  else
    stdin = frontier()
    if #stdin == 0 then
      S.done = true
      render(#S.commits + 1)
      return restore()
    end
    args[#args + 1] = "--stdin"
  end
  args[#args + 1] = "--"
  S.loading, S.page_at = true, vim.uv.now()
  job("log", args, function(...) loaded(reset, count, ...) end, { feature = "graph", stdin = stdin and table.concat(stdin, "\n") .. "\n" })
  render(not reset and #S.commits + 1 or nil)
end

-- Refreshes only when a ref or HEAD moved, so focus and file events cost one `show-ref` on a big repo; also
-- keeps S.tips for paging.
local function check()
  if not S then return end
  job("refs", { "show-ref", "--head", "-d" }, function(_, out, _, slow)
    if slow then
      S.tips = S.tips or {}
    elseif S.refs and out ~= S.refs then
      return M.refresh()
    else
      S.refs, S.tips = out, parse_tips(out)
    end
    if S.want then
      S.want = nil
      load()
    end
  end, { feature = "graph refs" })
end

-- A pending restore keeps its start time, so refreshes during a chase never extend it.
function M.refresh()
  if not S then return end
  if not (S.restore and S.restore.started) then
    S.restore = anchor() or S.restore
    if S.restore then S.restore.started, S.restore.chase = vim.uv.now(), true end
  end
  S.reset, S.done, S.loading, S.error, S.slow, S.refs, S.tips, S.want = true, false, false, nil, nil, nil, nil, nil
  repo.status(S.root, function(st)
    if not S then return end
    S.status = st
    vim.cmd.redrawstatus({ bang = true })
  end)
  check()
  load()
end

local function poke()
  if not S then return end
  S.timer:stop()
  S.timer:start(200, 0, vim.schedule_wrap(check))
end

-- Popup ----------------------------------------------------------------------------------------
-- Every view is a centred float (~90% x 85%); two panes are adjacent floats sharing that rectangle.

local function panes(split)
  local h = vim.o.lines - vim.o.cmdheight
  local W, H = math.floor(vim.o.columns * 0.9), math.floor(h * 0.85)
  local row, col = math.floor((h - H) / 2), math.floor((vim.o.columns - W) / 2)
  if not split then return { { relative = "editor", row = row, col = col, width = W - 2, height = H - 2 } } end
  local lw = math.floor(W * split)
  return {
    { relative = "editor", row = row, col = col, width = lw - 2, height = H - 2 },
    { relative = "editor", row = row, col = col + lw, width = W - lw - 2, height = H - 2 },
  }
end

local function when_closed(win, fn, group)
  vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), once = true, callback = function() vim.schedule(fn) end })
end

local function open_file(path)
  local file = S.root .. "/" .. path
  M.close()
  if not vim.uv.fs_stat(file) then return vim.notify("✗ " .. path .. " is not in the working tree", vim.log.levels.WARN) end
  vim.cmd.edit(vim.fn.fnameescape(file))
end

local function text_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden = false, "wipe"
  return buf
end

-- A small float over the graph; q, <Esc>, K, g? or leaving it closes it.
local function info_float(buf, lines, title)
  local widest = vim.iter(lines):fold(60, function(m, l) return math.max(m, vim.api.nvim_strwidth(l)) end)
  local width = math.min(widest + 2, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", width = width, height = height, row = math.floor((vim.o.lines - height) / 3),
    col = math.floor((vim.o.columns - width) / 2), title = title, title_pos = "left", zindex = 60,
  })
  vim.wo[win].wrap = true
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  for _, lhs in ipairs({ "q", "<Esc>", "K", "g?" }) do vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "close" }) end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

local function help(section)
  local lines = vim.tbl_map(function(k) return ("%-7s %s"):format(k[1], k[2]) end, section.keys)
  local buf = text_buf(lines)
  for i, k in ipairs(section.keys) do vim.hl.range(buf, fns, "AosArg", { i - 1, 0 }, { i - 1, #k[1] }) end
  info_float(buf, lines, " ❯ keys · " .. section.section .. " ")
end

-- Diff -----------------------------------------------------------------------------------------

local function close_diff()
  local d = S and S.diff
  if not d then return end
  S.diff = nil
  for _, w in ipairs(d.wins) do pcall(vim.api.nvim_win_close, w, true) end
  vim.o.diffopt = d.diffopt
  if not vim.api.nvim_win_is_valid(S.win) then return end
  vim.api.nvim_win_set_config(S.win, { hide = false })
  vim.api.nvim_set_current_win(S.win)
end

local function other_side()
  local w = S and S.diff and S.diff.wins
  if w and #w == 2 then vim.api.nvim_set_current_win(w[vim.api.nvim_get_current_win() == w[1] and 2 or 1]) end
end

-- { lhs, fn (nil: a native key listed for help), what it does }.
local DIFF_KEYS = {
  { "]c", nil, "next change" },
  { "[c", nil, "previous change" },
  { "<Tab>", other_side, "other side" },
  { "<C-l>", other_side, "other side" },
  { "<C-h>", other_side, "other side" },
  { "O", function() if S and S.diff then open_file(S.diff.path) end end, "open the file in the working tree (closes the graph)" },
  { "g?", function() help(M.keys[2]) end, "this help" },
  { "q", close_diff, "back to the graph" },
  { "<Esc>", close_diff, "back to the graph" },
}

local function map_keys(buf, list)
  for _, k in ipairs(list) do
    if k[2] then vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, desc = k[3] }) end
  end
end

local function scratch(name, text)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  return buf
end

-- Without `normal! ]c`: this runs from a git callback and a :normal would abort a cmdline being typed.
local function first_change(win)
  vim.api.nvim_win_call(win, function()
    local l, last = 1, vim.fn.line("$")
    while l < last and vim.fn.diff_hlID(l, 1) == 0 and vim.fn.diff_filler(l) == 0 do l = l + 1 end
    vim.api.nvim_win_set_cursor(win, { vim.fn.diff_hlID(l, 1) == 0 and vim.fn.diff_filler(l) == 0 and 1 or l, 0 })
  end)
end

local function title(verb, path, rev)
  return { { " ❯ ", "AosPrompt" }, { verb .. " ", "AosArg" }, { path .. "  ", "FloatTitle" }, { rev .. " ", "AosSha" } }
end

-- Each side titled with its own path, so a rename shows the old path on the old side.
local function diff_title(i, side, renamed)
  if i == 1 then return title("diff", side.path, side.r7) end
  local t = { { " ↔ ", "AosDim" }, { side.r7 .. " ", "AosSha" } }
  if renamed then table.insert(t, 2, { side.path .. "  ", "FloatTitle" }) end
  return t
end

-- Replaces the graph with floats in the same rectangle: old ↔ new diffed, or one plain pane; q brings the
-- graph back at its cursor. sides: { title, text, name, path (nil: no filetype) }.
local function show_panes(f, sides, diff)
  if not (S and vim.api.nvim_win_is_valid(S.win)) then return end
  close_diff()
  local d = { diffopt = vim.o.diffopt, wins = {}, path = f.path }
  S.diff = d
  if diff then vim.o.diffopt = DIFFOPT end
  vim.api.nvim_win_set_config(S.win, { hide = true })
  for i, cfg in ipairs(panes(#sides == 2 and 0.5 or nil)) do
    local side = sides[i]
    cfg.style, cfg.title_pos, cfg.title = "minimal", "left", side.title
    local buf = scratch(side.name, side.text)
    d.wins[i] = vim.api.nvim_open_win(buf, i == #sides, cfg)
    vim.wo[d.wins[i]].number, vim.wo[d.wins[i]].cursorline, vim.wo[d.wins[i]].foldmethod = true, true, "manual"
    if diff then vim.api.nvim_win_call(d.wins[i], vim.cmd.diffthis) end
    -- Set last: the global treesitter foldexpr would parse the whole buffer synchronously (2.5 s at 49k lines).
    if side.path then vim.bo[buf].filetype = vim.filetype.match({ filename = side.path, buf = buf }) or "" end
    map_keys(buf, DIFF_KEYS)
    when_closed(d.wins[i], function() if S and S.diff == d then close_diff() end end)
  end
  if diff then first_change(d.wins[2]) end
end

-- nvim's diff costs about 0.6 ms a hunk and grows with the file: past the bigfile limit or MAX_HUNKS the
-- commit's patch shows instead.
local function too_big(text)
  return #text > BIG_BYTES or select(2, text:gsub("\n", "")) > BIG_LINES
end

local function show_patch(c, f)
  local args = { "show", "--format=", "-U3", "-M", "--diff-merges=first-parent", c.sha, "--", f.path, f.orig }
  job("diff patch", args, function(ok, out, err, slow)
    if slow then return quiet("diff paused · slow repo") end
    if not ok then return vim.notify("✗ git show\n" .. err, vim.log.levels.ERROR) end
    local name = ("gitgraph://%s/%s.patch"):format(c.sha:sub(1, 7), f.path)
    show_panes(f, { { title = title("patch", f.path, c.sha:sub(1, 7)), text = out, name = name, path = "x.diff" } })
  end, { feature = "graph diff" })
end

-- An added or deleted file (or an empty side) shows the side that exists alone, like VS Code.
local function show_sides(c, f, sides, hunks)
  if #sides == 2 and (sides[1].text == "" or sides[2].text == "") then sides = { sides[sides[2].text == "" and 1 or 2] } end
  if #sides == 2 and (hunks > MAX_HUNKS or too_big(sides[1].text) or too_big(sides[2].text)) then return show_patch(c, f) end
  for i, x in ipairs(sides) do
    x.name, x.title = ("gitgraph://%s/%s"):format(x.r7, x.path), diff_title(i, x, f.orig ~= nil)
    if #sides == 1 then x.title, x.path = title(x.old and "deleted" or "added", x.path, x.r7), not too_big(x.text) and x.path or nil end
  end
  show_panes(f, sides, #sides == 2)
end

-- Both sides plus a -U0 patch whose hunk count is what nvim's diff would have to align.
local function open_diff(c, f)
  local old = { rev = c.parents[1], r7 = c.parents[1] and c.parents[1]:sub(1, 7) or "root", path = f.orig or f.path, old = true }
  local new = { rev = c.sha, r7 = c.sha:sub(1, 7), path = f.path }
  local sides = (f.letter == "A" or not old.rev) and { new } or f.letter == "D" and { old } or { old, new }
  local hunks = { args = { "show", "--format=", "-U0", "-M", "--diff-merges=first-parent", c.sha, "--", f.path, f.orig }, text = "" }
  local reads = #sides == 2 and { old, new, hunks } or sides
  local pending, slow = #reads, false
  for _, key in ipairs({ "diff patch", "diff 1", "diff 2", "diff 3" }) do cancel(key) end
  for i, r in ipairs(reads) do
    job("diff " .. i, r.args or { "show", r.rev .. ":" .. r.path }, function(ok, out, _, timed_out)
      r.text, pending, slow = ok and out or "", pending - 1, slow or timed_out
      if pending > 0 then return end
      if slow then return quiet("diff paused · slow repo") end
      show_sides(c, f, sides, select(2, hunks.text:gsub("\n@@", "")))
    end, { feature = "graph diff" })
  end
end

-- Actions --------------------------------------------------------------------------------------

local function current()
  return S.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function file_rows(ok, out, err, slow)
  if slow then return { { note = { "○", "AosDim", "files paused · slow repo", "AosDim" } } } end
  if not ok then return { { note = { "✗", "AosFailed", err } } } end
  local files = parse_files(out)
  if #files == 0 then return { { note = { "○", "AosDim", "no changes", "AosDim" } } } end
  if #files <= MAX_FILES then return files end
  local more = #files - MAX_FILES
  files = vim.list_slice(files, 1, MAX_FILES)
  files[#files + 1] = { note = { "○", "AosDim", more .. " more files · K for the stat", "AosDim" } }
  return files
end

-- `show` vs the first parent (a merge lists what it brought in); `show` is a budgeted read, unlike diff-tree.
local function fetch_files(c)
  local args = { "show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", c.sha }
  job("files " .. c.sha, args, function(ok, out, err, slow)
    S.files[c.sha] = file_rows(ok, out, err, slow)
    render()
  end, { feature = "graph files" })
end

local function toggle(c)
  S.open[c.sha] = not S.open[c.sha] or nil
  if S.open[c.sha] and not S.files[c.sha] then fetch_files(c) end
  if not S.open[c.sha] then cancel("files " .. c.sha) end
  render()
end

local function stat_hls(buf, i, line)
  local bar = line:find("|", 1, true)
  if not bar then return vim.hl.range(buf, fns, "AosDim", { i, 0 }, { i, #line }) end
  local plus, minus = line:match("(%+*)(%-*)%s*$", bar)
  local s = #line - #plus - #minus
  vim.hl.range(buf, fns, "AosDone", { i, s }, { i, s + #plus })
  vim.hl.range(buf, fns, "AosFailed", { i, s + #plus }, { i, #line })
end

local function show_float(c, out)
  local sha, author, date, body, stat = unpack(vim.split(out, "\0", { plain = true }))
  local labels = { { "sha", sha, "AosSha" }, { "author", author, "AosId" }, { "date", date .. " · " .. ago(c.time), "AosSha" } }
  local refs = vim.tbl_map(function(r) return vim.trim(r.text) end, c.refs)
  if #refs > 0 then labels[#labels + 1] = { "refs", table.concat(refs, "  "), "AosArg" } end
  local lines = {}
  for _, l in ipairs(labels) do lines[#lines + 1] = ("%-6s · %s"):format(l[1], l[2]) end
  local body_at = #lines + 1
  vim.list_extend(lines, vim.split("\n" .. vim.trim(body or ""), "\n", { plain = true }))
  local stat_at = #lines + 1
  stat = (stat or ""):gsub("^\n+", ""):gsub("%s+$", "")
  if stat ~= "" then vim.list_extend(lines, vim.split("\n" .. stat, "\n", { plain = true })) end
  local buf = text_buf(lines)
  for i, l in ipairs(labels) do
    vim.hl.range(buf, fns, "AosDim", { i - 1, 0 }, { i - 1, 9 })
    vim.hl.range(buf, fns, l[3], { i - 1, 10 }, { i - 1, -1 })
  end
  vim.hl.range(buf, fns, "Title", { body_at, 0 }, { body_at, -1 })
  for i = stat_at + 1, #lines do stat_hls(buf, i - 1, lines[i]) end
  info_float(buf, lines, " ❯ show " .. sha:sub(1, 7) .. " ")
end

local function show(c)
  local args = { "show", "--stat=100", "--stat-count=300", "--diff-merges=first-parent", "--date=format:%Y-%m-%d %H:%M", "--format=%H%x00%an <%ae>%x00%ad%x00%B%x00", c.sha }
  job("show", args, function(ok, out, err, slow)
    if slow then return quiet("show paused · slow repo") end
    if not ok then return vim.notify("✗ git show\n" .. err, vim.log.levels.ERROR) end
    show_float(c, out)
  end, { feature = "graph show" })
end

local function checkout_targets(c)
  local targets = {}
  for _, r in ipairs(c.refs) do
    if r.kind and r.kind ~= "tag" and not r.head then targets[#targets + 1] = { kind = r.kind, name = r.name } end
  end
  targets[#targets + 1] = { kind = "detached", name = c.sha, label = c.sha:sub(1, 7) .. " (detached)" }
  return targets
end

local target_glyph = { remote = { "⇄", "AosSha" }, ["local"] = { "○", "AosId" }, detached = { "●", "AosDim" } }

-- branch.checkout asks stash / carry over / cancel when local changes block the switch.
local function checkout(c)
  local root, targets = S.root, checkout_targets(c)
  if #targets == 1 then return branch.checkout(root, targets[1]) end
  local items = vim.tbl_map(function(t)
    local g = target_glyph[t.kind]
    return { glyph = g[1], hl = g[2], text = t.label or t.name, data = t }
  end, targets)
  pick.open({ title = "checkout", items = items, on_choose = function(item) branch.checkout(root, item.data) end })
end

local function on_row(fn)
  return function()
    local row = current()
    if row then fn(row) end
  end
end

local function set_filter()
  vim.ui.input({ prompt = "filter: ", default = S.filter }, function(q)
    if not q or not S then return end
    S.filter = vim.trim(q):lower()
    render()
    vim.api.nvim_win_set_cursor(S.win, { 1, 0 })
  end)
end

local function enter(r)
  if r.f and r.f.path then return open_diff(r.c, r.f) end
  if not r.f then toggle(r.c) end
end

local function yank(r)
  vim.fn.setreg('"', r.c.sha)
  pcall(vim.fn.setreg, "+", r.c.sha)
  vim.notify("✓ yanked " .. r.c.sha:sub(1, 7))
end

-- The cursor's commit is looked for in the other walk's first load only; its row number there means nothing.
local function toggle_walk()
  S.all = not S.all
  S.restore = anchor()
  if S.restore then S.restore.started, S.restore.chase, S.restore.line = vim.uv.now(), false, 1 end
  M.refresh()
end

local function clear_or_close()
  if S.filter == "" then return M.close() end
  S.filter = ""
  render()
end

-- { lhs, fn, what it does, winbar hint? }; the winbar hints, g? and M.keys all come from this list.
local GRAPH_KEYS = {
  { "/", set_filter, "filter commits by subject, author or sha", "/ filter" },
  { "b", toggle_walk, "all branches, remotes and tags ↔ HEAD only", "b branches" },
  { "<CR>", on_row(enter), "expand / collapse the commit's files · on a file: side-by-side diff", "⏎ files" },
  { "<Tab>", on_row(function(r) toggle(r.c) end), "expand / collapse the commit's files" },
  { "K", on_row(function(r) show(r.c) end), "commit details: message and stat", "K show" },
  { "c", on_row(function(r) checkout(r.c) end), "check out a branch on the commit, or the commit detached", "c checkout" },
  { "y", on_row(yank), "yank the full sha", "y yank" },
  { "r", function() M.refresh() end, "refresh", "r refresh" },
  { "O", on_row(function(r) if r.f and r.f.path then open_file(r.f.path) end end), "open the file row's file (closes the graph)", "O open" },
  { "g?", function() help(M.keys[1]) end, "this help", "g? keys" },
  { "<Esc>", clear_or_close, "clear the filter, else close" },
  { "q", function() M.close() end, "close", "q close" },
}

local function section(name, list)
  return { section = name, keys = vim.tbl_map(function(k) return { k[1], k[3] } end, list) }
end

M.keys = { section("Git graph", GRAPH_KEYS), section("Git graph diff", DIFF_KEYS) }

-- Winbar segments as { text, group }; the key hints are dropped whole from the end when the popup is narrow.
function M.header()
  if not S then return "" end
  local walk = "git log --graph " .. table.concat(S.all and WALK or { "HEAD" }, " ") .. " "
  local segs = { { " ❯ ", "AosPrompt" }, { walk, "AosArg" } }
  local st = S.status
  if st then
    segs[#segs + 1] = { " " .. (st.branch or ("HEAD " .. (st.oid or ""):sub(1, 7))) .. " ", "AosSegCyan" }
    if st.upstream then segs[#segs + 1] = { (" ↑%d ↓%d"):format(st.ahead or 0, st.behind or 0), "AosDim" } end
  end
  if S.filter ~= "" then segs[#segs + 1] = { " /" .. S.filter, "AosRunning" } end
  local room = vim.api.nvim_win_get_width(S.win) - vim.iter(segs):fold(0, function(n, x) return n + vim.api.nvim_strwidth(x[1]) end)
  for _, k in ipairs(GRAPH_KEYS) do
    room = room - (k[4] and vim.api.nvim_strwidth(k[4]) + 3 or 0)
    if room < 0 then break end
    if k[4] then segs[#segs + 1] = { " · " .. k[4], "AosFaint" } end
  end
  return table.concat(vim.tbl_map(function(x) return "%#" .. x[2] .. "#" .. esc(x[1]) end, segs))
end

-- Window ---------------------------------------------------------------------------------------

function M.close()
  if not S then return end
  local s = S
  close_diff()
  M.last = anchor()
  if M.last then M.last.root, M.last.path = s.root, nil end
  S = nil
  s.timer:close()
  for _, w in pairs(s.watched) do w:close() end
  for _, h in pairs(s.jobs) do pcall(h.kill, h, 15) end
  pcall(vim.api.nvim_del_augroup_by_name, "GitGraphBuf")
  pcall(vim.api.nvim_win_close, s.win, true)
  pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  if vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
end

local function reposition()
  if not S then return end
  vim.api.nvim_win_set_config(S.win, panes()[1])
  for i, cfg in ipairs(S.diff and panes(#S.diff.wins == 2 and 0.5 or nil) or {}) do vim.api.nvim_win_set_config(S.diff.wins[i], cfg) end
  render()
end

local function autocmds(buf, win)
  local group = vim.api.nvim_create_augroup("GitGraphBuf", {})
  when_closed(win, function() if S and S.win == win then M.close() end end, group)
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = reposition })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group, buffer = buf,
    callback = function() if vim.fn.line(".") > vim.fn.line("$") - 60 then load() end end,
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = poke })
end

local watch_tree

-- `names` limits a git dir to HEAD/packed-refs; under refs/ a new entry that is a directory (refs/heads/feature/)
-- gets watched too, since inotify is not recursive.
local function watch(dir, names)
  if S.watched[dir] then S.watched[dir]:close() end
  local w = vim.uv.new_fs_event()
  if not w then return end
  w:start(dir, {}, function(_, name)
    if not name or name:match("%.lock$") or (names and not names[name]) then return end
    vim.schedule(function()
      poke()
      if not names then watch_tree(dir .. "/" .. name) end
    end)
  end)
  S.watched[dir] = w
end

function watch_tree(dir)
  local st = S and vim.uv.fs_stat(dir)
  if not (st and st.type == "directory") then return end
  watch(dir)
  for name, kind in vim.fs.dir(dir, { depth = 6 }) do
    if kind == "directory" then watch(dir .. "/" .. name) end
  end
end

local function watch_refs()
  local s = S
  repo.run({ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, S.root, function(ok, out)
    if not (ok and S == s) then return end
    local git_dir, common = unpack(vim.split(vim.trim(out), "\n", { plain = true }))
    local top = { HEAD = true, ["packed-refs"] = true }
    watch(git_dir, top)
    if common ~= git_dir then watch(common, top) end
    watch_tree(common .. "/refs")
  end, { feature = "graph refs" })
end

function M.open()
  local root = branch.root()
  if not root then return vim.notify("✗ not a git repository", vim.log.levels.WARN) end
  local origin, buf = vim.api.nvim_get_current_win(), vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "gitgraph://" .. root)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  vim.b[buf].git_root = root
  local cfg = panes()[1]
  cfg.style, cfg.title, cfg.title_pos = "minimal", " ❯ git log ", "left"
  local win = vim.api.nvim_open_win(buf, true, cfg)
  S = { root = root, buf = buf, win = win, origin = origin, all = true, filter = "", open = {}, files = {}, hls = {}, rows = {} }
  S.commits, S.loaded, S.lanes, S.color, S.jobs, S.watched, S.timer = {}, {}, {}, 0, {}, {}, assert(vim.uv.new_timer())
  S.restore = M.last and M.last.root == root and M.last or nil
  vim.wo[win].cursorline, vim.wo[win].wrap, vim.wo[win].foldcolumn = true, false, "1"
  vim.wo[win].winbar = "%!v:lua.require'git.graph'.header()"
  vim.bo[buf].filetype = "gitgraph"
  map_keys(buf, GRAPH_KEYS)
  autocmds(buf, win)
  watch_refs()
  M.refresh()
end

function M.toggle()
  if not S then return M.open() end
  local cur = vim.api.nvim_get_current_win()
  if cur == S.win or (S.diff and vim.tbl_contains(S.diff.wins, cur)) then return M.close() end
  vim.api.nvim_set_current_win(S.diff and S.diff.wins[2] or S.win)
end

function M.setup()
  branch.setup()
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf) return S ~= nil and buf == S.buf end,
    on_line = function(_, _, buf, row)
      for _, h in ipairs(S.hls[row + 1] or {}) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, h[1], { end_col = h[2], hl_group = h[3], ephemeral = true })
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", { pattern = "GitChanged", callback = poke })
  vim.keymap.set("n", "<leader>gl", M.toggle, { desc = "Git graph" })
  vim.api.nvim_create_user_command("GitGraph", M.toggle, { desc = "Source Control Graph" })
end

return M
