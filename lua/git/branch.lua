-- Branch picker like VS Code's status-bar branch menu: create, local, remote and tag refs; choosing checks out.
local M = {}
local repo = require("git.repo")
local pick = require("ui.pick")

M.click_target = "v:lua.AosGitBranchClick"
M.TAG = "\u{f412}"

local FORMAT = "%(refname)%00%(objectname:short)%00%(upstream:track,nobracket)%00%(committerdate:relative)%00%(HEAD)"

-- Git root for the current buffer (a git view's own root, the file's repo, else the cwd's).
function M.root()
  if vim.b.git_root then return vim.b.git_root end
  local name = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  return name ~= "" and repo.root(name) or repo.root()
end

local function fail(verb, err)
  vim.notify(("✗ git %s\n%s"):format(verb, vim.trim(err)), vim.log.levels.ERROR)
end

-- Checkout rewrites files and HEAD outside nvim's view; FocusGained runs the checktime and branch-cache reset
-- that an external change would trigger.
local function changed(root)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  vim.api.nvim_exec_autocmds("User", { pattern = "GitChanged", data = { root = root } })
end

local function run(root, verb, args, done_msg, cb)
  repo.run(args, root, function(ok, _, err)
    if not ok then return fail(verb, err) end
    vim.notify("✓ " .. done_msg)
    changed(root)
    if cb then cb() end
  end)
end

-- target = { kind = "local"|"remote"|"tag"|"detached", name }; a remote creates a local tracking branch.
function M.checkout(root, target, cb)
  local args = { "checkout", "-q" }
  if target.kind == "remote" then vim.list_extend(args, { "--track", target.name })
  elseif target.kind == "tag" then vim.list_extend(args, { "--detach", "refs/tags/" .. target.name })
  elseif target.kind == "detached" then vim.list_extend(args, { "--detach", target.name })
  else args[#args + 1] = target.name end
  run(root, "checkout", args, "checked out " .. target.name, cb)
end

function M.create(name, from, root, cb)
  root = root or M.root()
  name = vim.trim(name or ""):gsub("%s+", "-")
  if name == "" then return end
  run(root, "branch", { "checkout", "-q", "-b", name, from }, "created " .. name .. (from and " from " .. from or ""), cb)
end

-- cb(true) when tracked files differ from HEAD.
function M.dirty(root, cb)
  repo.run({ "status", "--porcelain", "--untracked-files=no" }, root, function(ok, out) cb(ok and out ~= "") end)
end

local function track(s)
  if s == "gone" then return " · gone" end
  local ahead, behind = s:match("ahead (%d+)"), s:match("behind (%d+)")
  if not (ahead or behind) then return "" end
  return (" · ↑%s ↓%s"):format(ahead or 0, behind or 0)
end

local function ref_item(line)
  local ref, sha, upstream, date, head = unpack(vim.split(line, "\0", { plain = true }))
  local name = ref:match("^refs/heads/(.+)$")
  if name then
    local glyph, hl = head == "*" and "●" or "○", head == "*" and "AosDone" or "AosDim"
    return { glyph = glyph, hl = hl, text = name .. track(upstream) .. " · " .. date, data = { kind = "local", name = name, sha = sha, head = head == "*" } }
  end
  name = ref:match("^refs/tags/(.+)$")
  if name then return { glyph = M.TAG, hl = "AosRunning", text = name .. " · " .. date, data = { kind = "tag", name = name, sha = sha } } end
  name = ref:match("^refs/remotes/(.+)$")
  if name and not name:match("/HEAD$") then
    return { glyph = "⇄", hl = "AosSha", text = name .. " · " .. date, data = { kind = "remote", name = name, sha = sha } }
  end
end

-- cb(items) ordered local, remote, tags; a detached HEAD leads as its own row.
local function refs(root, cb)
  local args = { "for-each-ref", "--sort=-committerdate", "--format=" .. FORMAT, "refs/heads", "refs/remotes", "refs/tags" }
  repo.run(args, root, function(ok, out, err)
    if not ok then return fail("for-each-ref", err) end
    local groups = { ["local"] = {}, remote = {}, tag = {} }
    for line in out:gmatch("[^\n]+") do
      local item = ref_item(line)
      if item then table.insert(groups[item.data.kind], item) end
    end
    cb(vim.list_extend(vim.list_extend(groups["local"], groups.remote), groups.tag))
  end)
end

local function ask_name(from, root)
  vim.ui.input({ prompt = from and ("Branch name (from " .. from .. "): ") or "Branch name: " }, function(name)
    if name then M.create(name, from, root) end
  end)
end

local function pick_from(items, root)
  pick.open({ title = "create branch from", items = items, on_choose = function(item) ask_name(item.data.name, root) end })
end

local function choose(item, items, root)
  local d = item.data
  if d.action == "create" then return ask_name(nil, root) end
  if d.action == "from" then return pick_from(items, root) end
  if d.kind == "remote" then
    local name = d.name:match("^[^/]+/(.+)$")
    local existing = vim.iter(items):find(function(i) return i.data.kind == "local" and i.data.name == name end)
    d = existing and existing.data or d
  end
  if d.head or d.action then return end
  M.checkout(root, d)
end

local function open(root, items, head)
  local top = {
    { glyph = "＋", hl = "AosDone", text = "Create new branch…", data = { action = "create" } },
    { glyph = "＋", hl = "AosDone", text = "Create new branch from…", data = { action = "from" } },
  }
  if head then top[3] = { glyph = "●", hl = "AosDone", text = "HEAD detached at " .. head, data = { action = "none" } } end
  pick.open({ title = "checkout", items = vim.list_extend(top, items), on_choose = function(item) choose(item, items, root) end })
end

function M.pick(root)
  root = root or M.root()
  if not root then return vim.notify("✗ not a git repository", vim.log.levels.WARN) end
  refs(root, function(items)
    if vim.iter(items):any(function(i) return i.data.head end) then return open(root, items) end
    repo.run({ "rev-parse", "--short", "HEAD" }, root, function(ok, out) open(root, items, ok and vim.trim(out) or nil) end)
  end)
end

function _G.AosGitBranchClick() M.pick() end

function M.setup()
  vim.keymap.set("n", "<leader>gb", function() M.pick() end, { desc = "Git branch picker" })
  vim.api.nvim_create_user_command("GitBranch", function(o)
    if o.args ~= "" then return M.create(o.args) end
    M.pick()
  end, { nargs = "?", desc = "Git branch picker; with a name, create and check it out" })
end

return M
