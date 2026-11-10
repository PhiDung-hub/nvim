-- Branch picker like VS Code's status-bar branch menu: create, local, remote and tag refs; choosing checks out.
local M = {}
local repo = require("git.repo")
local pick = require("ui.pick")

M.click_target = "v:lua.AosGitBranchClick"
M.TAG = "\u{f412}"

-- The picker's keys come from ui.pick; its fuzzy filter matches branch names only.
M.keys = {
  {
    section = "Branch picker",
    keys = {
      { "<CR>", "check out (asks stash · carry over · cancel when local changes block it)" },
      { "<Down>", "next" },
      { "<C-n>", "next" },
      { "<Up>", "previous" },
      { "<C-p>", "previous" },
      { "<Esc>", "close" },
      { "<C-c>", "close" },
    },
  },
}

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

local function done(root, msg, cb)
  vim.notify("✓ " .. msg)
  changed(root)
  if cb then cb() end
end

-- `switch` never reads its argument as a pathspec, unlike `checkout <name>` for a branch that no longer exists.
local function switch_args(t)
  if t.kind == "local" then return { "switch", "-q", "--no-guess", t.name } end
  if t.kind == "remote" then return { "switch", "-q", "--track", t.name } end
  return { "switch", "-q", "--detach", t.kind == "tag" and "refs/tags/" .. t.name or t.name }
end

local function label(t)
  if t.kind == "detached" then return t.name:sub(1, 7) .. " (detached)" end
  if t.kind == "tag" then return "tag " .. t.name .. " (detached)" end
  return t.name
end

local function message(t)
  if t.short then return ("checked out %s · new local branch tracking %s"):format(t.short, t.name) end
  if t.remote then return ("checked out %s · existing local branch of %s"):format(t.name, t.remote) end
  return "checked out " .. label(t)
end

-- cb(true) when tracked or untracked files differ from HEAD.
function M.dirty(root, cb)
  repo.run({ "status", "--porcelain" }, root, function(ok, out) cb(ok and out ~= "") end, { feature = "checkout" })
end

local function unstash(root)
  repo.run({ "stash", "pop", "--index" }, root, function(ok, _, err)
    if not ok then fail("stash pop (your changes stay in the stash)", err) end
    changed(root)
  end)
end

local function carry(root, msg, cb)
  repo.run({ "stash", "pop" }, root, function(ok, _, err)
    if ok then return done(root, msg .. " · changes carried over", cb) end
    vim.notify(("! %s · carried changes conflict: resolve them, the stash is kept\n%s"):format(msg, vim.trim(err)), vim.log.levels.WARN)
    changed(root)
  end)
end

-- Like VS Code's Stash & Checkout (`migrate` false) and Migrate Changes (true); a switch that still fails puts
-- the stash back where it came from.
local function stashed(root, t, msg, migrate, cb)
  repo.run(switch_args(t), root, function(ok, _, err)
    if not ok then
      fail("checkout", err)
      return unstash(root)
    end
    if migrate then return carry(root, msg, cb) end
    done(root, msg .. " · changes stashed (git stash pop brings them back)", cb)
  end)
end

local function stash_switch(root, t, msg, migrate, cb)
  repo.run({ "stash", "push", "--include-untracked", "-m", "before checkout " .. label(t) }, root, function(ok, _, err)
    if not ok then return fail("stash", err) end
    stashed(root, t, msg, migrate, cb)
  end)
end

local function blocked(root, t, msg, err, cb)
  local why = table.concat(vim.list_slice(vim.split(vim.trim(err), "\n", { plain = true }), 1, 8), "\n")
  local choice = vim.fn.confirm(("Local changes block checking out %s\n%s"):format(label(t), why), "&Stash && checkout\nCarry &over changes\n&Cancel", 3)
  if choice == 1 or choice == 2 then stash_switch(root, t, msg, choice == 2, cb) end
end

local function switch(root, t, cb)
  repo.run(switch_args(t), root, function(ok, _, err)
    if ok then return done(root, message(t), cb) end
    M.dirty(root, function(dirty)
      if not dirty then return fail("checkout", err) end
      blocked(root, t, message(t), err, cb)
    end)
  end)
end

-- A remote checks out its existing local branch, else creates a tracking one (t.short).
local function resolve(root, target, cb)
  local short = target.kind == "remote" and target.name:match("^[^/]+/(.+)$")
  if not short then return cb(target) end
  repo.run({ "show-ref", "--verify", "-q", "refs/heads/" .. short }, root, function(exists)
    cb(exists and { kind = "local", name = short, remote = target.name } or { kind = "remote", name = target.name, short = short })
  end, { feature = "checkout" })
end

-- cb(true) when HEAD already is the target, so a switch would change nothing.
local function already(root, t, cb)
  if t.short then return cb(false) end
  local rev = t.kind == "local" and "refs/heads/" .. t.name or t.kind == "tag" and "refs/tags/" .. t.name or t.name
  repo.run({ "rev-parse", "HEAD", rev .. "^{commit}", "--symbolic-full-name", "HEAD" }, root, function(ok, out)
    local head, sha, ref = unpack(vim.split(vim.trim(out), "\n", { plain = true }))
    if t.kind == "local" then return cb(ok and ref == "refs/heads/" .. t.name) end
    cb(ok and ref == "HEAD" and head == sha)
  end, { feature = "checkout" })
end

-- target = { kind = "local"|"remote"|"tag"|"detached", name }.
function M.checkout(root, target, cb)
  resolve(root, target, function(t)
    already(root, t, function(yes)
      if yes then return vim.notify("○ already on " .. label(t)) end
      switch(root, t, cb)
    end)
  end)
end

function M.create(name, from, root, cb)
  root = root or M.root()
  name = vim.trim(name or ""):gsub("%s+", "-")
  if name == "" then return end
  repo.run({ "switch", "-q", "-c", name, from }, root, function(ok, _, err)
    if not ok then return fail("branch", err) end
    done(root, "created " .. name .. (from and " from " .. from or ""), cb)
  end)
end

local function track(s)
  if s == "gone" then return "  gone" end
  local ahead, behind = s:match("ahead (%d+)"), s:match("behind (%d+)")
  if not (ahead or behind) then return "" end
  return ("  ↑%s ↓%s"):format(ahead or 0, behind or 0)
end

-- Rows read `glyph · date ↑↓ · name`: only the name is the item's text, so only names are fuzzy-matched.
local function ref_item(line)
  local ref, sha, upstream, date, head = unpack(vim.split(line, "\0", { plain = true }))
  local name = ref:match("^refs/heads/(.+)$")
  if name then
    local glyph, hl = head == "*" and "●" or "○", head == "*" and "AosDone" or "AosDim"
    return { glyph = glyph, hl = hl, id = date .. track(upstream), text = name, data = { kind = "local", name = name, sha = sha, head = head == "*" } }
  end
  name = ref:match("^refs/tags/(.+)$")
  if name then return { glyph = M.TAG, hl = "AosRunning", id = date, text = name, data = { kind = "tag", name = name, sha = sha } } end
  name = ref:match("^refs/remotes/(.+)$")
  if name and not name:match("/HEAD$") then
    return { glyph = "⇄", hl = "AosSha", id = date, text = name, data = { kind = "remote", name = name, sha = sha } }
  end
end

local function pad_ids(items)
  local w = vim.iter(items):fold(0, function(m, i) return math.max(m, vim.api.nvim_strwidth(i.id)) end)
  for _, i in ipairs(items) do i.id = i.id .. (" "):rep(w - vim.api.nvim_strwidth(i.id)) end
  return items
end

-- cb(items) ordered local, remote, tags; a detached HEAD leads as its own row.
local function refs(root, cb)
  local args = { "for-each-ref", "--sort=-committerdate", "--format=" .. FORMAT, "refs/heads", "refs/remotes", "refs/tags" }
  repo.run(args, root, function(ok, out, err, slow)
    if slow then return vim.api.nvim_echo({ { "○ branch list paused · slow repo", "AosDim" } }, false, {}) end
    if not ok then return fail("for-each-ref", err) end
    local groups = { ["local"] = {}, remote = {}, tag = {} }
    for line in out:gmatch("[^\n]+") do
      local item = ref_item(line)
      if item then table.insert(groups[item.data.kind], item) end
    end
    cb(pad_ids(vim.list_extend(vim.list_extend(groups["local"], groups.remote), groups.tag)))
  end, { feature = "branch picker" })
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
  if d.action then return end
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
    repo.run({ "rev-parse", "--short", "HEAD" }, root, function(ok, out) open(root, items, ok and vim.trim(out) or nil) end, { feature = "branch picker" })
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
