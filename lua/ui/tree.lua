local M = {}
local uv, api = vim.uv, vim.api
local repo, icons = require("git.repo"), require("ui.icons")
local ns = api.nvim_create_namespace("ui.tree")
local LIMIT, BUDGET, GIT_DELAY = 2000, 3000, 300
local S = { nodes = {}, rows = {}, lines = {}, index = {}, watchers = {}, gitpaths = {}, width = 32, epoch = 0 }
local git, diagnostics, modified = {}, {}, {}
local render, scan, watch, refresh_git
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
  if node.name == ".git" or node.name == ".DS_Store" then return true end
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
  if node then node.dir = kind == "directory" return node end
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
    if a.dir ~= b.dir then return a.dir end
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
end

local function push(stack, node, prefix)
  local list = children(node)
  if node.notice then stack[#stack + 1] = { notice = node.notice, prefix = prefix } end
  for i = #list, 1, -1 do stack[#stack + 1] = { node = list[i], prefix = prefix, last = i == #list } end
end

local function build(version)
  if not visible() then return end
  local rows, lines, index, stack = {}, {}, {}, {}
  local deadline = uv.hrtime() + BUDGET * 1000000
  local root = S.nodes[S.root]
  local title = " ❯ " .. display(S.root) .. " "
  rows[1], lines[1], index[S.root] = { node = root, header = true }, title, 1
  if S.query then rows[2], lines[2] = {}, " filter: " .. display(S.query) .. " · Esc clears " end
  if root.expanded then push(stack, root, " ") end
  local function batch()
    if not visible() or version ~= S.version then return end
    local start = uv.hrtime()
    while #stack > 0 and uv.hrtime() - start < 2000000 do
      local item = table.remove(stack)
      local node = item.node
      local match = not S.query or (node and node.name:lower():find(S.query, 1, true))
      if match or item.notice then
        local icon, hl = "", "AosDim"
        if node then icon, hl = unpack(node.dir and icons.directory or { icons.get_icon(node.name, nil, { default = true }) }) end
        local guide = item.prefix .. (item.last and "└ " or "│ ")
        local lead = guide .. (node and node.dir and (node.expanded and "▾ " or "▸ ") or "")
        local text = lead .. (node and icon .. " " .. display(node.name) or "○ " .. display(item.notice))
        rows[#lines + 1] = { node = node, lead = #lead, guide = #guide, icon = #icon, hl = hl }
        lines[#lines + 1] = text
        if node then index[node.path] = #lines end
      end
      if node and node.dir and (node.expanded or (S.query and node.loaded)) then push(stack, node, item.prefix .. (item.last and "  " or "│ ")) end
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
  local version = S.version
  vim.schedule(function() if version == S.version then build(version) end end)
end

local function badges(node)
  local chunks, g = {}, cache()
  if not node then return chunks end
  local d = diagnostics[node.path]
  if modified[node.path] then chunks[#chunks + 1] = { "● ", "AosArg" } end
  if d and d.errors > 0 then chunks[#chunks + 1] = { "✗" .. d.errors .. " ", "AosFailed" } end
  if d and d.warnings > 0 then chunks[#chunks + 1] = { "!" .. d.warnings .. " ", "AosRunning" } end
  local status = g and (node.dir and g.dirs[node.path] or g.files[node.path])
  if node.dir and status then return vim.list_extend(chunks, { { "· ", "AosTree" .. status:gsub("!", "Conflict") } }) end
  if not status then return chunks end
  if status.staged then chunks[#chunks + 1] = { "✓" .. status.staged .. " ", LETTER[status.staged] } end
  if status.work then chunks[#chunks + 1] = { status.work .. " ", LETTER[status.work] } end
  return chunks
end

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf) return buf == S.buf end,
  on_line = function(_, win, _, line)
    local row = S.rows[line + 1]
    if not row then return end
    local function mark(col, opts) opts.ephemeral = true api.nvim_buf_set_extmark(S.buf, ns, line, col, opts) end
    if row.header then return mark(0, { end_col = #S.lines[line + 1], hl_group = "AosArg" }) end
    if not row.node then return mark(0, { end_col = #S.lines[line + 1], hl_group = "AosDim" }) end
    mark(0, { end_col = row.guide, hl_group = "AosDim" })
    mark(row.guide, { end_col = row.lead, hl_group = "AosDim" })
    mark(row.lead, { end_col = row.lead + row.icon, hl_group = row.hl })
    if row.node.path == S.current then mark(0, { line_hl_group = "PmenuSel" }) end
    local chunks = badges(row.node)
    if #chunks == 0 then return end
    local width = 1
    for _, chunk in ipairs(chunks) do width = width + vim.fn.strdisplaywidth(chunk[1]) end
    table.insert(chunks, 1, { " ", S.float and "NormalFloat" or "Normal" })
    mark(0, { virt_text = chunks, virt_text_win_col = math.max(0, api.nvim_win_get_width(win) - width), virt_text_pos = "overlay" })
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

local function resolve_link(node, epoch)
  uv.fs_stat(node.path, later(function(_, stat)
    if epoch == S.epoch and stat and stat.type == "directory" then node.dir = true render() end
  end))
end

local function prune()
  for _, node in pairs(S.nodes) do
    if not node.expanded or hidden(node) then retire(node) end
  end
end

scan = function(node, done)
  if node.loading then
    if done then node.waiters[#node.waiters + 1] = done end
    return
  end
  local previous = node.children or {}
  local epoch, result, total, finished, dir, reading = S.epoch, {}, 0, false, nil, false
  local timer = uv.new_timer()
  node.loading, node.waiters = true, done and { done } or {}
  -- libuv owns the directory until an in-flight readdir callback returns.
  local function close_dir() if dir and not reading then uv.fs_closedir(dir, function() end) dir = nil end end
  local function publish()
    node.children, node.loaded = result, true
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
    if not err then
      local keep = {}
      for _, child in ipairs(result) do keep[child.path] = true end
      for _, child in ipairs(previous) do
        if child.dir and not keep[child.path] then retire_branch(child.path) end
      end
    end
    node.notice = err or (total > LIMIT and ("… %d more · listing capped at %d"):format(total - LIMIT, LIMIT) or nil)
    publish()
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
      if err or not entries then return finish(err and ("… " .. err) or nil) end
      for _, entry in ipairs(entries) do
        total = total + 1
        if #result < LIMIT then
          local child = new_node(join(node.path, entry.name), entry.type)
          result[#result + 1] = child
          if entry.type == "link" then resolve_link(child, epoch) end
        end
      end
      if total == #entries then publish() end
      vim.schedule(read)
    end))
  end
  uv.fs_opendir(node.path, later(function(err, handle)
    if finished then if handle then uv.fs_closedir(handle, function() end) end return end
    if err then return finish("… " .. err) end
    dir = handle
    read()
  end), 128)
  watch(node.path, false)
end

local function aggregate(g, entries, staged)
  for _, entry in ipairs(entries) do
    local path = join(g.root, entry.path)
    local status = g.files[path] or {}
    status[staged and "staged" or "work"] = entry.letter
    g.files[path] = status
    local dir = vim.fs.dirname(path)
    while within(dir, g.root) do
      if entry.letter == "!" or not g.dirs[dir] then g.dirs[dir] = entry.letter end
      if dir == g.root then break end
      dir = vim.fs.dirname(dir)
    end
    if entry.letter == "D" then
      local parent = vim.fs.dirname(path)
      g.deleted[parent] = g.deleted[parent] or {}
      g.deleted[parent][#g.deleted[parent] + 1] = { path = path, name = vim.fs.basename(path), deleted = true }
    end
  end
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
    if g.again then debounce("git_timer", GIT_DELAY, refresh_git) end
  end
  repo.status(g.root, function(status, err)
    g.status_notice = nil
    if not status then g.status_notice = "git status cut off/unavailable · " .. (err or "unknown error") end
    if status then
      g.files, g.dirs, g.deleted = {}, {}, {}
      aggregate(g, status.staged, true)
      aggregate(g, status.changes, false)
      aggregate(g, status.conflicts, false)
    end
    finish()
  end)
  repo.run({ "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory" }, g.root, function(ok, out, err)
    g.ignore_notice = nil
    if ok then
      g.ignored, g.ignore_dirs = {}, {}
      for path in out:gmatch("([^%z]+)%z") do
        local target = path:sub(-1) == "/" and g.ignore_dirs or g.ignored
        target[join(g.root, path:gsub("/$", ""))] = true
      end
    else g.ignore_notice = "gitignore cut off/unavailable · " .. err end
    finish()
  end, { feature = "tree ignore" })
end

watch = function(path, gitdir)
  if S.watchers[path] or not visible() then return end
  local epoch = S.epoch
  local watcher = uv.new_fs_event()
  local ok = watcher:start(path, {}, function(err, name)
    if err then return end
    if gitdir and name and name:match("%.lock$") then return end
    S.dirty = S.dirty or {}
    if not gitdir then S.dirty[path] = true end
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

local function locate()
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
  end, { feature = "tree lookup" })
end

function M.refresh(done)
  if not visible() then return end
  local nodes = {}
  for _, node in pairs(S.nodes) do
    if node.dir and node.expanded and not hidden(node) then nodes[#nodes + 1] = node end
  end
  local pending = #nodes
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
  S.reveal, S.select = (S.reveal or 0) + 1, nil
  retire_branch(node.path)
  render()
end

local function include(parent, child)
  parent.children = parent.children or {}
  for _, node in ipairs(parent.children) do if node.path == child.path then return end end
  parent.children[#parent.children + 1] = child
end

function M.reveal(path)
  if not visible() or not within(path, S.root) or path == S.root then return end
  S.target, S.reveal = path, (S.reveal or 0) + 1
  local serial, epoch = S.reveal, S.epoch
  local relative = path:sub(#join(S.root, "") + 1)
  local parts, at = vim.split(relative, "/", { plain = true }), 1
  local function step(node)
    if epoch ~= S.epoch or serial ~= S.reveal or not visible() then return end
    if at > #parts then S.select = path render() return end
    node.expanded = true
    watch(node.path, false)
    local function advance()
      if epoch ~= S.epoch or serial ~= S.reveal then return end
      local childpath = join(node.path, parts[at])
      at = at + 1
      local child = S.nodes[childpath]
      if child then include(node, child) return step(child) end
      uv.fs_stat(childpath, later(function(err, stat)
        if err or epoch ~= S.epoch or serial ~= S.reveal then return end
        child = new_node(childpath, stat.type)
        include(node, child)
        step(child)
      end))
    end
    if node.loaded then advance() else scan(node, advance) end
  end
  step(S.nodes[S.root])
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

local function open_file(mode)
  local node = node_at()
  if not node then return end
  if node.dir then
    if node.expanded then collapse(node) else node.expanded = true scan(node) render() end
    return
  end
  if node.deleted then return notify("file was deleted") end
  local tree = S.win
  local win = S.inplace and not mode and tree or destination()
  api.nvim_set_current_win(win)
  local cmd = ({ s = "vsplit", S = "split", t = "tabedit" })[mode] or "edit"
  local ok, err = pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(node.path))
  if not ok then notify(err) end
  if mode == "P" and api.nvim_win_is_valid(tree) then api.nvim_set_current_win(tree)
  elseif S.float then M.close() end
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

local function input(title, default, cb)
  vim.ui.input({ prompt = title .. ": ", default = default or "" }, function(value)
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
    if err:find("EEXIST", 1, true) then return cb() end
    if not err:find("ENOENT", 1, true) then return cb(err) end
    mkdir(vim.fs.dirname(path), function(parenterr)
      if parenterr then return cb(parenterr) end
      uv.fs_mkdir(path, 493, later(cb))
    end)
  end))
end

local function changed(err, path)
  if err then return notify(err) end
  M.refresh()
  if path then M.reveal(path) end
end

local function add()
  local base = base_dir()
  input("add (trailing / for directory)", "", function(value)
    local path = valid_path(value, base)
    if not path then return end
    mkdir(value:sub(-1) == "/" and path or vim.fs.dirname(path), function(err)
      if err or value:sub(-1) == "/" then return changed(err, path) end
      uv.fs_open(path, "wx", 420, later(function(openerr, fd)
        if fd then uv.fs_close(fd, function() end) end
        changed(openerr, path)
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

local function buffer_destination(buf, name)
  for _, existing in ipairs(api.nvim_list_bufs()) do
    if existing ~= buf and api.nvim_buf_get_name(existing) == name then
      if api.nvim_buf_is_loaded(existing) or vim.bo[existing].modified then
        notify("destination buffer already exists: " .. name)
        return false
      end
      api.nvim_buf_delete(existing, { force = false })
    end
  end
  return true
end

local function move(from, to)
  if within(to, from) then return notify("destination must be outside the source") end
  for _, buf in ipairs(buffers_under(from)) do
    if not buffer_destination(buf, to .. api.nvim_buf_get_name(buf):sub(#from + 1)) then return end
  end
  unused(to, function()
    mkdir(vim.fs.dirname(to), function(err)
      if err then return notify(err) end
      uv.fs_rename(from, to, later(function(renameerr)
        if not renameerr then
          move_buffers(from, to)
          if S.clipboard and S.clipboard.cut and S.clipboard.path == from then S.clipboard = nil end
        end
        changed(renameerr, to)
      end))
    end)
  end)
end

local function rename()
  local node = node_at()
  if not node or node.path == S.root then return end
  input("rename", node.name, function(value)
    local path = valid_path(value, vim.fs.dirname(node.path))
    if path and path ~= node.path then move(node.path, path) end
  end)
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

local function delete()
  local node = node_at()
  if not node or node.path == S.root then return end
  local buffers = buffers_under(node.path)
  for _, buf in ipairs(buffers) do
    if vim.bo[buf].modified then return notify("save or close modified buffer before deleting: " .. api.nvim_buf_get_name(buf)) end
  end
  local function remove(trash)
    command(trash and { "gio", "trash", "--", node.path } or { "rm", "-rf", "--", node.path }, function(err)
      if err then return notify(err) end
      for _, buf in ipairs(buffers) do
        if api.nvim_buf_is_valid(buf) then
          if vim.bo[buf].modified then notify("deleted file has modified buffer: " .. api.nvim_buf_get_name(buf))
          else api.nvim_buf_delete(buf, { force = false }) end
        end
      end
      changed()
    end)
  end
  if vim.fn.executable("gio") == 1 then return remove(true) end
  vim.ui.select({ "cancel", "delete permanently" }, { prompt = "delete " .. node.name .. "?" }, function(choice)
    if choice == "delete permanently" then remove(false) end
  end)
end

local function clipboard(cut)
  local node = node_at()
  if node and node.path ~= S.root then S.clipboard = { path = node.path, cut = cut } end
end

local function paste()
  local clip = S.clipboard
  if not clip then return end
  local target = join(base_dir(), vim.fs.basename(clip.path))
  if within(target, clip.path) then return notify("destination must be outside the source") end
  if clip.cut then move(clip.path, target) return end
  unused(target, function() command({ "cp", "-R", "-n", "--", clip.path, target }, function(err) changed(err, target) end) end)
end

local function yank(absolute)
  local node = node_at()
  if not node then return end
  local path = absolute and node.path or (node.path == S.root and "." or node.path:sub(#join(S.root, "") + 1))
  vim.fn.setreg('"', path)
end

local function filter()
  S.reveal, S.select = (S.reveal or 0) + 1, nil
  local group = api.nvim_create_augroup("UiTreeFilter", {})
  api.nvim_create_autocmd("CmdlineChanged", { group = group, callback = function()
    local query = vim.fn.getcmdline()
    S.query = query ~= "" and query:lower() or nil
    S.first = true
    render()
    vim.cmd.redraw()
  end })
  local ok, query = pcall(vim.fn.input, { prompt = "/", default = S.query or "", cancelreturn = "" })
  api.nvim_del_augroup_by_id(group)
  S.query = ok and query ~= "" and query:lower() or nil
  S.first = true
  if visible() then api.nvim_set_current_win(S.win) end
  render()
end

M.keys = { { section = "File tree", keys = {
  { "<CR>", "open file / toggle directory", run = function() open_file() end },
  { "l", "open file / toggle directory", run = function() open_file() end },
  { "o", "open file / toggle directory", run = function() open_file() end },
  { "h", "collapse / parent", run = parent },
  { "s", "vertical split", run = function() open_file("s") end },
  { "S", "horizontal split", run = function() open_file("S") end },
  { "t", "tab", run = function() open_file("t") end },
  { "P", "preview in previous window", run = function() open_file("P") end },
  { "a", "add (trailing / creates directory)", run = add },
  { "r", "rename", run = rename },
  { "d", "trash (confirm permanent deletion without gio)", run = delete },
  { "c", "copy", run = function() clipboard(false) end },
  { "x", "cut", run = function() clipboard(true) end },
  { "p", "paste", run = paste },
  { "y", "yank relative path", run = function() yank(false) end },
  { "Y", "yank absolute path", run = function() yank(true) end },
  { "H", "toggle gitignored", run = function() S.hidden = not S.hidden prune() M.refresh() render() end },
  { "R", "refresh", run = M.refresh },
  { "z", "collapse all", run = function()
    S.reveal, S.select = (S.reveal or 0) + 1, nil
    for _, node in pairs(S.nodes) do
      if node.path ~= S.root then node.expanded = false retire(node) end
    end
    render()
  end },
  { ".", "root at directory", run = function() local node = node_at() if node and node.dir then M.open(node.path, S.float) end end },
  { "-", "root up", run = function() M.open(vim.fs.dirname(S.root), S.float) end },
  { "/", "filter loaded names (Enter selects first, Esc clears)", run = filter },
  { "g?", "help", run = function() require("ui.keys").open("Popups", "File tree") end },
  { "q", "close", run = function() M.close() end },
  { "<Esc>", "clear filter / close", run = function() if S.query then S.query = nil render() else M.close() end end },
} } }

local function win_opts()
  local wo = vim.wo[S.win]
  S.options = {}
  for _, name in ipairs({ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "list", "wrap", "spell",
    "colorcolumn", "winbar", "cursorline", "foldenable", "winfixwidth", "winhighlight" }) do S.options[name] = wo[name] end
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, "no", "0", ""
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

local function detach()
  local win = S.win
  S.win = nil
  if win and api.nvim_win_is_valid(win) then
    for name, value in pairs(S.options or {}) do vim.wo[win][name] = value end
  end
  S.options, S.select, S.first, S.repaint = nil, nil, nil, nil
  S.epoch = S.epoch + 1
  S.version = (S.version or 0) + 1
  for _, node in pairs(S.nodes) do if node.cancel then node.cancel() end end
  for path in pairs(S.watchers) do unwatch(path) end
  stop(S.watch_timer) stop(S.git_timer)
  S.watch_timer, S.git_timer = nil, nil
end

function M.close()
  local win = visible() and S.win or nil
  if win and not S.float and not S.inplace and normal_windows(win) > 1 then S.width = api.nvim_win_get_width(win) end
  detach()
  if not win or not api.nvim_win_is_valid(win) then return end
  if not S.float and normal_windows(win) == 1 then api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
  else api.nvim_win_close(win, true) end
end

function M.open(root, float, inplace)
  local origin = api.nvim_get_current_win()
  if visible() and origin == S.win then origin = S.origin end
  M.close()
  root = vim.fs.normalize(root or S.root or vim.fn.getcwd())
  if root ~= S.root then
    S.nodes, S.root, S.gitroot, S.query, S.notice, S.target = {}, root, nil, nil, nil, nil
  end
  S.float, S.origin, S.lines, S.rows, S.index = float == true, origin, { "" }, {}, {}
  S.inplace = inplace == true
  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].filetype, vim.bo[S.buf].bufhidden, vim.bo[S.buf].buftype = "aostree", "wipe", "nofile"
  vim.bo[S.buf].swapfile, vim.b[S.buf].completion = false, false
  for _, key in ipairs(M.keys[1].keys) do vim.keymap.set("n", key[1], key.run, { buffer = S.buf, nowait = true, desc = key[2] }) end
  if float then
    local width, height = math.min(80, vim.o.columns - 4), math.max(1, math.floor(vim.o.lines * 0.8))
    S.win = api.nvim_open_win(S.buf, true, { relative = "editor", width = width, height = height,
      row = math.floor((vim.o.lines - height - 2) / 2), col = math.floor((vim.o.columns - width - 2) / 2),
      border = "single", title = " ❯ tree ", title_pos = "left" })
  elseif inplace then
    S.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(S.win, S.buf)
  else
    vim.cmd("topleft " .. math.min(S.width, math.max(12, vim.o.columns - 10)) .. "vnew")
    S.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(S.win, S.buf)
  end
  win_opts()
  local node = new_node(root, "directory")
  node.expanded = true
  render()
  M.refresh()
  locate()
  if S.current then M.reveal(S.current) end
end

function M.toggle(float)
  if visible() and api.nvim_win_get_tabpage(S.win) == api.nvim_get_current_tabpage() and S.float == (float == true) then return M.close() end
  M.open(nil, float)
end

local function diagnostic(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local path, count = api.nvim_buf_get_name(buf), { errors = 0, warnings = 0 }
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.severity == vim.diagnostic.severity.ERROR then count.errors = count.errors + 1 end
    if d.severity == vim.diagnostic.severity.WARN then count.warnings = count.warnings + 1 end
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
  local group = api.nvim_create_augroup("UiTree", {})
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = colors })
  api.nvim_create_autocmd("DiagnosticChanged", { group = group, callback = function(ev) diagnostic(ev.buf) end })
  api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost", "BufEnter" }, { group = group, callback = function(ev)
    if vim.bo[ev.buf].buftype ~= "" then return end
    local path = api.nvim_buf_get_name(ev.buf)
    modified[path] = vim.bo[ev.buf].modified or nil
    if ev.event == "BufEnter" and path ~= "" then
      uv.fs_stat(path, later(function(_, stat)
        if not api.nvim_buf_is_valid(ev.buf) or api.nvim_get_current_buf() ~= ev.buf then return end
        if stat and stat.type == "directory" then
          vim.bo[ev.buf].buflisted, vim.bo[ev.buf].bufhidden = false, "wipe"
          vim.cmd.cd(vim.fn.fnameescape(path))
          M.open(path, false, true)
          return
        end
        S.current = path
        if visible() then S.origin = api.nvim_get_current_win() M.reveal(path) end
      end))
    end
    if ev.event == "BufWritePost" and visible() then debounce("git_timer", GIT_DELAY, refresh_git) end
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
