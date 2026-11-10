-- How nvim reaches an agent: a WezTerm pane (attach to a running session) or an
-- embedded terminal (pipe: the agent runs inside nvim). Both take the same calls.
local M = {}

local spinner_claude = { "◐", "◑", "◒", "◓" }
local EVENTS = vim.fn.expand("~/.local/state/wezterm-agent-dashboard/events.jsonl")
local TAIL = 256 * 1024
local busy = { running = "running", tool_active = "running", waiting = "waiting", blocked = "waiting", idle = "idle", completed = "idle", failed = "failed" }

local function wezterm(args, cb)
  return vim.system(vim.list_extend({ "wezterm", "cli" }, args), { text = true }, cb and vim.schedule_wrap(cb))
end

function M.available() return vim.env.WEZTERM_PANE ~= nil and vim.fn.executable("wezterm") == 1 end

-- Harness and a guessed state from the pane title (Agent OS's heuristic fallback).
function M.classify(title)
  local t = title or ""
  local lower = t:lower()
  for _, mark in ipairs(spinner_claude) do
    if vim.startswith(t, mark) then return "claude", "running" end
  end
  if vim.startswith(t, "✳") or lower:find("claude", 1, true) then return "claude", "idle" end
  local spinning = t:match("^%s*[\226][\160-\163][\128-\191]") ~= nil
  if lower:find("codex", 1, true) or spinning then return "codex", spinning and "running" or "idle" end
end

-- Observed state per mux pane: the newest main-session line in Agent OS's events log,
-- read from its tail and cached by size+mtime.
local cache = { key = nil, states = {} }
local function observed()
  local stat = vim.uv.fs_stat(EVENTS)
  if not stat then return {} end
  local key = stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec
  if cache.key == key then return cache.states end
  local fd = vim.uv.fs_open(EVENTS, "r", 438)
  if not fd then return cache.states end
  local chunk = vim.uv.fs_read(fd, math.min(TAIL, stat.size), math.max(stat.size - TAIL, 0)) or ""
  vim.uv.fs_close(fd)
  local states = {}
  for line in chunk:gmatch("[^\n]+") do
    local ok, ev = pcall(vim.json.decode, line)
    if ok and type(ev) == "table" and ev.event == "state.changed" and ev.agent_id == nil and busy[ev.state] then
      states[ev.pane] = { state = busy[ev.state], agent = ev.agent }
    end
  end
  cache.key, cache.states = key, states
  return states
end

-- Panes whose title says nothing (Claude shows its version before the first prompt): ask ps.
local function by_process(ttys)
  if #ttys == 0 then return {} end
  local r = vim.system({ "ps", "-o", "tty=,comm=", "-t", table.concat(ttys, ",") }, { text = true }):wait(1000)
  local kinds = {}
  for tty, comm in (r.stdout or ""):gmatch("(%S+)%s+(%S+)") do
    local kind = comm:match("^claude") and "claude" or comm:match("^codex") and "codex"
    if kind then kinds["/dev/" .. tty] = kind end
  end
  return kinds
end

local function from_uri(uri) return (uri or ""):gsub("^file://[^/]*", ""):gsub("/$", "") end

local function identify(list)
  local events, unknown = observed(), {}
  for _, p in ipairs(list) do
    p.kind, p.state = M.classify(p.title)
    local seen = events[p.pane_id]
    if seen then p.kind, p.state, p.observed = p.kind or seen.agent, seen.state, true end
    if not p.kind and p.tty_name then unknown[#unknown + 1] = p.tty_name:gsub("^/dev/", "") end
  end
  local procs = by_process(unknown)
  for _, p in ipairs(list) do p.kind = p.kind or procs[p.tty_name] end
end

-- Agent panes, the ones sharing nvim's working directory first. Agent OS's own pane never counts.
function M.panes(cb)
  wezterm({ "list", "--format", "json" }, function(r)
    if r.code ~= 0 then return cb({}, vim.trim(r.stderr or "wezterm cli failed")) end
    local ok, list = pcall(vim.json.decode, r.stdout)
    if not ok then return cb({}, "unreadable wezterm cli list output") end
    identify(list)
    local cwd, out = vim.fn.getcwd(), {}
    for _, p in ipairs(list) do
      local mine = tostring(p.pane_id) == vim.env.WEZTERM_PANE or p.title == "wezterm-agent-dashboard"
      if p.kind and not mine then
        local dir = from_uri(p.cwd)
        out[#out + 1] = {
          kind = p.kind, state = p.state or "idle", observed = p.observed, pane = p.pane_id, title = p.title, cwd = dir,
          near = vim.startswith(cwd, dir) or vim.startswith(dir, cwd),
        }
      end
    end
    table.sort(out, function(a, b)
      if a.near ~= b.near then return a.near end
      return a.pane < b.pane
    end)
    cb(out)
  end)
end

-- Refresh one target's state in place: observed event first, else the title guess.
function M.poll(target, cb)
  if target.chan then return cb(target) end
  wezterm({ "list", "--format", "json" }, function(r)
    local ok, list = pcall(vim.json.decode, r.stdout or "")
    local found = ok and r.code == 0 and vim.iter(list):find(function(p) return p.pane_id == target.pane end)
    if not found then
      target.state = "gone"
      return cb(target)
    end
    local seen = observed()[target.pane]
    target.title, target.observed = found.title, seen ~= nil
    target.state = seen and seen.state or select(2, M.classify(found.title)) or target.state
    cb(target)
  end)
end

-- Paste as one bracketed block (keeps newlines inside the agent's input), then press Enter.
function M.send(target, text, submit)
  if target.chan then
    vim.api.nvim_chan_send(target.chan, "\27[200~" .. text .. "\27[201~")
    if submit then vim.defer_fn(function() pcall(vim.api.nvim_chan_send, target.chan, "\r") end, 120) end
    return
  end
  -- An Enter now would answer the agent's permission or plan prompt instead.
  if submit and target.state == "waiting" then
    submit = false
    vim.notify("! " .. target.kind .. " is waiting on a prompt: pasted without Enter", vim.log.levels.WARN)
  end
  local pane = tostring(target.pane)
  wezterm({ "send-text", "--pane-id", pane, "--", text }, function(r)
    if r.code ~= 0 then return vim.notify("✗ agent: " .. vim.trim(r.stderr), vim.log.levels.ERROR) end
    if not submit then return end
    vim.defer_fn(function() wezterm({ "send-text", "--pane-id", pane, "--no-paste", "\r" }) end, 150)
  end)
end

function M.capture(target, cb)
  if target.chan then
    local lines = vim.api.nvim_buf_get_lines(target.buf, 0, -1, false)
    return cb(lines)
  end
  wezterm({ "get-text", "--pane-id", tostring(target.pane) }, function(r)
    cb(r.code == 0 and vim.split(r.stdout, "\n", { plain = true }) or { "✗ " .. vim.trim(r.stderr or "pane unavailable") })
  end)
end

function M.focus(target)
  if target.chan then
    local win = vim.fn.bufwinid(target.buf)
    if win ~= -1 then vim.api.nvim_set_current_win(win) end
    return
  end
  wezterm({ "activate-pane", "--pane-id", tostring(target.pane) })
end

-- Pipe mode: start the agent CLI in a right split owned by this nvim.
function M.spawn(kind)
  vim.cmd("botright vsplit")
  vim.api.nvim_win_set_width(0, math.floor(vim.o.columns * 0.4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local target = { kind = kind, buf = buf, state = "idle" }
  target.chan = vim.fn.jobstart({ kind }, {
    term = true,
    cwd = vim.fn.getcwd(),
    on_exit = function() target.state = "gone" end,
  })
  vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn = false, false, "no"
  vim.cmd.wincmd("p")
  return target
end

return M
