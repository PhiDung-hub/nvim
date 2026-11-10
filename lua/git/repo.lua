-- Shared git layer: async runs, repo root, parsed status and file contents at a revision.
local M = {}

-- Every git read is capped at BUDGET ms: past that it is killed, and that feature stays off for the repo for
-- PAUSE ms (one notice), so a slow repo never keeps working in the background. Network commands get NET_BUDGET.
-- Local writes (add, apply, commit, switch…) are never killed: a kill mid-write can leave index.lock behind.
-- Reads never download missing objects of a partial clone (GIT_NO_LAZY_FETCH), which is what made blame slow.
local BUDGET, NET_BUDGET, PAUSE = 3000, 60000, 10 * 60 * 1000
local READ = {}
for _, c in ipairs({ "blame", "log", "show", "diff", "status", "rev-parse", "rev-list", "for-each-ref", "show-ref", "cat-file",
  "ls-files", "ls-tree", "name-rev", "merge-base", "describe", "symbolic-ref", "check-ignore", "grep" }) do READ[c] = true end
local NET = { fetch = true, pull = true, push = true, ["ls-remote"] = true, clone = true }
local slow = {} -- root .. "\0" .. feature -> uv time it was paused

local function subcommand(args)
  for _, a in ipairs(args) do
    if a:sub(1, 1) ~= "-" then return a end
  end
end

local function budget(args, opts)
  local sub = subcommand(args)
  if opts.timeout then return opts.timeout, sub end
  return READ[sub] and BUDGET or NET[sub] and NET_BUDGET or nil, sub
end

local function command(args, cwd)
  return vim.list_extend({ "git", "-C", cwd or vim.fn.getcwd(), "--no-pager", "-c", "color.ui=never" }, args)
end

local function env(sub)
  local e = { GIT_TERMINAL_PROMPT = "0", GIT_EDITOR = "true" }
  if READ[sub] then e.GIT_NO_LAZY_FETCH, e.GIT_OPTIONAL_LOCKS = "1", "0" end
  return e
end

local function pause(key, feature, ms)
  if slow[key] then return end
  slow[key] = vim.uv.now()
  vim.notify(("○ git %s paused for this repo · took over %.1f s"):format(feature, ms / 1000), vim.log.levels.WARN)
end

-- True while `feature` (default: the subcommand) is paused for `root` after a timeout.
function M.is_slow(root, feature)
  local at = slow[(root or "") .. "\0" .. feature]
  return at ~= nil and vim.uv.now() - at < PAUSE
end

local skipped = { kill = function() end, is_closing = function() return true end, wait = function() return { code = 124 } end }

-- Runs `git -C cwd args…`; cb(ok, stdout, stderr, timed_out) on the main loop. Returns the vim.SystemObj (or a stub
-- when the feature is paused). opts: stdin, timeout (ms), feature (name for the pause notice), binary (raw bytes).
function M.run(args, cwd, cb, opts)
  opts = opts or {}
  local limit, sub = budget(args, opts)
  local feature = opts.feature or sub or "git"
  local key = (cwd or vim.fn.getcwd()) .. "\0" .. feature
  if limit and M.is_slow(cwd or vim.fn.getcwd(), feature) then
    vim.schedule(function() cb(false, "", "skipped: git " .. feature .. " is paused (slow repo)", true) end)
    return skipped
  end
  local started, finished = vim.uv.now(), false
  -- An uncapped write past BUDGET is never silent.
  if not limit then
    vim.defer_fn(function()
      if not finished then vim.notify(("◆ git %s still running…"):format(sub or "")) end
    end, BUDGET)
  end
  -- Network commands lead their own process group, so a cancel (kill -pid) also ends the ssh/https helper.
  local detach = NET[sub] or nil
  return vim.system(command(args, cwd), { text = not opts.binary, stdin = opts.stdin, env = env(sub), timeout = limit, detach = detach }, function(r)
    finished = true
    local timed_out = limit ~= nil and r.code == 124 and vim.uv.now() - started >= limit
    vim.schedule(function()
      if timed_out then pause(key, feature, limit) end
      cb(r.code == 0 and r.signal == 0, r.stdout or "", timed_out and ("timed out after %.1f s"):format(limit / 1000) or r.stderr or "", timed_out)
    end)
  end)
end

local function first_line(file)
  local f = io.open(file)
  local line = f and f:read("*l") or ""
  if f then f:close() end
  return line
end

local function abs(p, base) return p:sub(1, 1) == "/" and p or base .. "/" .. p end

-- Git's is_git_directory(): objects (or a commondir holding them, linked worktrees) and a valid HEAD.
local function is_gitdir(dir)
  if not (vim.uv.fs_stat(dir .. "/objects") or vim.uv.fs_stat(dir .. "/commondir")) then return false end
  local head = first_line(dir .. "/HEAD")
  return head:match("^ref: refs/") ~= nil or (head:match("^%x+$") ~= nil and (#head == 40 or #head == 64))
end

-- The work tree a git directory yields: nil when its config says bare, its core.worktree (submodule gitdirs
-- under .git/modules, or set by hand) resolved against it, else `default`.
local function worktree(gitdir, default)
  local f = io.open(gitdir .. "/config")
  local cfg = f and "\n" .. f:read("*a") or ""
  if f then f:close() end
  if cfg:match("\n%s*bare%s*=%s*true") then return nil end
  local tree = cfg:match("\n%s*worktree%s*=%s*([^\n]-)%s*\n")
  if tree then return vim.uv.fs_realpath(abs(tree, gitdir)) end
  return default
end

-- The git directory at `path`: itself, or the one a `.git` file (worktree, submodule) points at; nil if invalid.
local function gitdir_at(path, stat)
  if stat.type == "file" then
    local target = first_line(path):match("^gitdir: (.+)$")
    path = target and abs(target, vim.fs.dirname(path))
  end
  return path and is_gitdir(path) and path or nil
end

-- What git finds in `dir`: a work tree (or nil, where git stops without one), or false to keep walking up.
-- A `.git` file that points nowhere valid stops git; a `.git` directory that is not a repo is skipped.
local function candidate(dir)
  local stat = vim.uv.fs_stat(dir .. "/.git")
  local gitdir = stat and gitdir_at(dir .. "/.git", stat)
  if gitdir then return worktree(gitdir, dir) end
  if stat and stat.type == "file" then return nil end
  if is_gitdir(dir) then return worktree(dir, nil) end
  return false
end

-- Git's discovery walk, without a process; like git it stops at a filesystem boundary.
local function discover(dir)
  local dev = vim.uv.fs_stat(dir).dev
  local across = (vim.env.GIT_DISCOVERY_ACROSS_FILESYSTEM or ""):match("^[1tTyY]")
  while dir do
    local top = candidate(dir)
    if top ~= false then return top end
    local parent = vim.fs.dirname(dir)
    local pstat = parent ~= dir and vim.uv.fs_stat(parent)
    dir = pstat and (across or pstat.dev == dev) and parent or nil
  end
end

-- Worktree root containing `path` (a file or directory; default cwd), or nil outside git: what
-- `git rev-parse --show-toplevel` prints there (symlinks resolved), from a filesystem walk.
function M.root(path)
  path = path and path ~= "" and vim.fs.normalize(path) or vim.fn.getcwd()
  local dir = vim.uv.fs_realpath(vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path))
  if not dir then return nil end
  local tree = vim.env.GIT_WORK_TREE and vim.uv.fs_realpath(abs(vim.env.GIT_WORK_TREE, dir))
  if vim.env.GIT_DIR then
    local path = abs(vim.env.GIT_DIR, dir)
    local stat = vim.uv.fs_stat(path)
    local gitdir = stat and gitdir_at(path, stat)
    return gitdir and (tree or worktree(gitdir, dir)) or nil
  end
  local top = discover(dir)
  return top and tree or top
end

-- Path of `file` relative to `root`, with forward slashes.
function M.relative(root, file)
  file = vim.fs.normalize(file)
  return file:sub(1, #root + 1) == root .. "/" and file:sub(#root + 2) or file
end

local xy_kind = { M = "modified", A = "added", D = "deleted", R = "renamed", C = "copied", T = "typechange" }

-- Parses `git status --porcelain=v2 -z --branch --untracked-files=all`.
-- Result: { branch, oid, upstream, ahead, behind, staged = {entry}, changes = {entry}, conflicts = {entry} }
-- entry: { path, orig?, letter = "M"|"A"|"D"|"R"|"C"|"U"|"T", kind }
local function parse_status(out)
  local s = { ahead = 0, behind = 0, staged = {}, changes = {}, conflicts = {} }
  local fields, i = vim.split(out, "\0", { plain = true }), 1
  while i <= #fields do
    local f = fields[i]
    local head, val = f:match("^# branch%.(%S+) (.*)$")
    if head == "head" then s.branch = val ~= "(detached)" and val or nil
    elseif head == "oid" then s.oid = val
    elseif head == "upstream" then s.upstream = val
    elseif head == "ab" then s.ahead, s.behind = tonumber(val:match("%+(%d+)")), tonumber(val:match("%-(%d+)")) end
    local kind = f:sub(1, 1)
    if kind == "1" or kind == "2" then
      local xy, path = f:match("^%d (..) %S+ %S+ %S+ %S+ %S+ %S+ " .. (kind == "2" and "%S+ " or "") .. "(.*)$")
      local orig = kind == "2" and fields[i + 1] or nil
      if kind == "2" then i = i + 1 end
      local x, y = xy:sub(1, 1), xy:sub(2, 2)
      if x ~= "." then table.insert(s.staged, { path = path, orig = orig, letter = x, kind = xy_kind[x] }) end
      if y ~= "." then table.insert(s.changes, { path = path, letter = y, kind = xy_kind[y] }) end
    elseif kind == "u" then
      table.insert(s.conflicts, { path = f:match("^u %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$"), letter = "!", kind = "conflict" })
    elseif kind == "?" then
      table.insert(s.changes, { path = f:sub(3), letter = "U", kind = "untracked" })
    end
    i = i + 1
  end
  return s
end

function M.status(root, cb)
  M.run({ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all" }, root, function(ok, out, err)
    cb(ok and parse_status(out) or nil, err)
  end)
end

-- File content at a revision: rev = "HEAD", "" (index, i.e. `:path`), or any commit-ish. cb(text|nil).
function M.show(root, rev, path, cb)
  M.run({ "show", rev .. ":" .. path }, root, function(ok, out) cb(ok and out or nil) end)
end

-- M.show without text mode, so CRLF line endings come back exactly as stored. cb(bytes|nil).
function M.show_raw(root, rev, path, cb)
  M.run({ "show", rev .. ":" .. path }, root, function(ok, out) cb(ok and out or nil) end, { binary = true })
end

return M
