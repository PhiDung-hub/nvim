local M = {}
local uv, api = vim.uv, vim.api
local repo, icons = require("git.repo"), require("ui.icons")
local ns = api.nvim_create_namespace("ui.tree")
local LIMIT, BUDGET, GIT_DELAY = 2000, 3000, 300
local function state(width)
  return { nodes = {}, rows = {}, lines = {}, index = {}, watchers = {}, gitpaths = {}, width = width or 40, epoch = 0,
    source = "filesystem", selection = {}, clipboard = {}, trash = {} }
end
local S, tabs, epoch = state(), {}, 0
local git, diagnostics, modified = {}, {}, {}
local render, scan, watch, refresh_git, forget, save_session, refresh_buffers, close_preview, preview, clear_filter, locate, buffer_destination, pin_source
local LETTER = { M = "AosRunning", T = "AosRunning", A = "AosDone", U = "AosDone", D = "AosFailed", R = "AosId", C = "AosId", ["!"] = "AosFailed" }

local function visible() return S.win and api.nvim_win_is_valid(S.win) and api.nvim_win_get_buf(S.win) == S.buf end
local function notify(text) vim.notify("○ tree · " .. text, vim.log.levels.WARN) end
local function display(text) return (text:gsub("%c", "?")) end
local function join(dir, name) return (dir == "/" and "" or dir) .. "/" .. name end
local function within(path, dir) return path == dir or path:sub(1, #join(dir, "")) == join(dir, "") end
local function stop(handle)
  if handle and not handle:is_closing() then handle:stop() handle:close() end
end
local function later(fn) return vim.schedule_wrap(fn) end
local function selected() return visible() and S.rows[api.nvim_win_get_cursor(S.win)[1]] end
local function node_at() local row = selected() return row and row.node end
local function cache() return S.gitroot and git[S.gitroot] end

local function debounce(key, ms, fn)
  local epoch = S.epoch
  stop(S[key])
  local timer = uv.new_timer()
  S[key] = timer
  timer:start(ms, 0, later(function()
    stop(timer)
    if S[key] ~= timer then return end
    S[key] = nil
    if epoch == S.epoch and visible() then fn() end
  end))
end

local function hidden(node)
  if node.name:match("^%.nvim%-tree%-") then return true end
  if S.source == "buffers" then return false end
  if node.name == ".git" or node.name == ".DS_Store" or node.name == "thumbs.db" then return true end
  if S.hidden or node.name == ".gitignore" or (S.target and within(S.target, node.path)) then return false end
  local g = cache()
  if not g then return false end
  if g.ignored[node.path] then return true end
  local dir = node.path
  while within(dir, g.root) do
    if g.ignore_dirs[dir] then return true end
    if dir == g.root then break end
    dir = vim.fs.dirname(dir)
  end
  return false
end

local function new_node(path, kind)
  local node = S.nodes[path]
  if node then
    if kind ~= "link" and node.dir ~= (kind == "directory") then
      forget(node)
      node.dir, node.children, node.loaded, node.expanded = kind == "directory", nil, nil, nil
      S.nodes[path] = node
    end
    return node
  end
  node = { path = path, name = vim.fs.basename(path), dir = kind == "directory" }
  S.nodes[path] = node
  return node
end

local function children(node)
  local result, seen = {}, {}
  for _, child in ipairs(node.children or {}) do
    seen[child.path] = true
    if not hidden(child) then result[#result + 1] = child end
  end
  local g = cache()
  for _, child in ipairs(g and g.deleted[node.path] or {}) do
    if not seen[child.path] and not hidden(child) then result[#result + 1] = child end
  end
  table.sort(result, function(a, b)
    if not not a.dir ~= not not b.dir then return not not a.dir end
    if S.scores and (S.scores[a.path] or math.huge) ~= (S.scores[b.path] or math.huge) then return (S.scores[a.path] or math.huge) < (S.scores[b.path] or math.huge) end
    local order = S.order
    if order == "type" then
      local ae, be = a.name:match("%.([^.]*)$") or "", b.name:match("%.([^.]*)$") or ""
      if ae ~= be then return ae < be end
    elseif order == "git" then
      local g = cache()
      local function letter(n) local s = g and g.files[n.path] return s and (s.work or s.staged) or "~" end
      if letter(a) ~= letter(b) then return letter(a) < letter(b) end
    elseif order == "diagnostics" then
      local function severity(n) local d = diagnostics[n.path] return d and d.errors * 1000 + d.warnings or 0 end
      if severity(a) ~= severity(b) then return severity(a) > severity(b) end
    elseif order == "size" or order == "mtime" or order == "birthtime" then
      local function value(n) local v = n.stat and n.stat[order] return type(v) == "table" and v.sec or v or 0 end
      if value(a) ~= value(b) then return value(a) > value(b) end
    end
    return a.name < b.name
  end)
  return result
end

local function cursor(path)
  local row = S.index[path]
  if not visible() or not row then return end
  api.nvim_win_set_cursor(S.win, { row, 0 })
  api.nvim_win_call(S.win, function() vim.cmd("normal! zv") end)
end

local function apply(rows, lines, index)
  local old, first, tail = S.lines, 1, 0
  while first <= #old and first <= #lines and old[first] == lines[first] do first = first + 1 end
  while tail < math.min(#old, #lines) - first + 1 and old[#old - tail] == lines[#lines - tail] do tail = tail + 1 end
  local at = node_at()
  S.rows, S.lines, S.index = rows, lines, index
  if first <= #old or first <= #lines then
    vim.bo[S.buf].modifiable = true
    api.nvim_buf_set_lines(S.buf, first - 1, #old - tail, false, vim.list_slice(lines, first, #lines - tail))
    vim.bo[S.buf].modifiable = false
  end
  if S.first then
    local first_match = 1
    for i, row in ipairs(rows) do if row.node and not row.header then first_match = i break end end
    api.nvim_win_set_cursor(S.win, { first_match, 0 })
    S.first = nil
  elseif S.select and index[S.select] then cursor(S.select) S.select = nil
  elseif at then cursor(at.path) end
  -- Ephemeral badges need invalidation even when the buffer text is unchanged.
  if S.repaint then api.nvim__redraw({ buf = S.buf, valid = false, flush = true })
  else vim.cmd.redraw() end
  S.repaint = nil
  if S.auto_width and not S.float and not S.inplace then
    local width = S.width
    for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 9) end
    api.nvim_win_set_width(S.win, math.min(width, math.floor(vim.o.columns * 0.6)))
  end
  save_session()
end

local function push(stack, node, prefix)
  local list = children(node)
  if node.notice then stack[#stack + 1] = { notice = node.notice, prefix = prefix } end
  for i = #list, 1, -1 do stack[#stack + 1] = { node = list[i], prefix = prefix, last = i == #list } end
end

local function build(version)
  if not visible() or S.revealing then return end
  local rows, lines, index, stack = {}, {}, {}, {}
  local deadline = uv.hrtime() + BUDGET * 1000000
  local root = S.nodes[S.root]
  local title = " ❯ " .. display(vim.fn.fnamemodify(S.root, ":~")) .. " "
  rows[1], lines[1], index[S.root] = { node = root, header = true }, title, 1
  if S.query then rows[2], lines[2] = {}, " filter: " .. display(S.query) .. " · Esc clears " end
  if root.expanded or S.query then push(stack, root, " ") end
  local function batch()
    if not visible() or version ~= S.version then return end
    local start = uv.hrtime()
    while #stack > 0 and uv.hrtime() - start < 2000000 do
      local item = table.remove(stack)
      local node = item.node
      local match = not S.query or (node and (S.matches and S.matches[node.path] or not S.matches and node.name:lower():find(S.query, 1, true)))
      if match or item.notice then
        local icon, hl = "", "AosDim"
        local open = node and node.dir and (node.expanded or S.matches and S.matches[node.path])
        if node then icon, hl = unpack(node.dir and (open and icons.directory_open or icons.directory) or { icons.get_icon(node.name, nil, { default = true }) }) end
        local guide = item.prefix .. "▏ "
        local lead = guide
        local text = lead .. (node and (icon ~= "" and icon .. " " or "") .. display(node.label or node.name) or "○ " .. display(item.notice))
        rows[#lines + 1] = { node = node, lead = #lead, guide = #guide, icon = #icon, hl = hl }
        lines[#lines + 1] = text
        if node then index[node.path] = #lines end
      end
      if node and node.dir and (node.expanded or (S.query and node.loaded) or (S.matches and S.matches[node.path])) then push(stack, node, item.prefix .. (item.last and "  " or "▏ ")) end
    end
    if #stack > 0 and uv.hrtime() < deadline then return vim.defer_fn(batch, 1) end
    if #stack > 0 then rows[#lines + 1], lines[#lines + 1] = {}, " ○ … cut off · too many loaded rows" end
    local g = cache()
    if S.notice or (g and g.notice) then
      rows[#lines + 1], lines[#lines + 1] = {}, " ○ " .. display(S.notice or g.notice)
    end
    apply(rows, lines, index)
  end
  batch()
end

render = function(repaint)
  S.repaint = S.repaint or repaint
  S.version = (S.version or 0) + 1
  if S.revealing then return end
  local version = S.version
  vim.schedule(function() if version == S.version then build(version) end end)
end

local function badges(node)
  local chunks, g = {}, cache()
  if not node then return chunks end
  if S.selection[node.path] then chunks[#chunks + 1] = { "✓ ", "AosArg" } end
  local clip = S.clipboard[node.path]
  if clip then chunks[#chunks + 1] = { clip.cut and "cut " or "copied ", "AosRunning" } end
  local d = diagnostics[node.path]
  local buf = not node.dir and (node.buf or vim.fn.bufnr(node.path)) or -1
  local dirty = modified[node.path]
  if buf > 0 and api.nvim_buf_is_loaded(buf) then dirty = vim.bo[buf].modified end
  if dirty then chunks[#chunks + 1] = { "● ", "AosArg" } end
  if d and d.errors > 0 then chunks[#chunks + 1] = { "✗" .. d.errors .. " ", "AosFailed" } end
  if d and d.warnings > 0 then chunks[#chunks + 1] = { "!" .. d.warnings .. " ", "AosRunning" } end
  if d and (d.info or 0) > 0 then chunks[#chunks + 1] = { "i" .. d.info .. " ", "AosId" } end
  if d and (d.hints or 0) > 0 then chunks[#chunks + 1] = { "?" .. d.hints .. " ", "AosArg" } end
  local status = g and g.files[node.path]
  if node.dir then
    local letter = g and g.dirs[node.path]
    if letter then chunks[#chunks + 1] = { "· ", "AosTree" .. letter:gsub("!", "Conflict") } end
  end
  if not status then return chunks end
  if status.staged then chunks[#chunks + 1] = { "✓" .. status.staged .. " ", LETTER[status.staged] } end
  if status.work then chunks[#chunks + 1] = { status.work .. " ", LETTER[status.work] } end
  return chunks
end

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win, buf)
    if buf ~= S.buf then return false end
    local info = vim.fn.getwininfo(win)[1]
    S.textwidth = api.nvim_win_get_width(win) - (info and info.textoff or 0)
    return true
  end,
  on_line = function(_, win, _, line)
    local row = S.rows[line + 1]
    if not row then return end
    local function mark(col, opts) opts.ephemeral = true api.nvim_buf_set_extmark(S.buf, ns, line, col, opts) end
    if row.header then return mark(0, { end_col = #S.lines[line + 1], hl_group = "AosArg" }) end
    if not row.node then return mark(0, { end_col = #S.lines[line + 1], hl_group = "AosDim" }) end
    mark(0, { end_col = row.guide, hl_group = "Whitespace" })
    mark(row.guide, { end_col = row.lead, hl_group = "AosDim" })
    mark(row.lead, { end_col = row.lead + row.icon, hl_group = row.hl })
    if row.node.path == S.current then mark(0, { line_hl_group = "PmenuSel" }) end
    local chunks = badges(row.node)
    if #chunks == 0 then return end
    local width = 1
    for _, chunk in ipairs(chunks) do width = width + vim.fn.strdisplaywidth(chunk[1]) end
    table.insert(chunks, 1, { " ", S.float and "NormalFloat" or "Normal" })
    mark(0, { virt_text = chunks, virt_text_win_col = math.max(0, (S.textwidth or api.nvim_win_get_width(win)) - width), virt_text_pos = "overlay" })
  end,
})

local function unwatch(path)
  stop(S.watchers[path])
  S.watchers[path], S.gitpaths[path] = nil, nil
end

local function retire(node)
  if not S.gitpaths[node.path] then unwatch(node.path) end
  if node.cancel then node.cancel() end
end

local function retire_branch(path)
  for childpath, node in pairs(S.nodes) do
    if within(childpath, path) then node.expanded = false retire(node) end
  end
end

forget = function(node)
  local stack = { node }
  while #stack > 0 do
    local current = table.remove(stack)
    for _, child in ipairs(current.children or {}) do stack[#stack + 1] = child end
    retire(current)
    current.expanded = false
    if S.nodes[current.path] == current then S.nodes[current.path] = nil end
  end
end

local function resolve_link(node, epoch)
  uv.fs_stat(node.path, later(function(_, stat)
    if epoch ~= S.epoch or S.nodes[node.path] ~= node then return end
    new_node(node.path, stat and stat.type or "file")
    render()
  end))
end

local function target_child(node)
  if not S.target or not within(S.target, node.path) or S.target == node.path then return end
  local part = S.target:sub(#join(node.path, "") + 1):match("^[^/]+")
  return part and S.nodes[join(node.path, part)]
end

local function prune()
  for _, node in pairs(S.nodes) do
    if not node.expanded or hidden(node) then retire(node) end
  end
end

local function prune_listing(previous, result, node, complete, updated)
  local keep = {}
  for _, child in ipairs(result) do keep[child.path] = true end
  if updated then keep[updated.path] = true end
  for _, child in ipairs(previous) do
    if not keep[child.path] and child ~= target_child(node) then
      if complete then forget(child) elseif child.dir then retire_branch(child.path) end
    end
  end
end

scan = function(node, done)
  if S.source == "buffers" then render() if done then vim.schedule(done) end return end
  if node.loading then
    if done then node.waiters[#node.waiters + 1] = done end
    return
  end
  local previous = node.children or {}
  local updated
  local epoch, result, total, finished, dir, reading = S.epoch, {}, 0, false, nil, false
  local timer = uv.new_timer()
  node.loading, node.waiters = true, done and { done } or {}
  -- libuv owns the directory until an in-flight readdir callback returns.
  local function close_dir() if dir and not reading then uv.fs_closedir(dir, function() end) dir = nil end end
  local function publish()
    local view, seen = {}, {}
    for _, child in ipairs(result) do view[#view + 1], seen[child.path] = child, true end
    local target = target_child(node)
    if target and not seen[target.path] then view[#view + 1], seen[target.path] = target, true end
    if updated and not seen[updated.path] then view[#view + 1] = updated end
    for path in pairs(S.matches or {}) do
      if vim.fs.dirname(path) == node.path and S.nodes[path] and not seen[path] then view[#view + 1], seen[path] = S.nodes[path], true end
    end
    node.children, node.loaded, node.total = view, true, total
    node.notice = total > #view and ("… %d more · listing capped at %d"):format(total - #view, LIMIT) or nil
    render()
  end
  local function finish(err, cancelled)
    if finished then return end
    finished = true
    stop(timer)
    close_dir()
    node.loading, node.cancel = false, nil
    local waiters = node.waiters
    node.waiters = nil
    if epoch ~= S.epoch or cancelled then return end
    if not err then prune_listing(previous, result, node, total <= LIMIT, updated) end
    publish()
    if err then node.notice = err end
    for _, cb in ipairs(waiters) do cb() end
  end
  node.cancel = function() finish(nil, true) end
  timer:start(BUDGET, 0, later(function() finish("… cut off · directory took over 3 s") end))
  local read
  read = function()
    if finished or not dir then return end
    reading = true
    uv.fs_readdir(dir, later(function(err, entries)
      reading = false
      if finished then close_dir() return end
      if err then return finish("… " .. err) end
      if not entries then
        local target = target_child(node)
        if not target then return finish() end
        return uv.fs_stat(target.path, later(function(staterr)
          if finished then return end
          if staterr then forget(target) end
          finish()
        end))
      end
      for _, entry in ipairs(entries) do
        total = total + 1
        if #result < LIMIT then
          local child = new_node(join(node.path, entry.name), entry.type)
          result[#result + 1] = child
          if entry.type == "link" then resolve_link(child, epoch) end
        elseif join(node.path, entry.name) == node.changed then
          updated = new_node(node.changed, entry.type)
          if entry.type == "link" then resolve_link(updated, epoch) end
        end
      end
      if total == #entries then publish() end
      vim.schedule(read)
    end))
  end
  uv.fs_stat(node.path, later(function(_, stat)
    if epoch ~= S.epoch or finished then return end
    if stat and (node.ino ~= stat.ino or node.dev ~= stat.dev) then
      unwatch(node.path)
      node.ino, node.dev = stat.ino, stat.dev
      if node.expanded then watch(node.path, false) end
    end
  end))
  uv.fs_opendir(node.path, later(function(err, handle)
    if finished then if handle then uv.fs_closedir(handle, function() end) end return end
    if err then return finish("… " .. err) end
    dir = handle
    read()
  end), 128)
  if node.expanded then watch(node.path, false) end
end

local function refresh_loaded()
  for _, node in pairs(S.nodes) do
    if node.dir and node.loaded and not node.expanded and not hidden(node) then scan(node) end
  end
end

local function consume(step, done)
  local deadline = uv.hrtime() + BUDGET * 1000000
  local function batch()
    local start = uv.hrtime()
    while uv.hrtime() - start < 2000000 do
      if not step() then return done() end
    end
    if uv.hrtime() > deadline then return done("tree metadata cut off after 3 s") end
    vim.defer_fn(batch, 1)
  end
  batch()
end

local function aggregate(g, entry, staged)
  local path = join(g.root, entry.path)
  local status = g.files[path] or {}
  status[staged and "staged" or "work"] = entry.letter
  g.files[path] = status
  local dir = vim.fs.dirname(path)
  while within(dir, g.root) do
    if g.dirs[dir] and (entry.letter ~= "!" or g.dirs[dir] == "!") then break end
    g.dirs[dir] = entry.letter
    if dir == g.root then break end
    dir = vim.fs.dirname(dir)
  end
  if entry.letter == "D" then
    local parent = vim.fs.dirname(path)
    g.deleted[parent] = g.deleted[parent] or {}
    g.deleted[parent][#g.deleted[parent] + 1] = { path = path, name = vim.fs.basename(path), dir = false, deleted = true }
  end
end

local function status_index(g, status, done)
  local result = { root = g.root, files = {}, dirs = {}, deleted = {} }
  local groups, group, index = { status.staged, status.changes, status.conflicts }, 1, 1
  consume(function()
    while group <= #groups and not groups[group][index] do group, index = group + 1, 1 end
    if group > #groups then return false end
    aggregate(result, groups[group][index], group == 1)
    index = index + 1
    return true
  end, function(err)
    if not err then g.files, g.dirs, g.deleted = result.files, result.dirs, result.deleted end
    done(err)
  end)
end

refresh_git = function()
  local g = cache()
  if not g then return end
  if g.busy then g.again = true return end
  g.busy, g.again = true, false
  local pending = 2
  local function finish()
    pending = pending - 1
    if pending > 0 then return end
    g.busy = false
    if not visible() or cache() ~= g then return end
    g.notice = g.status_notice or g.ignore_notice
    prune()
    render(true)
    if S.query then refresh_loaded() end
    if g.again then debounce("git_timer", GIT_DELAY, refresh_git) end
  end
  repo.status(g.root, function(status, err)
    g.status_notice = nil
    if not status then g.status_notice = "git status cut off/unavailable · " .. (err or "unknown error") end
    if not status then return finish() end
    status_index(g, status, function(indexerr)
      g.status_notice = indexerr
      finish()
    end)
  end)
  repo.run({ "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory" }, g.root, function(ok, out, err)
    g.ignore_notice = nil
    if not ok then g.ignore_notice = "gitignore cut off/unavailable · " .. err finish() return end
    local ignored, dirs, paths = {}, {}, out:gmatch("([^%z]+)%z")
    consume(function()
      local path = paths()
      if not path then return false end
      local target = path:sub(-1) == "/" and dirs or ignored
      target[join(g.root, path:gsub("/$", ""))] = true
      return true
    end, function(parseerr)
      if not parseerr then g.ignored, g.ignore_dirs = ignored, dirs end
      g.ignore_notice = parseerr
      finish()
    end)
  end, { feature = "tree ignore", binary = true })
end

watch = function(path, gitdir)
  if S.watchers[path] or not visible() then return end
  local epoch = S.epoch
  local watcher = uv.new_fs_event()
  local ok = watcher:start(path, {}, function(err, name)
    if err then return end
    if gitdir and name and name:match("%.lock$") then return end
    S.dirty = S.dirty or {}
    if not gitdir then
      S.dirty[path] = true
      local node = S.nodes[path]
      if node and name then node.changed = join(path, name) end
    end
    vim.schedule(function()
      if epoch ~= S.epoch or not visible() then return end
      debounce("git_timer", GIT_DELAY, refresh_git)
      debounce("watch_timer", 150, function()
        local dirty = S.dirty or {}
        S.dirty = {}
        for dir in pairs(dirty) do
          local node = S.nodes[dir]
          if node and node.expanded then scan(node) end
        end
      end)
    end)
  end)
  if ok then S.watchers[path], S.gitpaths[path] = watcher, gitdir
  else stop(watcher) notify("cannot watch " .. path) end
end

locate = function()
  local root, epoch = S.root, S.epoch
  repo.run({ "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" }, root, function(ok, out, _, cut)
    if epoch ~= S.epoch or not visible() then return end
    if not ok then S.notice = cut and "git lookup cut off" or nil render() return end
    local top, dir, common = unpack(vim.split(vim.trim(out), "\n"))
    S.gitroot = top
    git[top] = git[top] or { root = top, files = {}, dirs = {}, deleted = {}, ignored = {}, ignore_dirs = {} }
    watch(dir, true)
    if common ~= dir then watch(common, true) end
    stop(S.git_timer)
    S.git_timer = nil
    refresh_git()
    stop(S.poll_timer)
    S.poll_timer = uv.new_timer()
    S.poll_timer:start(400, 400, later(function()
      if visible() and not S.git_timer and not git[top].busy then refresh_git() end
    end))
  end, { feature = "tree lookup" })
end

function M.refresh(done)
  if not visible() then return end
  if S.source == "buffers" then refresh_buffers() if done then vim.schedule(done) end return end
  local nodes = {}
  for _, node in pairs(S.nodes) do
    if node.dir and node.expanded and not hidden(node) then nodes[#nodes + 1] = node end
  end
  local pending = #nodes
  if pending == 0 and done then vim.schedule(done) end
  for _, node in ipairs(nodes) do
    scan(node, function()
      pending = pending - 1
      if pending == 0 and done then vim.schedule(done) end
    end)
  end
  debounce("git_timer", GIT_DELAY, refresh_git)
end

local function collapse(node)
  if not node then return end
  S.reveal, S.select, S.revealing = (S.reveal or 0) + 1, nil, nil
  retire_branch(node.path)
  render()
end

local function include(parent, child)
  parent.children = parent.children or {}
  for _, node in ipairs(parent.children) do if node.path == child.path then return end end
  parent.children[#parent.children + 1] = child
  local omitted = (parent.total or 0) - #parent.children
  parent.notice = omitted > 0 and ("… %d more · listing capped at %d"):format(omitted, LIMIT) or nil
end

function M.reveal(path, done)
  if not visible() or not within(path, S.root) or path == S.root then return end
  if S.source == "buffers" then
    local node = S.nodes[path]
    if not node then return end
    local dir = vim.fs.dirname(path)
    while S.nodes[dir] do
      S.nodes[dir].expanded = true
      if dir == S.root then break end
      dir = vim.fs.dirname(dir)
    end
    S.select = path
    render()
    if done then done(node) end
    return
  end
  S.target, S.reveal = path, (S.reveal or 0) + 1
  local serial, epoch = S.reveal, S.epoch
  S.revealing = serial
  stop(S.reveal_timer)
  local function valid() return epoch == S.epoch and serial == S.reveal and S.revealing == serial and visible() end
  local function finish(node, expired)
    if not valid() then return end
    stop(S.reveal_timer)
    S.reveal_timer, S.revealing = nil, nil
    if expired then S.reveal = S.reveal + 1 end
    if node then S.select = path end
    render()
    if done then done(node) end
  end
  S.reveal_timer = uv.new_timer()
  S.reveal_timer:start(BUDGET, 0, later(function()
    if not valid() then return end
    S.notice = "… cut off · reveal took over 3 s"
    finish(nil, true)
  end))
  uv.fs_stat(path, later(function(err, stat)
    if not valid() then return end
    local g = cache()
    local status = g and g.files[path]
    local deleted = status and (status.work == "D" or status.staged == "D")
    if err and deleted then err, stat = nil, { type = "file" } end
    if err then
      local stale = S.nodes[path]
      if stale then forget(stale) end
      return finish()
    end
    local parts = vim.split(path:sub(#join(S.root, "") + 1), "/", { plain = true })
    local node, at = S.nodes[S.root], 1
    local function advance()
      if not valid() then return end
      local start = uv.hrtime()
      while at <= #parts and uv.hrtime() - start < 2000000 do
        local expanded = node.expanded
        node.expanded = true
        watch(node.path, false)
        if not node.loaded or not expanded then scan(node) end
        local child = new_node(join(node.path, parts[at]), at == #parts and stat.type or "directory")
        if at == #parts and deleted then child.deleted = true end
        include(node, child)
        node, at = child, at + 1
      end
      if at <= #parts then return vim.defer_fn(advance, 1) end
      finish(node)
    end
    advance()
  end))
end

local function destination()
  if S.origin and api.nvim_win_is_valid(S.origin) and S.origin ~= S.win then return S.origin end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if win ~= S.win and api.nvim_win_get_config(win).relative == "" then return win end
  end
  local tree = S.win
  api.nvim_set_current_win(tree)
  vim.cmd("rightbelow vnew")
  S.origin = api.nvim_get_current_win()
  return S.origin
end

local function open_file(mode, picked)
  local node = node_at()
  if not node then return end
  if node.dir then
    if node.expanded then collapse(node) else node.expanded = true scan(node) render() end
    return
  end
  if node.deleted then return notify("file was deleted") end
  local tree = S.win
  if close_preview then close_preview() end
  if S.float and mode == "t" then
    M.close()
    local ok, err = pcall(function()
      if node.buf and api.nvim_buf_is_valid(node.buf) then vim.cmd.tabnew() api.nvim_set_current_buf(node.buf)
      else vim.cmd.tabedit(vim.fn.fnameescape(node.path)) end
    end)
    if not ok then notify(err) end
    return
  end
  local win = picked or ((mode == "t" or S.inplace and not mode) and tree or destination())
  api.nvim_set_current_win(win)
  local cmd = ({ s = "vsplit", S = "split", t = "tabedit" })[mode] or "edit"
  local function edit()
    if node.buf and api.nvim_buf_is_valid(node.buf) then
      if mode then vim.cmd(({ s = "vsplit", S = "split", t = "tabnew" })[mode]) end
      api.nvim_set_current_buf(node.buf)
    else vim.cmd(cmd .. " " .. vim.fn.fnameescape(node.path)) end
  end
  local ok, err = pcall(edit)
  if not ok then notify(err) end
  if S.float then M.close() end
end

local function parent()
  local node = node_at()
  if not node then return end
  if node.expanded and node.path ~= S.root then collapse(node) return end
  S.select = vim.fs.dirname(node.path)
  render()
end

local function base_dir()
  local node = node_at()
  return node and (node.dir and node.path or vim.fs.dirname(node.path)) or S.root
end

local function input(title, default, cb, ask)
  (ask or vim.ui.input)({ prompt = title .. ": ", default = default or "" }, function(value)
    if value and value ~= "" then cb(value) end
  end)
end

local function valid_path(value, base)
  if value:find("[%z\r\n]") then notify("invalid path") return end
  return vim.fs.normalize(value:sub(1, 1) == "/" and value or join(base, value))
end

local function mkdir(path, cb)
  uv.fs_mkdir(path, 493, later(function(err)
    if not err then return cb() end
    if err:find("EEXIST", 1, true) then
      return uv.fs_stat(path, later(function(staterr, stat)
        cb(staterr or (stat and stat.type ~= "directory" and ("not a directory: " .. path) or nil))
      end))
    end
    if not err:find("ENOENT", 1, true) then return cb(err) end
    mkdir(vim.fs.dirname(path), function(parenterr)
      if parenterr then return cb(parenterr) end
      uv.fs_mkdir(path, 493, later(cb))
    end)
  end))
end

local function changed(err, path, serial)
  if err then return notify(err) end
  M.refresh()
  if path and (not serial or serial == S.reveal) then M.reveal(path) end
end

local function add(directory)
  local base, generation = base_dir(), S.epoch
  input("add (trailing / for directory)", "", function(value)
    local path = valid_path(value, base)
    if not path then return end
    if not buffer_destination(nil, path) then return end
    mkdir((directory or value:sub(-1) == "/") and path or vim.fs.dirname(path), function(err)
      if err or directory or value:sub(-1) == "/" then return changed(err, path) end
      if not buffer_destination(nil, path) then return end
      uv.fs_open(path, "wx", 420, later(function(openerr, fd)
        if not fd then return changed(openerr, path) end
        uv.fs_fstat(fd, later(function(staterr, identity)
          uv.fs_close(fd, function() end)
          if staterr then return notify(staterr) end
          if not buffer_destination(nil, path) then
            if identity.size ~= 0 then return end
            return pin_source(path, identity, function(stored, cleanup, rollback)
              uv.fs_unlink(stored, later(function(unlinkerr)
                if unlinkerr then rollback(unlinkerr) else cleanup() end
              end))
            end)
          end
          changed(nil, path)
          if generation ~= S.epoch then return end
          local win = S.inplace and S.win or destination()
          if S.float then M.close() end
          if win and api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
            vim.cmd.edit(vim.fn.fnameescape(path))
          end
        end))
      end))
    end)
  end)
end

local function buffers_under(path)
  local buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if within(api.nvim_buf_get_name(buf), path) then buffers[#buffers + 1] = buf end
  end
  return buffers
end

local function move_buffers(from, to)
  for _, buf in ipairs(buffers_under(from)) do
    local name = to .. api.nvim_buf_get_name(buf):sub(#from + 1)
    local old = api.nvim_buf_get_name(buf)
    local ok, err = pcall(api.nvim_buf_set_name, buf, name)
    if not ok then notify("buffer rename failed: " .. err)
    else
      modified[old], modified[name] = nil, vim.bo[buf].modified or nil
      diagnostics[old], diagnostics[name] = nil, diagnostics[old]
      if S.current == old then S.current = name end
    end
  end
  -- :file leaves unloaded aliases for the old names; these must not become ghost files.
  for _, buf in ipairs(buffers_under(from)) do
    if not api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then api.nvim_buf_delete(buf, { force = false }) end
  end
end

local function unused(path, cb)
  uv.fs_lstat(path, later(function(err, stat)
    if stat then return notify("destination exists: " .. path) end
    if err and not err:find("ENOENT", 1, true) then return notify(err) end
    cb()
  end))
end

buffer_destination = function(from, to)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    local intersects = name ~= "" and (within(name, to) or within(to, name))
    if intersects and (not from or not within(name, from)) then
      if api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified then
        notify("destination buffer already exists: " .. api.nvim_buf_get_name(buf))
        return false
      end
      api.nvim_buf_delete(buf, { force = false })
    end
  end
  return true
end

local function rename_noreplace(from, to, cb)
  local work
  work = uv.new_work(function(source, destination)
    local ok, err = pcall(function()
      local ffi = require("ffi")
      ffi.cdef("int renameat2(int, const char*, int, const char*, unsigned int); char *strerror(int);")
      local AT_FDCWD, RENAME_NOREPLACE = -100, 1
      local result = ffi.C.renameat2(AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE)
      return result == 0 and "" or ffi.string(ffi.C.strerror(ffi.errno()))
    end)
    return ok and err or ("atomic no-replace rename unavailable: " .. tostring(err))
  end, later(function(err)
    work = nil
    cb(err ~= "" and err or nil)
  end))
  local ok, err = work:queue(from, to)
  if not ok then work = nil return cb(err or "could not queue atomic rename") end
  vim.defer_fn(function() if work then notify("rename still running…") end end, BUDGET)
end

local function same_identity(a, b, renamed)
  if not a or not b then return false end
  for _, field in ipairs({ "dev", "ino", "size", "mode" }) do if a[field] ~= b[field] then return false end end
  for _, field in ipairs(renamed and { "mtime" } or { "mtime", "ctime" }) do if not vim.deep_equal(a[field], b[field]) then return false end end
  return true
end

pin_source = function(path, identity, use)
  uv.fs_lstat(path, later(function(err, stat)
    if err then return notify(err) end
    if identity and not same_identity(identity, stat) then return notify("source changed: " .. path) end
    uv.fs_mkdtemp(join(vim.fs.dirname(path), ".nvim-tree-XXXXXX"), later(function(temperr, dir)
      if temperr then return notify(temperr) end
      local stored = join(dir, "item")
      local function cleanup() uv.fs_rmdir(dir, function() end) end
      local function rollback(reason)
        rename_noreplace(stored, path, function(restoreerr)
          if restoreerr then notify((reason or restoreerr) .. " · recover " .. stored)
          else cleanup() if reason then notify(reason) end end
          M.refresh()
        end)
      end
      rename_noreplace(path, stored, function(moveerr)
        if moveerr then cleanup() return notify(moveerr) end
        uv.fs_lstat(stored, later(function(staterr, pinned)
          if staterr or not same_identity(stat, pinned, true) then return rollback("source changed: " .. path) end
          use(stored, cleanup, rollback)
        end))
      end)
    end))
  end))
end

local function move(from, to, done, identity)
  local serial = S.reveal
  if within(to, from) then return notify("destination must be outside the source") end
  if not buffer_destination(from, to) then return end
  unused(to, function()
    mkdir(vim.fs.dirname(to), function(err)
      if err then return notify(err) end
      if not buffer_destination(from, to) then return end
      pin_source(from, identity, function(stored, cleanup, rollback)
        if not buffer_destination(from, to) then return rollback() end
        rename_noreplace(stored, to, function(renameerr)
          if renameerr then return rollback(renameerr) end
          if not buffer_destination(from, to) then
            return rename_noreplace(to, stored, function(backerr)
              if backerr then return notify("move interrupted · recover " .. to) end
              rollback()
            end)
          end
          cleanup()
          move_buffers(from, to)
          S.clipboard[from], S.selection[from] = nil, nil
          for _, data in pairs(tabs) do data.clipboard[from], data.selection[from] = nil, nil end
          changed(nil, to, serial)
          if done then done() end
        end)
      end)
    end)
  end)
end

local function rename(basename)
  local node = node_at()
  if not node or node.path == S.root then return end
  local stem, ext = node.name:match("^(.*)(%.[^.]*)$")
  if not stem or stem == "" or node.dir then stem, ext = node.name, "" end
  local ask = vim.ui.input
  uv.fs_lstat(node.path, later(function(err, identity)
    if err then return notify(err) end
    input(basename and "rename basename" or "rename", basename and stem or node.name, function(value)
      if basename then value = value .. ext end
      local path = valid_path(value, vim.fs.dirname(node.path))
      if path and path ~= node.path then move(node.path, path, nil, identity) end
    end, ask)
  end))
end

local function command(args, cb)
  local finished = false
  vim.defer_fn(function() if not finished then notify("operation still running…") end end, BUDGET)
  vim.system(args, { text = true }, function(result)
    finished = true
    vim.schedule(function()
      if result.code == 0 then cb() else cb(result.stderr ~= "" and result.stderr or "operation failed") end
    end)
  end)
end

local function targets()
  local paths, result = {}, {}
  for path in pairs(S.selection) do
    if S.nodes[path] and within(path, S.root) and path ~= S.root then paths[#paths + 1] = path end
  end
  table.sort(paths)
  if #paths == 0 then local n = node_at() if n and n.path ~= S.root then return { n } end return {} end
  local parent
  for _, path in ipairs(paths) do
    if not parent or not within(path, parent) then result[#result + 1], parent = S.nodes[path], path end
  end
  return result
end

local function mark_selection(action)
  if action == "clear" then S.selection = {} render(true) return end
  if action == "invert" then
    for _, row in ipairs(S.rows) do
      if row.node and not row.header then S.selection[row.node.path] = not S.selection[row.node.path] or nil end
    end
  else
    local node = node_at()
    if node and node.path ~= S.root then S.selection[node.path] = not S.selection[node.path] or nil end
  end
  render(true)
end

local function wipe_buffer(buf)
  if vim.bo[buf].modified then return notify("deleted file has modified buffer: " .. api.nvim_buf_get_name(buf)) end
  local ok, err = pcall(api.nvim_buf_delete, buf, { force = false })
  if not ok then notify(err) end
end

local function delete_buffers(items)
  for _, node in ipairs(items) do
    if S.preview_path and within(S.preview_path, node.path) then close_preview() end
    for _, buf in ipairs(buffers_under(node.path)) do wipe_buffer(buf) end
    S.selection[node.path], S.clipboard[node.path] = nil, nil
    for _, data in pairs(tabs) do data.clipboard[node.path], data.selection[node.path] = nil, nil end
  end
end

local function safe_delete(items)
  for _, node in ipairs(items) do
    for _, buf in ipairs(buffers_under(node.path)) do
      if vim.bo[buf].modified then notify("save or close modified buffer before deleting: " .. api.nvim_buf_get_name(buf)) return false end
    end
  end
  return true
end

local function trash_index(base, scope, mount, done)
  local deadline = uv.hrtime() + BUDGET * 1000000
  local records, files, at = {}, {}, 1
  uv.fs_opendir(join(base, "info"), later(function(err, dir)
    if err then return done(records) end
    local read
    local function infos()
      if uv.hrtime() > deadline or not files[at] then return done(records) end
      local name = files[at]
      at = at + 1
      local info = join(join(base, "info"), name)
      uv.fs_open(info, "r", 0, later(function(openerr, fd)
        if openerr then return infos() end
        uv.fs_read(fd, 16384, 0, later(function(_, text)
          uv.fs_close(fd, function() end)
          local path = text and text:match("\nPath=([^\n]+)")
          path = path and vim.uri_decode(path)
          if path and path:find("[%z\r\n]") then path = nil end
          if path and path:sub(1, 1) ~= "/" and mount then path = join(mount, path) end
          path = path and vim.fs.normalize(path)
          if path and path:sub(1, 1) == "/" and within(path, scope) then
            records[#records + 1] = { path = path, stored = join(join(base, "files"), name:sub(1, -11)), info = info,
              date = text:match("\nDeletionDate=([^\n]+)") or "", data = text, mount = mount }
          end
          infos()
        end))
      end))
    end
    read = function()
      uv.fs_readdir(dir, later(function(readerr, entries)
        for _, entry in ipairs(entries or {}) do
          if entry.name:sub(-10) == ".trashinfo" then files[#files + 1] = entry.name end
        end
        if not readerr and entries and #files < 10000 and uv.hrtime() < deadline then return read() end
        uv.fs_closedir(dir, function() end)
        infos()
      end))
    end
    read()
  end), 128)
end

local function trash_records(done, scope)
  scope = scope or S.root
  local home_trash = join(vim.env.XDG_DATA_HOME or join(vim.env.HOME, ".local/share"), "Trash")
  local records, pending = {}, 1
  local function receive(items)
    for _, item in ipairs(items) do records[#records + 1] = item end
    pending = pending - 1
    if pending == 0 then done(records) end
  end
  local function at_mount(mount)
    local uid = tostring(uv.os_get_passwd().uid)
    pending = 3
    trash_index(home_trash, scope, nil, receive)
    trash_index(join(mount, ".Trash/" .. uid), scope, mount, receive)
    trash_index(join(mount, ".Trash-" .. uid), scope, mount, receive)
  end
  local function ascend(path, child, device)
    uv.fs_stat(path, later(function(_, stat)
      if child and stat and device ~= stat.dev then return at_mount(child) end
      local parent = vim.fs.dirname(path)
      if path == parent then return at_mount(path) end
      ascend(parent, stat and path or child, stat and stat.dev or device)
    end))
  end
  ascend(scope)
end

local function trash_metadata(stored, original, done)
  trash_records(function(records)
    local record
    for _, item in ipairs(records) do if item.path == stored then record = item break end end
    if not record then return done("trash metadata unavailable · original path " .. original) end
    local trash_path = record.mount and original:sub(#join(record.mount, "") + 1) or original
    local escaped = trash_path:gsub("([^%w/._~%-])", function(c) return string.format("%%%02X", c:byte()) end)
    local text = record.data:gsub("(\nPath=)[^\n]+", function(prefix) return prefix .. escaped end, 1)
    uv.fs_open(record.info, "w", 420, later(function(err, fd)
      if err then return done(err) end
      uv.fs_write(fd, text, 0, later(function(writeerr)
        uv.fs_close(fd, function() end)
        done(writeerr)
      end))
    end))
  end, vim.fs.dirname(original))
end

local function delete_item(node, trash, batch)
  pin_source(node.path, node.identity, function(stored, cleanup, rollback)
    if not safe_delete({ node }) then return rollback() end
    command(trash and { "gio", "trash", "--", stored } or { "rm", "-rf", "--", stored }, function(err)
      if err then return rollback(err) end
      local function finish(metaerr)
        if metaerr then notify(metaerr) else cleanup() end
        delete_buffers({ node })
        if trash then
          batch.wait.count = math.max(0, batch.wait.count - 1)
          batch.paths[node.path] = true
          if not batch.saved then batch.saved = true batch.history[#batch.history + 1] = batch end
        end
        changed()
      end
      if trash then trash_metadata(stored, node.path, finish) else finish() end
    end)
  end)
end

local function delete(trash)
  local items, chooser, root = targets(), vim.ui.select, S.root
  if #items == 0 or not safe_delete(items) then return end
  if trash and vim.fn.executable("gio") ~= 1 then return notify("gio is required to trash files") end
  if trash then
    S.trash_wait = S.trash_wait or { count = 0 }
    S.trash_wait.count, S.trash_wait.deadline = S.trash_wait.count + #items, uv.hrtime() + BUDGET * 1000000
  end
  local history, wait = S.trash, S.trash_wait
  local pending, failed = #items, false
  local function remove()
    if failed or not safe_delete(items) then return end
    local batch = { root = root, paths = {}, history = history, wait = wait }
    for _, node in ipairs(items) do delete_item(node, trash, batch) end
  end
  local function ready()
    pending = pending - 1
    if pending > 0 or failed then return end
    if trash then return remove() end
    chooser({ "cancel", "delete permanently" }, { prompt = "delete " .. #items .. " item(s) permanently?" }, function(choice)
      if choice == "delete permanently" then remove() end
    end)
  end
  for _, node in ipairs(items) do
    uv.fs_lstat(node.path, later(function(err, stat)
      if err then failed = true notify(err) else node.identity = stat end
      ready()
    end))
  end
end

local function restore_record(record)
  unused(record.path, function()
    mkdir(vim.fs.dirname(record.path), function(err)
      if err then return notify(err) end
      rename_noreplace(record.stored, record.path, function(moveerr)
        if moveerr then return notify(moveerr) end
        uv.fs_unlink(record.info, later(function(unlinkerr) changed(unlinkerr, record.path) end))
      end)
    end)
  end)
end

local function restore_trash(undo, chooser, context)
  chooser = chooser or vim.ui.select
  context = context or { root = S.root, history = S.trash, wait = S.trash_wait }
  if context.wait and context.wait.count > 0 and uv.hrtime() < context.wait.deadline then return vim.defer_fn(function() restore_trash(undo, chooser, context) end, 20) end
  trash_records(function(records)
    table.sort(records, function(a, b) return a.date > b.date end)
    if undo then
      local batch = context.history[#context.history]
      if not batch then return notify("nothing to undo") end
      for _, record in ipairs(records) do
        if batch.paths[record.path] then restore_record(record) batch.paths[record.path] = nil end
      end
      if not next(batch.paths) then table.remove(context.history) end
      return
    end
    if #records == 0 then return notify("no restorable items under this root") end
    chooser(records, { prompt = "restore from trash", format_item = function(r) return r.path .. " · " .. r.date end }, function(record)
      if record then restore_record(record) end
    end)
  end, context.root)
end

local function clipboard(cut)
  for _, node in ipairs(targets()) do
    local previous = S.clipboard[node.path]
    local entry = not (previous and previous.cut == cut) and { path = node.path, cut = cut } or nil
    S.clipboard[node.path] = entry
    if entry then
      uv.fs_lstat(node.path, later(function(err, stat)
        if err then return notify(err) end
        entry.identity = stat
      end))
    end
  end
  render(true)
end

local function copy_path(from, to, identity)
  local serial = S.reveal
  if within(to, from) then return notify("destination must be outside the source") end
  if not buffer_destination(from, to) then return end
  local function copy()
    uv.fs_mkdtemp(join(vim.fs.dirname(to), ".nvim-tree-XXXXXX"), later(function(err, dir)
      if err then return notify(err) end
      local stored = join(dir, "item")
      local function cleanup() command({ "rm", "-rf", "--", dir }, function(cleanerr) if cleanerr then notify(cleanerr) end end) end
      command({ "cp", "-R", "-P", "-T", "--", from, stored }, function(copyerr)
        if copyerr then cleanup() return notify(copyerr) end
        if not buffer_destination(from, to) then return cleanup() end
        rename_noreplace(stored, to, function(renameerr)
          if renameerr then cleanup() return notify(renameerr) end
          if not buffer_destination(from, to) then
            return rename_noreplace(to, stored, function(backerr)
              if backerr then return notify("copy interrupted · recover " .. to) end
              cleanup()
            end)
          end
          cleanup()
          changed(nil, to, serial)
        end)
      end)
    end))
  end
  unused(to, function()
    mkdir(vim.fs.dirname(to), function(err)
      if err then return notify(err) end
      if not buffer_destination(from, to) then return end
      uv.fs_lstat(from, later(function(staterr, stat)
        if staterr then return notify(staterr) end
        if identity and not same_identity(identity, stat) then return notify("source changed: " .. from) end
        copy()
      end))
    end)
  end)
end

local function paste()
  local base, entries = base_dir(), S.clipboard
  S.clipboard = {}
  for _, clip in pairs(entries) do
    local target = join(base, vim.fs.basename(clip.path))
    if clip.cut then move(clip.path, target, nil, clip.identity) else copy_path(clip.path, target, clip.identity) end
  end
  render(true)
end

local function transfer(cut)
  local items = targets()
  if #items == 0 then return end
  local base = vim.fs.dirname(items[1].path)
  input(cut and "move to" or "copy to", #items == 1 and items[1].name or "", function(value)
    local to = valid_path(value, base)
    if not to then return end
    uv.fs_stat(to, later(function(_, stat)
      local directory = #items > 1 or value:sub(-1) == "/" or stat and stat.type == "directory"
      for _, node in ipairs(items) do
        local target = directory and join(to, node.name) or to
        if cut then move(node.path, target) else copy_path(node.path, target) end
      end
    end))
  end)
end

local function yank(absolute)
  local node = node_at()
  if not node then return end
  local path = absolute and node.path or (node.path == S.root and "." or node.path:sub(#join(S.root, "") + 1))
  vim.fn.setreg('"', path)
end

local function popup(buf, title, width, height, focus)
  width, height = math.max(1, math.min(width, vim.o.columns - 4)), math.max(1, math.min(height, vim.o.lines - 5))
  local win = api.nvim_open_win(buf, focus == true, { relative = "editor", title = " ❯ " .. title .. " ",
    width = width, height = height, row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)) })
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, "no", "0", ""
  wo.wrap, wo.winbar = false, ""
  wo.winhighlight = "Normal:NormalFloat,CursorLine:PmenuSel"
  return win
end

local function restore_preview_maps(buf, mappings)
  if not api.nvim_buf_is_valid(buf) then return end
  for key, old in pairs(mappings) do
    pcall(vim.keymap.del, "n", key, { buffer = buf })
    if old.lhs then
      vim.keymap.set("n", key, old.callback or old.rhs, { buffer = buf, expr = old.expr == 1,
        remap = old.noremap == 0, nowait = old.nowait == 1, silent = old.silent == 1, desc = old.desc })
    end
  end
end

local function buffer_mapping(buf, key)
  for _, mapping in ipairs(api.nvim_buf_get_keymap(buf, "n")) do if mapping.lhs == key then return mapping end end
  return {}
end

close_preview = function()
  S.preview_serial = (S.preview_serial or 0) + 1
  local win = S.preview_win
  S.preview_win, S.preview_path, S.preview_on = nil, nil, nil
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  for buf, mappings in pairs(S.preview_maps or {}) do restore_preview_maps(buf, mappings) end
  S.preview_maps = nil
end

preview = function()
  local node = node_at()
  if not S.preview_on or not node or node.dir or node.deleted or node.path == S.preview_path then return end
  local serial, epoch = (S.preview_serial or 0) + 1, S.epoch
  S.preview_serial, S.preview_path = serial, node.path
  local function show(buf)
    if serial ~= S.preview_serial or epoch ~= S.epoch or not visible() or not api.nvim_buf_is_valid(buf) then return end
    if not S.preview_win or not api.nvim_win_is_valid(S.preview_win) then
      S.preview_win = popup(buf, "preview · " .. display(node.name), math.min(100, math.floor(vim.o.columns * 0.55)), math.floor(vim.o.lines * 0.65), false)
    else
      api.nvim_win_set_buf(S.preview_win, buf)
      api.nvim_win_set_config(S.preview_win, { title = " ❯ preview · " .. display(node.name) .. " " })
    end
    S.preview_maps = S.preview_maps or {}
    local saved = S.preview_maps[buf]
    S.preview_maps[buf] = saved or {}
    for _, key in ipairs({ "<Esc>", "q" }) do
      if not saved then
        S.preview_maps[buf][key] = buffer_mapping(buf, key)
      end
      vim.keymap.set("n", key, function()
        if api.nvim_get_current_win() ~= S.preview_win then return vim.cmd.normal({ key == "q" and "q" or "\27", bang = true }) end
        close_preview()
        if visible() then api.nvim_set_current_win(S.win) end
      end, { buffer = buf, nowait = true })
    end
  end
  local buf = vim.fn.bufnr(node.path)
  if buf > 0 and api.nvim_buf_is_loaded(buf) then return show(buf) end
  uv.fs_open(node.path, "r", 0, later(function(err, fd)
    if err then S.preview_path = nil return notify(err) end
    uv.fs_read(fd, 262144, 0, later(function(readerr, data)
      uv.fs_close(fd, function() end)
      if readerr then return notify(readerr) end
      if serial ~= S.preview_serial or epoch ~= S.epoch or not visible() then return end
      local scratch = #data == 262144 or data:find("%z")
      if data:find("%z") then data = "○ binary file · open to view" end
      local existing = vim.fn.bufnr(node.path)
      buf = scratch and api.nvim_create_buf(false, true) or existing > 0 and existing or vim.fn.bufadd(node.path)
      if scratch then
        api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(data:gsub("\n$", ""), "\n", { plain = true }))
        vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].buflisted = "nofile", "wipe", false
      elseif not api.nvim_buf_is_loaded(buf) then
        -- bufload decodes 'fileencodings'; filling the file's own buffer with raw bytes corrupted non-UTF-8 files on save.
        vim.fn.bufload(buf)
      end
      show(buf)
    end))
  end))
end

local function scroll_preview(delta)
  local win = S.preview_win
  if not win or not api.nvim_win_is_valid(win) then return end
  api.nvim_win_call(win, function() vim.cmd("normal! " .. math.abs(delta) .. (delta > 0 and "\5" or "\25")) end)
end

local function details()
  local node, epoch = node_at(), S.epoch
  if not node then return end
  uv.fs_lstat(node.path, later(function(err, stat)
    if epoch ~= S.epoch or not visible() then return end
    if err then return notify(err) end
    local function date(t) return t and os.date("%Y-%m-%d %H:%M:%S", t.sec) or "unknown" end
    local lines = { display(node.path), "type: " .. stat.type, "size: " .. stat.size .. " bytes",
      "created: " .. date(stat.birthtime), "modified: " .. date(stat.mtime), "permissions: " .. string.format("%03o", stat.mode % 512) }
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    local win = popup(buf, "file details", math.max(60, vim.fn.strdisplaywidth(lines[1])), #lines, true)
    for _, key in ipairs({ "q", "<Esc>" }) do vim.keymap.set("n", key, function() if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end end, { buffer = buf }) end
  end))
end

local function choose_label(items, title, draw, choose)
  local alphabet, labels, floats = "jfkdlsahgnuvrbytmiceoxwpqz", {}, {}
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.b[buf].completion = "wipe", false
  local prompt = popup(buf, title, 34, 1, true)
  local function close()
    for _, w in ipairs(floats) do if api.nvim_win_is_valid(w) then api.nvim_win_close(w, true) end end
    if api.nvim_win_is_valid(prompt) then api.nvim_win_close(prompt, true) end
    if visible() then api.nvim_buf_clear_namespace(S.buf, ns, 0, -1) end
  end
  local function pick(item) close() if visible() then api.nvim_set_current_win(S.win) choose(item) end end
  for i, item in ipairs(items) do
    local label = #items <= #alphabet and alphabet:sub(i, i) or alphabet:sub(math.floor((i - 1) / #alphabet) + 1, math.floor((i - 1) / #alphabet) + 1) .. alphabet:sub((i - 1) % #alphabet + 1, (i - 1) % #alphabet + 1)
    labels[#labels + 1] = label
    draw(item, label, floats)
    vim.keymap.set("n", label, function() pick(item) end, { buffer = buf, nowait = false })
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { "type a label · Esc cancels" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = close })
end

local function window_picker()
  local items = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if win ~= S.win and api.nvim_win_get_config(win).relative == "" and vim.bo[buf].buftype == "" then items[#items + 1] = win end
  end
  if #items == 0 then return open_file() end
  choose_label(items, "open in window", function(win, label, floats)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { " " .. label .. " " })
    vim.bo[buf].bufhidden = "wipe"
    floats[#floats + 1] = api.nvim_open_win(buf, false, { relative = "win", win = win, width = #label + 2, height = 1,
      row = 0, col = math.max(0, math.floor(api.nvim_win_get_width(win) / 2)), focusable = false })
  end, function(win) open_file(nil, win) end)
end

local function quick_jump()
  local items = {}
  local range = api.nvim_win_call(S.win, function() return { vim.fn.line("w0"), vim.fn.line("w$") } end)
  for i = range[1], range[2] do if S.rows[i] and S.rows[i].node and not S.rows[i].header then items[#items + 1] = i end end
  choose_label(items, "jump", function(row, label)
    api.nvim_buf_set_extmark(S.buf, ns, row - 1, S.rows[row].lead, { virt_text = { { label, "AosArg" } }, virt_text_pos = "overlay", priority = 300 })
  end, function(row) api.nvim_win_set_cursor(S.win, { row, 0 }) open_file() end)
end

local function buffer_node(root, expanded, buf)
  local path = api.nvim_buf_get_name(buf)
  if not vim.bo[buf].buflisted then return end
  if path == "" or vim.bo[buf].buftype == "terminal" then
    local name = vim.bo[buf].buftype == "terminal" and ("terminal #" .. buf) or ("[No Name] #" .. buf)
    local node = new_node(join(S.root, name), "file")
    node.buf, node.virtual = buf, true
    include(root, node)
    return
  end
  if not within(path, S.root) or vim.bo[buf].buftype ~= "" then return end
  local parent, dir = root, S.root
  local parts = vim.split(path:sub(#join(S.root, "") + 1), "/", { plain = true })
  for i, part in ipairs(parts) do
    dir = join(dir, part)
    local child = new_node(dir, i < #parts and "directory" or "file")
    include(parent, child)
    child.loaded, child.expanded = true, expanded[dir] ~= false
    if i == #parts then child.buf = buf else child.children = child.children or {} end
    parent = child
  end
end

refresh_buffers = function()
  if S.source ~= "buffers" or not visible() then return end
  local expanded = {}
  for path, node in pairs(S.nodes) do expanded[path] = node.expanded end
  S.nodes = {}
  local root = new_node(S.root, "directory")
  root.expanded, root.loaded, root.children = true, true, {}
  for _, buf in ipairs(api.nvim_list_bufs()) do buffer_node(root, expanded, buf) end
  local function group(node)
    for i, child in ipairs(node.children or {}) do
      while child.dir and #child.children == 1 and child.children[1].dir do
        local next_node = child.children[1]
        next_node.label = (child.label or child.name) .. "/" .. next_node.name
        child = next_node
      end
      node.children[i] = child
      group(child)
    end
  end
  group(root)
  render(true)
end

local function buffer_delete()
  for _, node in ipairs(targets()) do
    local buffers = node.buf and { node.buf } or buffers_under(node.path)
    for _, buf in ipairs(buffers) do
      local ok, err = pcall(api.nvim_buf_delete, buf, { force = false })
      if not ok then notify(err) end
    end
  end
  refresh_buffers()
end

local function order_by(order)
  S.order = order
  if order ~= "size" and order ~= "mtime" and order ~= "birthtime" then return render() end
  local items, epoch, at, deadline = {}, S.epoch, 0, uv.hrtime() + BUDGET * 1000000
  for _, node in pairs(S.nodes) do items[#items + 1] = node end
  local function next_stat()
    at = at + 1
    if epoch ~= S.epoch or not items[at] then return render() end
    if uv.hrtime() > deadline then S.notice = "order paused · metadata took over 3 s" return render() end
    local node = items[at]
    uv.fs_stat(node.path, later(function(_, stat) node.stat = stat next_stat() end))
  end
  next_stat()
end

local function git_jump(direction)
  local g, items = cache(), {}
  for path in pairs(g and g.files or {}) do if within(path, S.root) then items[#items + 1] = path end end
  table.sort(items)
  if #items == 0 then return end
  local current, target = node_at(), direction > 0 and items[1] or items[#items]
  if direction > 0 then
    for _, path in ipairs(items) do if not current or path > current.path then target = path break end end
  else
    for i = #items, 1, -1 do if not current or items[i] < current.path then target = items[i] break end end
  end
  M.reveal(target)
end

clear_filter = function()
  S.search_serial = (S.search_serial or 0) + 1
  if S.search then S.search:kill(15) S.search = nil end
  stop(S.filter_timer)
  local extras = S.filter_nodes
  for path in pairs(extras or {}) do
    local parent = S.nodes[vim.fs.dirname(path)]
    if parent then parent.children = vim.tbl_filter(function(n) return n.path ~= path end, parent.children or {}) end
    S.nodes[path] = nil
  end
  S.filter_nodes, S.scores = nil, nil
  S.filter_selected = nil
  S.filter_timer, S.query, S.matches, S.match_files, S.filter_accept = nil, nil, nil, nil, nil
  if extras then M.refresh() end
  render()
end

local function fuzzy_score(text, query)
  local at, score, previous = 1, 0, 0
  text = text:lower()
  for i = 1, #query do
    local found = text:find(query:sub(i, i), at, true)
    if not found then return end
    score, previous, at = score + found - previous - 1, found, found + 1
  end
  return score + #text / 1000
end

local function filter_move(delta)
  local rows = {}
  for i, row in ipairs(S.rows) do if row.node and (not S.match_files or S.match_files[row.node.path]) and not row.header then rows[#rows + 1] = i end end
  if #rows == 0 then return end
  local current, at = S.filter_selected and S.index[S.filter_selected] or api.nvim_win_get_cursor(S.win)[1], 0
  for i, row in ipairs(rows) do if row == current then at = i break end end
  local row = rows[(at - 1 + delta) % #rows + 1]
  S.filter_selected = S.rows[row].node.path
  api.nvim_win_set_cursor(S.win, { row, 0 })
  local path = S.filter_selected
  vim.schedule(function()
    if visible() and S.filter_selected == path and S.index[path] then api.nvim_win_set_cursor(S.win, { S.index[path], 0 }) end
  end)
end

local function accept_match()
  S.filter_accept = nil
  local path = S.filter_selected
  S.filter_selected = nil
  if path and S.index[path] then return cursor(path) end
  local node = node_at()
  if not node or not S.match_files or not S.match_files[node.path] then filter_move(1) end
  S.filter_selected = nil
end

local function search(query, directories, sorter)
  if not visible() then return end
  S.search_serial = (S.search_serial or 0) + 1
  local serial, epoch, root = S.search_serial, S.epoch, S.root
  if S.search then S.search:kill(15) end
  if query == "" then return clear_filter() end
  if S.query ~= query:lower() then S.filter_selected = nil end
  S.query = query:lower()
  local args = directories and { "find", ".", "-name", ".git", "-prune", "-o", "-type", "d", "-print0" }
    or { "rg", "--files", "--hidden", "--null", "--glob", "!.git", "--glob", "!.DS_Store", "--glob", "!thumbs.db" }
  if not directories and S.hidden then args[#args + 1] = "--no-ignore" end
  local chunks, bytes, truncated = {}, 0, false
  local process
  process = vim.system(args, { cwd = root, timeout = BUDGET, stdout = function(_, data)
    if not data then return end
    bytes = bytes + #data
    if bytes <= 4 * 1024 * 1024 then chunks[#chunks + 1] = data
    else truncated = true if process then process:kill(15) end end
  end }, function(result)
    vim.schedule(function()
      if serial ~= S.search_serial or epoch ~= S.epoch or not visible() then return end
      S.search = nil
      local data = table.concat(chunks)
      local paths, at, matches = data:gmatch("([^%z]+)%z"), 0, {}
      local deadline = uv.hrtime() + BUDGET * 1000000
      local function finish()
        if serial ~= S.search_serial or epoch ~= S.epoch or not visible() then return end
        if sorter then table.sort(matches, function(a, b) return a.score < b.score end) end
        local allowed, files, scores = {}, {}, {}
        S.filter_nodes = S.filter_nodes or {}
        for i = 1, math.min(200, #matches) do
          local item, parent = matches[i], S.nodes[root]
          local parts = vim.split(item.path:sub(#join(root, "") + 1), "/", { plain = true })
          for j, part in ipairs(parts) do
            local path = join(parent.path, part)
            if not S.nodes[path] then S.filter_nodes[path] = true end
            local child = new_node(path, (directories or j < #parts) and "directory" or "file")
            include(parent, child)
            allowed[child.path], parent = true, child
            scores[path] = math.min(scores[path] or math.huge, item.score)
          end
          files[item.path] = true
        end
        S.matches, S.match_files, S.first = allowed, files, true
        S.scores = sorter and scores or nil
        if result.code > 1 and result.code ~= 143 then S.notice = "search incomplete · " .. display(result.stderr or "")
        elseif truncated or #matches > 200 then S.notice = "search capped · first 200 matches"
        else S.notice = nil end
        render()
        if S.filter_accept then vim.schedule(accept_match) end
      end
      local function batch()
        if serial ~= S.search_serial or epoch ~= S.epoch then return end
        local start = uv.hrtime()
        while uv.hrtime() - start < 2000000 do
          local relative = paths()
          if not relative then return finish() end
          at = at + 1
          local path = vim.fs.normalize(join(root, relative:gsub("^%./", "")))
          local score = fuzzy_score(relative, S.query)
          if path ~= root and score and not hidden({ name = vim.fs.basename(path), path = path }) then matches[#matches + 1] = { path = path, score = score } end
          if not sorter and #matches >= 200 then return finish() end
          if at >= 100000 or uv.hrtime() > deadline then truncated = true return finish() end
        end
        vim.defer_fn(batch, 1)
      end
      batch()
    end)
  end)
  S.search = process
end

local function filter(directories, sorter, submit)
  S.filter_selected = nil
  if S.source == "buffers" then directories = false end
  refresh_loaded()
  S.reveal, S.select, S.revealing = (S.reveal or 0) + 1, nil, nil
  local group, changed, cancel = api.nvim_create_augroup("UiTreeFilter", {}), false, false
  local last_query = S.query or ""
  local mappings = {}
  local function map(lhs, run)
    mappings[lhs] = vim.fn.maparg(lhs, "c", false, true)
    vim.keymap.set("c", lhs, run, { expr = true, silent = true })
  end
  local function accept(clear) return function() cancel = clear return "\r" end end
  map("<C-n>", function() filter_move(1) return "" end)
  map("<Down>", function() filter_move(1) return "" end)
  map("<C-p>", function() filter_move(-1) return "" end)
  map("<Up>", function() filter_move(-1) return "" end)
  map("<S-CR>", accept(false))
  map("<C-CR>", accept(true))
  api.nvim_create_autocmd("CmdlineChanged", { group = group, callback = function()
    changed = true
    if submit then return end
    local query = vim.fn.getcmdline()
    if query == last_query then return end
    last_query = query
    debounce("filter_timer", 50, function() search(query, directories, sorter) end)
  end })
  local ok, query = pcall(vim.fn.input, { prompt = directories and "directories /" or "/", default = S.query or "", cancelreturn = "" })
  api.nvim_del_augroup_by_id(group)
  for lhs, mapping in pairs(mappings) do
    pcall(vim.keymap.del, "c", lhs)
    if next(mapping) then vim.fn.mapset("c", false, mapping) end
  end
  if not visible() then return end
  api.nvim_set_current_win(S.win)
  if not ok or query == "" or cancel then return clear_filter() end
  if changed then
    stop(S.filter_timer)
    S.filter_timer, S.filter_accept = nil, true
    if S.query ~= query:lower() or submit or not S.matches then search(query, directories, sorter) else accept_match() end
  else
    S.query, S.first = query:lower(), true
    render()
  end
end

local function set_root(path)
  local float, inplace, source, side = S.float, S.inplace, S.source, S.side
  S.binding = true
  M.open(path, float, inplace, source, side)
  vim.cmd((inplace and "lcd " or "tcd ") .. vim.fn.fnameescape(path))
  S.binding = nil
end

local function root_here() set_root(base_dir()) end
local function root_up() set_root(vim.fs.dirname(S.root)) end
local function help() require("ui.keys").open("Popups", "File tree") end
local function switch_source() M.open(S.root, S.float, S.inplace, S.source == "buffers" and "filesystem" or "buffers", S.side) end
local function close_node()
  local node = node_at()
  if not node then return end
  if node.dir and node.expanded then return collapse(node) end
  local parent_node = S.nodes[vim.fs.dirname(node.path)]
  if parent_node then collapse(parent_node) S.select = parent_node.path end
end
local function collapse_all()
  S.reveal, S.select, S.revealing = (S.reveal or 0) + 1, nil, nil
  for _, node in pairs(S.nodes) do if node.path ~= S.root then node.expanded = false retire(node) end end
  render()
end
local function cancel()
  if S.preview_on then return close_preview() end
  if S.query then return clear_filter() end
  if S.float then M.close() end
end

M.keys = { { section = "File tree", keys = {
  { "<CR>", "open file / toggle directory", run = function() open_file() end },
  { "<2-LeftMouse>", "open file / toggle directory", run = function() open_file() end },
  { "<Space>", "toggle directory", run = function() local n = node_at() if n and n.dir then open_file() end end },
  { "l", "focus preview / open node", run = function() if S.preview_win and api.nvim_win_is_valid(S.preview_win) then api.nvim_set_current_win(S.preview_win) else open_file() end end },
  { "h", "collapse / parent", run = parent },
  { "s", "vertical split", run = function() open_file("s") end },
  { "S", "horizontal split", run = function() open_file("S") end },
  { "t", "new tab", run = function() open_file("t") end },
  { "w", "choose destination window", run = window_picker },
  { "P", "toggle floating preview", run = function() if S.preview_on then close_preview() else S.preview_on = true preview() end end },
  { "<C-f>", "scroll preview down", run = function() scroll_preview(10) end },
  { "<C-b>", "scroll preview up", run = function() scroll_preview(-10) end },
  { "a", "add file or trailing / directory", run = function() add(false) end },
  { "A", "add directory", run = function() add(true) end },
  { "r", "rename", run = function() rename(false) end },
  { "b", "rename basename, preserving extension", run = function() rename(true) end },
  { "d", "delete permanently / remove buffer", run = function() if S.source == "buffers" then buffer_delete() else delete(false) end end },
  { "bd", "remove buffer", run = buffer_delete },
  { "T", "trash", run = function() delete(true) end },
  { "u", "undo last trash", run = function() restore_trash(true) end },
  { "U", "restore from trash", run = function() restore_trash(false) end },
  { "c", "copy to destination path", run = function() transfer(false) end },
  { "m", "move to destination path", run = function() transfer(true) end },
  { "y", "copy to clipboard", run = function() clipboard(false) end },
  { "x", "cut to clipboard", run = function() clipboard(true) end },
  { "p", "paste clipboard", run = paste },
  { "<C-r>", "clear clipboard", run = function() S.clipboard = {} render(true) end },
  { "Y", "yank absolute path", run = function() yank(true) end },
  { "<Tab>", "toggle selection", run = function() mark_selection() end },
  { "<C-S-i>", "invert selection", run = function() mark_selection("invert") end },
  { "<C-;>", "clear selection", run = function() mark_selection("clear") end },
  { "H", "toggle gitignored", run = function() S.hidden = not S.hidden prune() M.refresh() if S.query then search(S.query) end render() end },
  { "R", "refresh", run = M.refresh },
  { "C", "close node", run = close_node },
  { "z", "close all nodes", run = collapse_all },
  { ".", "root at directory and change cwd", run = root_here },
  { "<BS>", "root up and change cwd", run = root_up },
  { "-", "root up and change cwd", run = root_up },
  { "/", "recursive fuzzy finder", run = function() filter(false, false, false) end },
  { "D", "recursive directory finder", run = function() filter(true, false, false) end },
  { "#", "recursive fuzzy sorter", run = function() filter(false, true, false) end },
  { "f", "filter on submit", run = function() filter(false, false, true) end },
  { "<C-x>", "clear filter", run = function() clear_filter() end },
  { "[g", "previous git modified file", run = function() git_jump(-1) end },
  { "]g", "next git modified file", run = function() git_jump(1) end },
  { "i", "file details", run = details },
  { "o", "order by (c/d/g/m/n/s/t)", run = help },
  { "oc", "order by created", run = function() order_by("birthtime") end },
  { "od", "order by diagnostics", run = function() order_by("diagnostics") end },
  { "og", "order by git status", run = function() order_by("git") end },
  { "om", "order by modified", run = function() order_by("mtime") end },
  { "on", "order by name", run = function() order_by("name") end },
  { "os", "order by size", run = function() order_by("size") end },
  { "ot", "order by type", run = function() order_by("type") end },
  { "e", "toggle auto-expand width", run = function() S.auto_width = not S.auto_width render() end },
  { "<", "previous source", run = switch_source },
  { ">", "next source", run = switch_source },
  { "<C-s>", "jump using row labels", run = quick_jump },
  { "?", "help", run = help },
  { "g?", "help", run = help },
  { "q", "close", run = function() M.close() end },
  { "<Esc>", "close preview / clear filter / close float", run = cancel },
} } }

local function win_opts()
  local wo = vim.wo[S.win]
  S.options = {}
  for _, name in ipairs({ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "list", "wrap", "spell",
    "colorcolumn", "winbar", "cursorline", "foldenable", "winfixwidth", "winhighlight" }) do S.options[name] = wo[name] end
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, true, "no", "0", ""
  wo.list, wo.wrap, wo.spell, wo.colorcolumn, wo.winbar = false, false, false, "", ""
  wo.cursorline, wo.foldenable, wo.winfixwidth = true, false, not S.float
  wo.winhighlight = "Normal:" .. (S.float and "NormalFloat" or "Normal") .. ",CursorLine:PmenuSel"
end

local function normal_windows(win)
  local count = 0
  for _, id in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(win))) do
    if api.nvim_win_get_config(id).relative == "" then count = count + 1 end
  end
  return count
end

local function detach(keep)
  close_preview()
  if S.search then S.search:kill(15) S.search = nil end
  stop(S.filter_timer)
  S.filter_timer = nil
  local win = S.win
  S.win = nil
  if not keep and not S.session_loading then vim.g.AosTreeSession = "" end
  if not keep and win and api.nvim_win_is_valid(win) then
    for name, value in pairs(S.options or {}) do vim.wo[win][name] = value end
  end
  if not keep then S.options, S.select, S.first, S.repaint = nil, nil, nil, nil end
  epoch = epoch + 1
  S.epoch = epoch
  S.version = (S.version or 0) + 1
  for _, node in pairs(S.nodes) do if node.cancel then node.cancel() end end
  for path in pairs(S.watchers) do unwatch(path) end
  stop(S.watch_timer) stop(S.git_timer) stop(S.poll_timer) stop(S.reveal_timer)
  stop(S.root_timer) stop(S.buffer_timer)
  S.root_timer, S.buffer_timer = nil, nil
  S.watch_timer, S.git_timer, S.poll_timer, S.reveal_timer, S.revealing = nil, nil, nil, nil, nil
  if keep then S.win = win end
end

function M.close()
  local win = visible() and S.win or nil
  if win and not S.float and not S.inplace and normal_windows(win) > 1 then S.width = api.nvim_win_get_width(win) end
  detach()
  if not win or not api.nvim_win_is_valid(win) then return end
  if S.inplace or not S.float and normal_windows(win) == 1 then
    local previous = S.previous
    api.nvim_win_set_buf(win, previous and api.nvim_buf_is_valid(previous) and previous or api.nvim_create_buf(true, false))
  else api.nvim_win_close(win, true) end
end

local function poll_root()
  local generation = S.epoch
  S.root_timer = uv.new_timer()
  S.root_timer:start(400, 400, later(function()
    if not visible() or generation ~= S.epoch then return end
    if S.query then refresh_loaded() end
    for _, directory in pairs(S.nodes) do
      if directory.dir and directory.expanded and not hidden(directory) then
        uv.fs_stat(directory.path, later(function(_, stat)
          if generation ~= S.epoch or not stat or stat.ino == directory.ino and stat.dev == directory.dev then return end
          scan(directory)
          if directory.path == S.root then S.gitroot = nil locate() end
        end))
      end
    end
  end))
end

function M.open(root, float, inplace, source, side)
  local origin = api.nvim_get_current_win()
  local previous = origin == S.win and S.previous or api.nvim_win_get_buf(origin)
  if visible() and origin == S.win then origin = S.origin end
  local inplace_win = api.nvim_get_current_win()
  if inplace and inplace_win == S.win and not S.inplace then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if win ~= S.win and api.nvim_win_get_config(win).relative == "" then inplace_win = win break end
    end
  end
  M.close()
  S.tab = api.nvim_get_current_tabpage()
  root = vim.fs.normalize(vim.fn.fnamemodify(root or S.root or vim.fn.getcwd(), ":p"))
  if root ~= "/" then root = root:gsub("/$", "") end
  source = source or "filesystem"
  if root ~= S.root or source ~= S.source then
    S.nodes, S.root, S.gitroot, S.query, S.notice, S.target = {}, root, nil, nil, nil, nil
    S.matches, S.match_files, S.selection = nil, nil, {}
  end
  S.source, S.side, S.previous = source, side or "left", previous
  S.float, S.origin, S.lines, S.rows, S.index = float == true, origin, { "" }, {}, {}
  S.inplace = inplace == true
  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].filetype, vim.bo[S.buf].bufhidden, vim.bo[S.buf].buftype = "aostree", "wipe", "nofile"
  vim.bo[S.buf].swapfile, vim.b[S.buf].completion = false, false
  for _, key in ipairs(M.keys[1].keys) do
    if key[1] ~= "bd" or source == "buffers" then
      vim.keymap.set("n", key[1], key.run, { buffer = S.buf, nowait = key[1] ~= "o" and (key[1] ~= "b" or source ~= "buffers"), desc = key[2] })
    end
  end
  for _, key in ipairs({ "y", "x", "d", "T", "c", "m" }) do
    vim.keymap.set("x", key, function()
      local first, last = vim.fn.line("v"), vim.fn.line(".")
      S.selection = {}
      for i = math.min(first, last), math.max(first, last) do
        local row = S.rows[i]
        if row and row.node and not row.header then S.selection[row.node.path] = true end
      end
      vim.cmd.normal({ "\27", bang = true })
      for _, mapping in ipairs(M.keys[1].keys) do if mapping[1] == key then mapping.run() break end end
    end, { buffer = S.buf, nowait = true })
  end
  if float then
    local width, height = math.min(80, vim.o.columns - 4), math.max(1, math.floor(vim.o.lines * 0.8))
    S.win = api.nvim_open_win(S.buf, true, { relative = "editor", width = width, height = height,
      row = math.floor((vim.o.lines - height - 2) / 2), col = math.floor((vim.o.columns - width - 2) / 2),
      title = source == "buffers" and " ❯ buffers " or " ❯ tree ", title_pos = "left" })
  elseif inplace then
    S.win = api.nvim_win_is_valid(inplace_win) and inplace_win or api.nvim_get_current_win()
    api.nvim_set_current_win(S.win)
    api.nvim_win_set_buf(S.win, S.buf)
  else
    vim.cmd((S.side == "right" and "botright " or "topleft ") .. math.min(S.width, math.max(12, vim.o.columns - 10)) .. "vsplit")
    S.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(S.win, S.buf)
  end
  win_opts()
  local node = new_node(root, "directory")
  node.expanded = true
  render()
  M.refresh()
  if source ~= "buffers" then locate() poll_root() end
  if S.current then M.reveal(S.current) end
end

function M.toggle(float, source)
  source = source or "filesystem"
  if visible() and api.nvim_win_get_tabpage(S.win) == api.nvim_get_current_tabpage() and S.float == (float == true) and S.source == source then return M.close() end
  M.open(nil, float, false, source)
end

save_session = function()
  if not visible() or S.session_loading then return end
  local dirs = {}
  for path, node in pairs(S.nodes) do if node.dir and node.expanded and path ~= S.root then dirs[#dirs + 1] = path end end
  vim.g.AosTreeSession = vim.json.encode({ root = S.root, float = S.float, inplace = S.inplace,
    width = (S.float or S.inplace) and S.width or api.nvim_win_get_width(S.win), dirs = dirs, source = S.source, side = S.side })
end

local function restore_session()
  local value = vim.g.AosTreeSession
  if type(value) ~= "string" or value == "" then S.session_loading = nil return end
  local ok, data = pcall(vim.json.decode, value)
  if not ok or type(data) ~= "table" or type(data.root) ~= "string" or data.root:sub(1, 1) ~= "/" then
    S.session_loading = nil
    return notify("invalid tree session")
  end
  S.session_loading = true
  local origin, current = api.nvim_get_current_win(), S.current
  local width = tonumber(data.width) or 40
  S.width, S.current = math.max(12, math.min(width, math.max(12, vim.o.columns - 10))), nil
  M.open(data.root, data.float == true, data.inplace == true, data.source, data.side)
  S.current = current
  local dirs = type(data.dirs) == "table" and data.dirs or {}
  dirs = vim.tbl_filter(function(path) return type(path) == "string" and path ~= data.root and within(path, data.root) end, dirs)
  table.sort(dirs)
  local index, epoch = 0, S.epoch
  local function advance()
    if epoch ~= S.epoch then return end
    index = index + 1
    local path = dirs[index]
    if not path then return end
    M.reveal(path, function(node)
      if not node or not node.dir then return advance() end
      node.expanded = true
      scan(node, advance)
    end)
  end
  advance()
  if not data.inplace and api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
  S.session_loading = nil
end

local function diagnostic(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local path, count = api.nvim_buf_get_name(buf), { errors = 0, warnings = 0, info = 0, hints = 0 }
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.severity == vim.diagnostic.severity.ERROR then count.errors = count.errors + 1 end
    if d.severity == vim.diagnostic.severity.WARN then count.warnings = count.warnings + 1 end
    if d.severity == vim.diagnostic.severity.INFO then count.info = count.info + 1 end
    if d.severity == vim.diagnostic.severity.HINT then count.hints = count.hints + 1 end
  end
  diagnostics[path] = count
end

local function colors()
  for letter, group in pairs(LETTER) do
    local color = api.nvim_get_hl(0, { name = group, link = false }).fg
    if color then
      local r, g, b = math.floor(color / 65536), math.floor(color / 256) % 256, color % 256
      api.nvim_set_hl(0, "AosTree" .. letter:gsub("!", "Conflict"), { fg = string.format("#%02x%02x%02x", math.floor(r * 0.65), math.floor(g * 0.65), math.floor(b * 0.65)), bg = "NONE" })
    end
  end
end

function M.setup()
  colors()
  vim.opt.sessionoptions:append("globals")
  local group = api.nvim_create_augroup("UiTree", {})
  api.nvim_create_autocmd("TabLeave", { group = group, callback = function()
    local tab = api.nvim_get_current_tabpage()
    if S.tab ~= tab then return end
    if visible() then detach(true) end
    tabs[tab] = vim.tbl_extend("force", {}, S)
  end })
  api.nvim_create_autocmd("TabEnter", { group = group, callback = function()
    local tab = api.nvim_get_current_tabpage()
    if S.tab == tab then return end
    local data = tabs[tab]
    tabs[tab] = nil
    if not data then data = state(S.width) data.root, data.current = S.root, S.current end
    for key in pairs(S) do S[key] = nil end
    for key, value in pairs(data) do S[key] = value end
    epoch = epoch + 1
    S.epoch, S.tab = epoch, tab
    if not visible() then return end
    M.refresh()
    if S.source ~= "buffers" then locate() poll_root() end
    render()
  end })
  api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    for tab in pairs(tabs) do if not api.nvim_tabpage_is_valid(tab) then tabs[tab] = nil end end
  end })
  local function command_tree(opts)
    local root, position, action, source, reveal = nil, "left", "show", "filesystem", nil
    for _, arg in ipairs(opts.fargs) do
      if arg:match("^dir=") then root = arg:sub(5)
      elseif arg:match("^reveal_file=") then reveal = arg:sub(13)
      elseif arg == "left" or arg == "right" or arg == "float" or arg == "current" then position = arg
      elseif arg == "toggle" or arg == "close" or arg == "reveal" then action = arg
      elseif arg == "filesystem" or arg == "buffers" or arg == "git_status" then source = arg
      else return notify("unknown Tree argument: " .. arg) end
    end
    if action == "close" then return M.close() end
    if source == "git_status" then return require("git.scm").toggle() end
    if action == "toggle" and not root and visible() and S.source == source and S.float == (position == "float") and S.inplace == (position == "current") and S.side == (position == "right" and "right" or "left") then return M.close() end
    if action == "reveal" then reveal = reveal or api.nvim_buf_get_name(0) end
    M.open(root, position == "float", position == "current", source, position == "right" and "right" or "left")
    if reveal and reveal ~= "" then M.reveal(reveal) end
  end
  for _, name in ipairs({ "Tree", "Neotree" }) do
    api.nvim_create_user_command(name, command_tree, { nargs = "*", complete = function() return { "left", "right", "float", "current", "toggle", "reveal", "close", "filesystem", "buffers", "dir=" } end, force = true })
  end
  api.nvim_create_autocmd("CursorMoved", { group = group, callback = function()
    if visible() and api.nvim_get_current_win() == S.win and S.preview_on then preview() end
  end })
  api.nvim_create_autocmd("DirChanged", { group = group, callback = function(ev)
    if S.binding or S.session_loading or not visible() then return end
    if ev.match == "window" and not S.inplace then return end
    local path = vim.v.event.cwd
    if path and path ~= S.root then
      local origin = api.nvim_get_current_win()
      if S.inplace then api.nvim_set_current_win(S.win) end
      M.open(path, S.float, S.inplace, S.source, S.side)
      if S.inplace then S.binding = true vim.cmd.lcd(vim.fn.fnameescape(path)) S.binding = nil end
      if api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
    end
  end })
  api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufUnload" }, { group = group, callback = function()
    if visible() and S.source == "buffers" then debounce("buffer_timer", 30, refresh_buffers) end
  end })
  api.nvim_create_autocmd("SessionLoadPre", { group = group, callback = function() S.session_loading = true end })
  api.nvim_create_autocmd("SessionLoadPost", { group = group, callback = function()
    if S.session_restore_pending then return end
    S.session_restore_pending = true
    vim.schedule(function() S.session_restore_pending = nil restore_session() end)
  end })
  api.nvim_create_autocmd("WinResized", { group = group, callback = save_session })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = colors })
  api.nvim_create_autocmd("DiagnosticChanged", { group = group, callback = function(ev) diagnostic(ev.buf) if visible() then render(true) end end })
  api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost", "BufEnter" }, { group = group, callback = function(ev)
    if vim.bo[ev.buf].buftype ~= "" and not (S.source == "buffers" and vim.bo[ev.buf].buftype == "terminal") then return end
    local path = api.nvim_buf_get_name(ev.buf)
    modified[path] = vim.bo[ev.buf].modified or nil
    if ev.event == "BufEnter" and visible() and S.source == "buffers" and not S.session_loading then
      refresh_buffers()
      for _, node in pairs(S.nodes) do if node.buf == ev.buf then S.select = node.path break end end
      render()
    end
    if ev.event == "BufEnter" and path ~= "" then
      local follow = not S.session_loading
      uv.fs_stat(path, later(function(_, stat)
        if not api.nvim_buf_is_valid(ev.buf) or api.nvim_get_current_buf() ~= ev.buf then return end
        if stat and stat.type == "directory" then
          vim.bo[ev.buf].buflisted, vim.bo[ev.buf].bufhidden = false, "wipe"
          S.binding = true
          vim.cmd.lcd(vim.fn.fnameescape(path))
          S.binding = nil
          M.open(path, false, true)
          return
        end
        S.current = path
        if visible() and follow and not S.session_loading then
          S.origin = api.nvim_get_current_win()
          if S.source == "buffers" then refresh_buffers() end
          M.reveal(path)
        end
      end))
    end
    if ev.event == "BufWritePost" and visible() then debounce("git_timer", GIT_DELAY, refresh_git) end
    if visible() and ev.event == "BufModifiedSet" then render(true) end
  end })
  api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev)
    if ev.buf == S.buf and S.win then detach() end
    local path = api.nvim_buf_get_name(ev.buf)
    diagnostics[path], modified[path] = nil, nil
  end })
  api.nvim_create_autocmd("WinClosed", { group = group, callback = function(ev)
    if tonumber(ev.match) == S.win then M.close() end
  end })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close })
  api.nvim_create_autocmd("FocusGained", { group = group, callback = function() if visible() then M.refresh() end end })
  for _, buf in ipairs(api.nvim_list_bufs()) do diagnostic(buf) end
end

return M
