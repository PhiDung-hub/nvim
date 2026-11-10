-- Shared git layer: async runs, repo root, parsed status and file contents at a revision.
local M = {}

-- Runs `git -C cwd args…`; cb(ok, stdout, stderr) on the main loop. Returns the vim.SystemObj.
function M.run(args, cwd, cb, opts)
  opts = opts or {}
  local cmd = vim.list_extend({ "git", "-C", cwd or vim.fn.getcwd(), "--no-pager", "-c", "color.ui=never" }, args)
  return vim.system(cmd, { text = true, stdin = opts.stdin, env = { GIT_TERMINAL_PROMPT = "0", GIT_EDITOR = "true" } }, function(r)
    vim.schedule(function() cb(r.code == 0, r.stdout or "", r.stderr or "") end)
  end)
end

function M.run_sync(args, cwd)
  local cmd = vim.list_extend({ "git", "-C", cwd or vim.fn.getcwd(), "--no-pager", "-c", "color.ui=never" }, args)
  local r = vim.system(cmd, { text = true }):wait()
  return r.code == 0, r.stdout or "", r.stderr or ""
end

local roots = {}

-- Worktree root containing `path` (a file or directory; default cwd), or nil outside git.
function M.root(path)
  path = path and path ~= "" and vim.fs.normalize(path) or vim.fn.getcwd()
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  if roots[dir] == nil then
    local ok, out = M.run_sync({ "rev-parse", "--show-toplevel" }, dir)
    roots[dir] = ok and vim.trim(out) or false
  end
  return roots[dir] or nil
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
  local cmd = { "git", "-C", root, "--no-pager", "show", rev .. ":" .. path }
  vim.system(cmd, {}, function(r) vim.schedule(function() cb(r.code == 0 and (r.stdout or "") or nil) end) end)
end

return M
