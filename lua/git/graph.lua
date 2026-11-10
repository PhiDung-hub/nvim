-- Source Control Graph: `git log --topo-order` laid out into coloured lanes here (no `--graph` parsing).
-- A centred popup; commits expand inline into their changed files, a file swaps the popup for a side-by-side diff.
local M = {}
local repo = require("git.repo")
local branch = require("git.branch")
local icons = require("ui.icons")
local pick = require("ui.pick")
local ns = vim.api.nvim_create_namespace("git.graph")
local fns = vim.api.nvim_create_namespace("git.graph.float")
local PAGE, LANES, MAX_ART = 400, 6, 40
local FORMAT = "%H%x00%P%x00%D%x00%an%x00%at%x00%s"
local UNBORN = { "does not have any commits", "unknown revision", "bad revision 'HEAD'" }
local DIFFOPT = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:char"
local letter_hl = { M = "AosRunning", A = "AosDone", D = "AosFailed", R = "AosId", C = "AosId", T = "AosRunning", U = "AosDone" }
local corner = { ["end"] = { "╰", "╯" }, start = { "╭", "╮" }, join = { "├", "┤" } }
local tee = { ["end"] = "┴", start = "┬", join = "┼" }
local S -- the open graph

local function esc(s) return (s:gsub("%%", "%%%%")) end

-- Lanes ----------------------------------------------------------------------------------------
-- S.lanes[i] is the lane in column i ({ sha = commit it waits for, color }) or false when free.

local function lane_hl(lane) return "AosGraphLane" .. lane.color end

local function new_lane(sha)
  S.color = S.color % LANES + 1
  return { sha = sha, color = S.color }
end

local function free_slot(lanes, reserved)
  local i = 1
  while lanes[i] or reserved[i] do i = i + 1 end
  return i
end

local function link_parent(lanes, links, reserved, col, sha)
  for j = 1, #lanes do
    if j ~= col and lanes[j] and lanes[j].sha == sha then
      links[#links + 1] = { j, "join", lanes[j] }
      return
    end
  end
  local j = free_slot(lanes, reserved)
  lanes[j], reserved[j] = new_lane(sha), true
  links[#links + 1] = { j, "start", lanes[j] }
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

-- Column i sits in cell 2i-1; the cell between two columns carries horizontal links.
-- Cells stop at MAX_ART: a wider graph ends in "…" followed by the node when it sits beyond.
local function draw(c)
  local width = math.max(#c.before, #c.below, c.col)
  local n, at = math.min(2 * width - 1, MAX_ART), 2 * c.col - 1
  local cells = {}
  for i = 1, n do cells[i] = { " " } end
  table.sort(c.links, function(a, b) return math.abs(a[1] - c.col) > math.abs(b[1] - c.col) end)
  for _, l in ipairs(c.links) do
    for p = 2 * math.min(l[1], c.col), math.min(2 * math.max(l[1], c.col) - 2, n) do cells[p] = { "─", lane_hl(l[3]) } end
  end
  for i = 1, (n + 1) / 2 do
    if c.before[i] and c.below[i] then cells[2 * i - 1] = { "│", lane_hl(c.below[i]) } end
  end
  local far = {}
  for _, l in ipairs(c.links) do
    local side, p = l[1] > c.col and 2 or 1, 2 * l[1] - 1
    if p <= n then cells[p] = { far[side] and tee[l[2]] or corner[l[2]][side], lane_hl(l[3]) } end
    far[side] = true
  end
  local node = { c.head and "◉" or #c.parents > 1 and "○" or "●", c.head and "AosGraphHead" or lane_hl(c.node) }
  if at <= n then cells[at] = node end
  if 2 * width - 1 > MAX_ART then cells[n - 1], cells[n] = { "…", "AosFaint" }, at > n - 2 and node or nil end
  c.art, c.art_hl = join(cells)
end

-- Places commit `c` into S.lanes: c.col, c.before/c.below (lanes above/below the row), c.links, c.art.
local function layout(c)
  local lanes, before, links, reserved, col = S.lanes, {}, {}, {}, nil
  for i = 1, #lanes do
    before[i] = lanes[i]
    if lanes[i] and lanes[i].sha == c.sha and col then
      links[#links + 1], lanes[i], reserved[i] = { i, "end", lanes[i] }, false, true
    elseif lanes[i] and lanes[i].sha == c.sha then
      col = i
    end
  end
  if not col then
    col = free_slot(lanes, reserved)
    lanes[col] = new_lane(c.sha)
  end
  local node = lanes[col]
  lanes[col] = c.parents[1] and { sha = c.parents[1], color = node.color } or false
  reserved[col] = true
  for k = 2, #c.parents do link_parent(lanes, links, reserved, col, c.parents[k]) end
  while #lanes > 0 and not lanes[#lanes] do lanes[#lanes] = nil end
  c.col, c.node, c.links, c.before, c.below = col, node, links, before, { unpack(lanes) }
  draw(c)
end

-- Lanes passing below a commit, for its expanded file rows.
local function continuation(c)
  local n, cells = math.min(#c.below * 2 - 1, MAX_ART), {}
  for i = 1, n do cells[i] = { " " } end
  for i = 1, (n + 1) / 2 do
    if c.below[i] then cells[2 * i - 1] = { "│", lane_hl(c.below[i]) } end
  end
  if #c.below * 2 - 1 > MAX_ART then cells[n - 1], cells[n] = { "…", "AosFaint" }, nil end
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

local function build_line(c, width)
  local b = S.filter == "" and with_art(c.art, c.art_hl) or with_art("●", { { 0, #"●", c.head and "AosGraphHead" or lane_hl(c.node) } })
  add(b, " ")
  for _, r in ipairs(c.refs) do
    add(b, r.text, r.hl)
    add(b, " ")
  end
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
  if f.error then
    add(b, "✗ · ", "AosFailed")
    add(b, (vim.trim(f.error):gsub("\n", " ")))
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

local function note(glyph, hl, text) return glyph .. " · " .. text, { { 0, #glyph, hl } } end

-- Rebuilds the buffer from S.commits; highlights are drawn per visible line by the decoration provider.
local function render()
  if not (S and vim.api.nvim_buf_is_valid(S.buf)) then return end
  local width = vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_width(S.win) - 2 or 120
  local lines, hls, rows = {}, {}, {}
  local function push(row, text, hl)
    local n = #lines + 1
    lines[n], hls[n], rows[n] = text, hl, row
  end
  for _, c in ipairs(S.commits) do
    if matches(c) then push({ c = c }, commit_line(c, width)) end
    local files = matches(c) and S.open[c.sha] and (S.files[c.sha] or { { error = "loading…" } }) or {}
    for _, f in ipairs(files) do push({ c = c, f = f }, file_line(c, f)) end
  end
  if S.error then push(nil, note("✗", "AosFailed", (vim.trim(S.error):gsub("\n", " "))))
  elseif S.loading then push(nil, note("◆", "AosRunning", "loading…"))
  elseif #lines == 0 then push(nil, note("○", "AosDim", S.filter ~= "" and ("no match for " .. S.filter) or "no commits yet"))
  elseif not S.done then push(nil, note("▸", "AosDim", "more on scroll")) end
  S.hls, S.rows = hls, rows
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
end

-- Loading --------------------------------------------------------------------------------------

local load

-- The row under the cursor as { sha, path?, line }.
local function anchor()
  if not vim.api.nvim_win_is_valid(S.win) then return end
  local line = vim.api.nvim_win_get_cursor(S.win)[1]
  local row = S.rows[line]
  return row and { sha = row.c.sha, path = row.f and row.f.path, line = line }
end

-- Puts the cursor back on the row it was on before a refresh or when the graph last closed;
-- one extra page is loaded when that commit has not arrived yet.
local function restore()
  local last = S.restore
  if not (last and vim.api.nvim_win_is_valid(S.win)) then return end
  for i, row in ipairs(S.rows) do
    if row.c.sha == last.sha and (row.f and row.f.path) == last.path then
      S.restore = nil
      return vim.api.nvim_win_set_cursor(S.win, { i, 0 })
    end
  end
  if not (S.done or last.more) then
    last.more = true
    return load()
  end
  S.restore = nil
  vim.api.nvim_win_set_cursor(S.win, { math.min(last.line, vim.api.nvim_buf_line_count(S.buf)), 0 })
end

-- A refresh keeps the old rows on screen and reloads as many commits as were shown, then swaps them in.
function load()
  if S.loading or S.done then return end
  S.loading = true
  local gen, reset = S.gen, S.reset
  local count = reset and math.max(PAGE, #S.commits) or PAGE
  local args = { "log", "--topo-order", "--decorate=full", "--format=" .. FORMAT, "--skip=" .. (reset and 0 or #S.commits), "-n", tostring(count) }
  vim.list_extend(args, S.all and { "--branches", "--remotes", "--tags", "HEAD", "--" } or { "HEAD", "--" })
  repo.run(args, S.root, function(ok, out, err)
    if not S or gen ~= S.gen then return end
    local t0, n = vim.uv.hrtime(), 0
    S.loading = false
    if reset then S.restore, S.commits, S.lanes, S.color, S.reset = anchor() or S.restore, {}, {}, 0, nil end
    if not ok and not vim.iter(UNBORN):any(function(m) return err:find(m, 1, true) end) then S.error = err end
    for line in out:gmatch("[^\n]+") do
      local c = parse(line)
      layout(c)
      S.commits[#S.commits + 1], n = c, n + 1
    end
    S.done = n < count
    render()
    restore()
    S.ms = (vim.uv.hrtime() - t0) / 1e6
  end)
  render()
end

function M.refresh()
  if not S then return end
  S.gen = S.gen + 1
  S.reset, S.done, S.loading, S.error = true, false, false, nil
  repo.status(S.root, function(st)
    if not S then return end
    S.status = st
    vim.cmd.redrawstatus({ bang = true })
  end)
  repo.run({ "show-ref", "--head" }, S.root, function(_, out) if S then S.refs = out end end)
  load()
end

-- Refreshes only when a ref or HEAD moved, so focus and file events cost one `show-ref` on a big repo.
local function check()
  if not S then return end
  repo.run({ "show-ref", "--head" }, S.root, function(_, out)
    if S and out ~= S.refs then M.refresh() end
  end)
end

local function poke()
  if not S then return end
  S.timer:stop()
  S.timer:start(200, 0, vim.schedule_wrap(check))
end

local HINTS = { "/ filter", "b branches", "⏎ files", "K show", "c checkout", "y yank", "r refresh", "O open", "q close" }

-- Winbar segments as { text, group }; the key hints are dropped whole from the end when the popup is narrow.
function M.header()
  if not S then return "" end
  local segs = { { " ❯ ", "AosPrompt" }, { "git log --graph " .. (S.all and "--all" or "HEAD") .. " ", "AosArg" } }
  local st = S.status
  if st then
    segs[#segs + 1] = { " " .. (st.branch or ("HEAD " .. (st.oid or ""):sub(1, 7))) .. " ", "AosSegCyan" }
    if st.upstream then segs[#segs + 1] = { (" ↑%d ↓%d"):format(st.ahead or 0, st.behind or 0), "AosDim" } end
  end
  if S.filter ~= "" then segs[#segs + 1] = { " /" .. S.filter, "AosRunning" } end
  local room = vim.api.nvim_win_get_width(S.win) - vim.iter(segs):fold(0, function(n, x) return n + vim.api.nvim_strwidth(x[1]) end)
  for _, h in ipairs(HINTS) do
    room = room - vim.api.nvim_strwidth(h) - 3
    if room < 0 then break end
    segs[#segs + 1] = { " · " .. h, "AosFaint" }
  end
  return table.concat(vim.tbl_map(function(x) return "%#" .. x[2] .. "#" .. esc(x[1]) end, segs))
end

-- Actions --------------------------------------------------------------------------------------

local function current()
  return S.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function fetch_files(c)
  local args = { "diff-tree", "-r", "-z", "--name-status", "-M", "--no-commit-id" }
  vim.list_extend(args, c.parents[1] and { c.parents[1], c.sha } or { "--root", c.sha })
  repo.run(args, S.root, function(ok, out, err)
    if not S then return end
    S.files[c.sha] = ok and parse_files(out) or { { error = err } }
    if ok and #S.files[c.sha] == 0 then S.files[c.sha] = { { error = "no changes" } } end
    render()
  end)
end

local function toggle(c)
  S.open[c.sha] = not S.open[c.sha] or nil
  if S.open[c.sha] and not S.files[c.sha] then fetch_files(c) end
  render()
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

local function open_file(path)
  local file = S.root .. "/" .. path
  M.close()
  if not vim.uv.fs_stat(file) then return vim.notify("✗ " .. path .. " is not in the working tree", vim.log.levels.WARN) end
  vim.cmd.edit(vim.fn.fnameescape(file))
end

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

local function diff_keys(buf, d, path)
  local function other() vim.api.nvim_set_current_win(d.wins[vim.api.nvim_get_current_win() == d.wins[1] and 2 or 1]) end
  local maps = { q = close_diff, ["<Esc>"] = close_diff, ["<Tab>"] = other, ["<C-l>"] = other, ["<C-h>"] = other, O = function() open_file(path) end }
  for lhs, fn in pairs(maps) do vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
end

local function scratch(name, text, path)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
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

-- Replaces the graph with old ↔ new floats in the same rectangle; q brings the graph back at its cursor.
local function show_diff(c, f, old, new)
  if not (S and vim.api.nvim_win_is_valid(S.win)) then return end
  close_diff()
  local p7, s7, old_path = c.parents[1] and c.parents[1]:sub(1, 7) or "root", c.sha:sub(1, 7), f.orig or f.path
  local sides = { { p7, old, old_path }, { s7, new, f.path } }
  local d = { diffopt = vim.o.diffopt, wins = {} }
  S.diff, vim.o.diffopt = d, DIFFOPT
  vim.api.nvim_win_set_config(S.win, { hide = true })
  for i, cfg in ipairs(panes(0.5)) do
    local rev, text, path = unpack(sides[i])
    cfg.style, cfg.title_pos = "minimal", "left"
    cfg.title = i == 1 and { { " ❯ ", "AosPrompt" }, { "diff ", "AosArg" }, { f.path .. "  ", "FloatTitle" }, { rev .. " ", "AosSha" } }
      or { { " ↔ ", "AosDim" }, { rev .. " ", "AosSha" } }
    local buf = scratch(("gitgraph://%s/%s"):format(rev, path), text, path)
    d.wins[i] = vim.api.nvim_open_win(buf, i == 2, cfg)
    vim.wo[d.wins[i]].number, vim.wo[d.wins[i]].cursorline = true, true
    vim.api.nvim_win_call(d.wins[i], function() vim.cmd.diffthis() end)
    diff_keys(buf, d, f.path)
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(d.wins[i]), once = true,
      callback = function() vim.schedule(function() if S and S.diff == d then close_diff() end end) end,
    })
  end
  first_change(d.wins[2])
end

local function open_diff(c, f)
  local texts, pending = {}, 2
  local function got(key)
    return function(text)
      texts[key], pending = text or "", pending - 1
      if pending == 0 then show_diff(c, f, texts.old, texts.new) end
    end
  end
  if c.parents[1] then repo.show(S.root, c.parents[1], f.orig or f.path, got("old")) else got("old")("") end
  repo.show(S.root, c.sha, f.path, got("new"))
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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, l in ipairs(labels) do
    vim.hl.range(buf, fns, "AosDim", { i - 1, 0 }, { i - 1, 9 })
    vim.hl.range(buf, fns, l[3], { i - 1, 10 }, { i - 1, -1 })
  end
  vim.hl.range(buf, fns, "Title", { body_at, 0 }, { body_at, -1 })
  for i = stat_at + 1, #lines do stat_hls(buf, i - 1, lines[i]) end
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden = false, "wipe"
  local widest = vim.iter(lines):fold(60, function(m, l) return math.max(m, vim.api.nvim_strwidth(l)) end)
  local width = math.min(widest + 2, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", width = width, height = height, row = math.floor((vim.o.lines - height) / 3),
    col = math.floor((vim.o.columns - width) / 2), title = " ❯ show " .. sha:sub(1, 7) .. " ", title_pos = "left", zindex = 60,
  })
  vim.wo[win].wrap = true
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  for _, lhs in ipairs({ "q", "<Esc>", "K" }) do vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true }) end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

local function show(c)
  local args = { "show", "--stat=100", "--stat-count=300", "--diff-merges=first-parent", "--date=format:%Y-%m-%d %H:%M", "--format=%H%x00%an <%ae>%x00%ad%x00%B%x00", c.sha }
  repo.run(args, S.root, function(ok, out, err)
    if not ok then return vim.notify("✗ git show\n" .. err, vim.log.levels.ERROR) end
    show_float(c, out)
  end)
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

local function checkout(c)
  local root = S.root
  local function go(t)
    if not t then return end
    branch.dirty(root, function(dirty)
      local label = t.label or t.name
      if dirty and vim.fn.confirm("Uncommitted changes. Check out " .. label .. " anyway?", "&Yes\n&No", 2) ~= 1 then return end
      branch.checkout(root, t)
    end)
  end
  local targets = checkout_targets(c)
  if #targets == 1 then return go(targets[1]) end
  local items = vim.tbl_map(function(t)
    local g = target_glyph[t.kind]
    return { glyph = g[1], hl = g[2], text = t.label or t.name, data = t }
  end, targets)
  pick.open({ title = "checkout", items = items, on_choose = function(item) go(item.data) end })
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

local keys = {
  ["<CR>"] = on_row(function(r) if r.f and r.f.path then open_diff(r.c, r.f) elseif not r.f then toggle(r.c) end end),
  ["<Tab>"] = on_row(function(r) toggle(r.c) end),
  K = on_row(function(r) show(r.c) end),
  y = on_row(function(r)
    vim.fn.setreg('"', r.c.sha)
    pcall(vim.fn.setreg, "+", r.c.sha)
    vim.notify("✓ yanked " .. r.c.sha:sub(1, 7))
  end),
  c = on_row(function(r) checkout(r.c) end),
  r = function() M.refresh() end,
  b = function() S.all = not S.all; M.refresh() end,
  ["/"] = set_filter,
  O = on_row(function(r) if r.f and r.f.path then open_file(r.f.path) end end),
  ["<Esc>"] = function()
    if S.filter == "" then return M.close() end
    S.filter = ""
    render()
  end,
  q = function() M.close() end,
}

-- Window ---------------------------------------------------------------------------------------

function M.close()
  if not S then return end
  local s = S
  close_diff()
  if vim.api.nvim_win_is_valid(s.win) then
    local line = vim.api.nvim_win_get_cursor(s.win)[1]
    M.last = { root = s.root, line = line, sha = s.rows[line] and s.rows[line].c.sha }
  end
  S = nil
  s.timer:close()
  for _, w in ipairs(s.watchers) do w:close() end
  pcall(vim.api.nvim_del_augroup_by_name, "GitGraphBuf")
  pcall(vim.api.nvim_win_close, s.win, true)
  pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  if vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
end

local function reposition()
  if not S then return end
  vim.api.nvim_win_set_config(S.win, panes()[1])
  for i, cfg in ipairs(S.diff and panes(0.5) or {}) do vim.api.nvim_win_set_config(S.diff.wins[i], cfg) end
  render()
end

local function autocmds(buf, win)
  local group = vim.api.nvim_create_augroup("GitGraphBuf", {})
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group, pattern = tostring(win),
    callback = function() vim.schedule(function() if S and S.win == win then M.close() end end) end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = reposition })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group, buffer = buf,
    callback = function() if vim.fn.line(".") > vim.fn.line("$") - 60 then load() end end,
  })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = poke })
end

local function watch(dir, names)
  local w = vim.uv.new_fs_event()
  if not w then return end
  w:start(dir, {}, function(_, name)
    if name and not name:match("%.lock$") and (not names or names[name]) then vim.schedule(poke) end
  end)
  S.watchers[#S.watchers + 1] = w
end

-- inotify is not recursive: the git dirs (HEAD, packed-refs) plus every directory under refs/.
local function watch_refs()
  local s = S
  repo.run({ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, S.root, function(ok, out)
    if not (ok and S == s) then return end
    local git_dir, common = unpack(vim.split(vim.trim(out), "\n", { plain = true }))
    local top = { HEAD = true, ["packed-refs"] = true }
    watch(git_dir, top)
    if common ~= git_dir then watch(common, top) end
    watch(common .. "/refs")
    for name, kind in vim.fs.dir(common .. "/refs", { depth = 6 }) do
      if kind == "directory" then watch(common .. "/refs/" .. name) end
    end
  end)
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
  S = { root = root, buf = buf, win = win, origin = origin, all = true, filter = "", open = {}, files = {}, gen = 0, hls = {}, rows = {} }
  S.commits, S.watchers, S.timer = {}, {}, assert(vim.uv.new_timer())
  S.restore = M.last and M.last.root == root and M.last or nil
  vim.wo[win].cursorline, vim.wo[win].wrap, vim.wo[win].foldcolumn = true, false, "1"
  vim.wo[win].winbar = "%!v:lua.require'git.graph'.header()"
  vim.bo[buf].filetype = "gitgraph"
  for lhs, fn in pairs(keys) do vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
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
