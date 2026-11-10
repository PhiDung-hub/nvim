-- Co-work with a running Claude Code / Codex session from nvim: attach to its WezTerm pane
-- (or start one in a split), ask about a selection with /btw, hand it a task or the
-- `@agent` comments in the code, watch its screen, and review its edits as hunks.
local M = {}
local transport = require("agent.transport")
local review = require("agent.review")
local g = require("design").glyphs
local ns = vim.api.nvim_create_namespace("agent.tasks")
local MAX_INLINE = 150
local MARKER = "@agent"
local SCAN_MS = 3000
local repo = require("git.repo")

local target, tasks = nil, {}

M.keys = {
  {
    section = "Agent prompt",
    keys = {
      { "<CR>", "send to the agent", "n i" },
      { "<Esc>", "cancel", "n i" },
    },
  },
}
local state_glyph = { running = g.running, waiting = g.question, idle = g.done, failed = g.failed, gone = g.failed }
local state_hl = { running = "AosRunning", waiting = "AosRunning", idle = "AosDone", failed = "AosFailed", gone = "AosFailed" }

function M.label() return target and target.kind or "agent" end

function M.segments()
  local out = {}
  if target then
    local open = 0
    for _, list in pairs(tasks) do open = open + #list end
    local where = target.chan and "split" or "#" .. target.pane
    local text = ("%s %s %s"):format(state_glyph[target.state] or g.todo, target.kind, where)
    if open > 0 then text = text .. (" · %d task%s"):format(open, open > 1 and "s" or "") end
    local hl = (target.state == "gone" or target.state == "failed") and "AosSegRed" or target.state == "waiting" and "AosSegYellow"
      or target.kind == "claude" and "AosSegMagenta" or "AosSegBlue"
    out[#out + 1] = { hl = hl, text = text }
  end
  local hunks = review.total()
  if hunks > 0 then out[#out + 1] = { hl = "AosSegYellow", text = ("%s %d hunk%s"):format(g.attention, hunks, hunks > 1 and "s" or "") } end
  return out
end

-- Target ---------------------------------------------------------------------------------

local poller = vim.uv.new_timer()
local function start_polling()
  poller:start(0, 2000, vim.schedule_wrap(function()
    if not target then return poller:stop() end
    transport.poll(target, function() vim.cmd.redrawtabline() end)
    -- Agents write files in the background; reload every unchanged visible buffer.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then pcall(vim.cmd.checktime, buf) end
    end
  end))
end

local function set_target(t)
  target = t
  start_polling()
  vim.notify(("%s attached %s %s"):format(g.done, t.kind, t.chan and "(split)" or "#" .. t.pane))
  vim.cmd.redrawtabline()
end

function M.attach(cb)
  local function choose(item)
    local t = item.data.spawn and transport.spawn(item.data.spawn) or item.data
    set_target(t)
    if cb then vim.defer_fn(function() cb(t) end, t.chan and 1500 or 0) end
  end
  local function open(panes, err)
    local items = {}
    for _, p in ipairs(panes) do
      items[#items + 1] = {
        glyph = state_glyph[p.state] or g.todo, hl = state_hl[p.state], id = "#" .. p.pane, data = p,
        text = ("%s%s · %s · %s"):format(p.kind, p.observed and "" or " (guess)", p.title, vim.fn.fnamemodify(p.cwd, ":~")),
      }
    end
    for _, kind in ipairs({ "claude", "codex" }) do
      if vim.fn.executable(kind) == 1 then
        items[#items + 1] = { glyph = "+", hl = "AosPrompt", id = kind, text = "start in a split here", data = { spawn = kind } }
      end
    end
    if err then vim.notify("! wezterm: " .. err, vim.log.levels.WARN) end
    require("ui.pick").open({ title = "attach agent", items = items, on_choose = choose })
  end
  if transport.available() then return transport.panes(open) end
  open({})
end

local function with_target(cb)
  if target and target.state ~= "gone" then return cb(target) end
  M.attach(cb)
end

-- Context ----------------------------------------------------------------------------------

local function selection()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    local l = vim.fn.line(".")
    return l, l
  end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return math.min(a, b), math.max(a, b)
end

local function context(buf, first, last)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  local ref = first == last and ("@%s#L%d"):format(path, first) or ("@%s#L%d-%d"):format(path, first, last)
  if last - first + 1 > MAX_INLINE then return ref end
  local code = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  return ("%s\n```%s\n%s\n```"):format(ref, vim.bo[buf].filetype, table.concat(code, "\n"))
end

-- One-line prompt float: ` ❯ btw · claude #4 `.
local function input(title, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].completion = false
  local width = math.min(90, vim.o.columns - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = 1,
    title = (" ❯ %s · %s "):format(title, M.label()), title_pos = "left",
  })
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, "no"
  local function close() pcall(vim.api.nvim_win_close, win, true) vim.cmd.stopinsert() end
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    local text = vim.trim(vim.api.nvim_get_current_line())
    close()
    if text ~= "" then vim.schedule(function() cb(text) end) end
  end, { buffer = buf })
  vim.keymap.set({ "i", "n" }, "<Esc>", close, { buffer = buf, nowait = true })
  vim.cmd.startinsert()
end

-- Actions ----------------------------------------------------------------------------------

function M.ask(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not first then first, last = selection() end
  input("btw", function(question)
    with_target(function(t)
      local lead = t.kind == "claude" and "/btw " or "Side question, answer only, do not edit files: "
      transport.send(t, lead .. question .. "\n\n" .. context(buf, first, last), true)
    end)
  end)
end

local function annotate(buf, row, text, hl)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_lines = { { { "  " .. text, hl } } }, virt_lines_above = true, invalidate = true,
  })
end

function M.attached() return target and target.state ~= "gone" and target or nil end

-- Hand `t` a task on lines first..last of buf, annotated until its edit lands.
function M.send_task(t, buf, first, last, instruction)
  transport.send(t, instruction .. "\n\nWork on this code, edit the file in place:\n" .. context(buf, first, last), true)
  tasks[buf] = tasks[buf] or {}
  local label = ("%s %s · %s"):format(g.running, t.kind, instruction)
  table.insert(tasks[buf], { row = first - 1, text = instruction, mark = annotate(buf, first - 1, label, "AosAnnotation") })
  vim.cmd.redrawtabline()
end

function M.task(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not first then first, last = selection() end
  input("task", function(instruction)
    with_target(function(t) M.send_task(t, buf, first, last, instruction) end)
  end)
end

function M.add()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = selection()
  with_target(function(t) transport.send(t, context(buf, first, last) .. "\n", false) end)
end

-- `@agent` (or @claude/@codex) comments become one task list; the agent removes each marker.
local function buffer_items()
  local out, path = {}, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local lower = line:lower()
    if lower:find(MARKER, 1, true) or lower:find("@claude", 1, true) or lower:find("@codex", 1, true) then
      out[#out + 1] = ("%s:%d: %s"):format(path, i, vim.trim(line))
    end
  end
  return out
end

local function wide(dir) return dir == "/" or vim.startswith(vim.env.HOME .. "/", dir .. "/") end

-- The tree <leader>aC scans: the cwd's repo, else the cwd; never $HOME or an ancestor of it wholesale (then the buffer's repo, `narrowed`).
local function scan_root()
  local cwd = vim.fn.getcwd()
  local root = repo.root(cwd)
  if root and not wide(root) then return root end
  if not wide(cwd) then return cwd end
  local file = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  root = file ~= "" and repo.root(file) or nil
  if root and not wide(root) then return root, true end
end

local PATTERN = "(//|#|--|/\\*|<!--|;)\\s*@(agent|claude|codex)\\b"

local function nonempty(text) return vim.tbl_filter(function(l) return l ~= "" end, vim.split(text or "", "\n")) end

-- Async rg over the scan root, cut at SCAN_MS; cb(lines, cut). A cheap per-file count pass (one `path:n` line per
-- searched file, so a cut can say how far it got) finds the hits, then --vimgrep reads only those files.
local function project_items(cb)
  local root, narrowed = scan_root()
  local where = vim.fn.fnamemodify(vim.fn.getcwd(), ":~")
  if not root then return vim.notify(("%s cwd is %s · open a file in a repo to scan its @agent comments"):format(g.todo, where)) end
  vim.notify(("%s scanning %s for @agent comments…%s"):format(g.running, vim.fn.fnamemodify(root, ":~"),
    narrowed and (" (cwd is %s: only this buffer's repo)"):format(where) or ""))
  local scanned, hits, rest = 0, {}, ""
  local function count(_, data)
    rest = rest .. (data or "")
    for file, n in rest:gmatch("([^\n]*):(%d+)\n") do
      scanned = scanned + 1
      if n ~= "0" then hits[#hits + 1] = file end
    end
    rest = rest:match("[^\n]*$")
  end
  local args = { "rg", "--count", "--include-zero", "-i", "--max-filesize", "1M", "-e", PATTERN }
  if root ~= vim.fn.getcwd() then args[#args + 1] = root end
  vim.system(args, { text = true, timeout = SCAN_MS, stdout = count }, vim.schedule_wrap(function(r)
    local cut = r.code == 124
    if cut then vim.notify(("%s @agent scan cut off at %d s · %d files scanned"):format(g.todo, SCAN_MS / 1000, scanned), vim.log.levels.WARN) end
    if #hits == 0 then return cb({}, cut) end
    local grep = vim.list_extend({ "rg", "--vimgrep", "--no-heading", "-i", "-e", PATTERN, "--" }, hits)
    vim.system(grep, { text = true, timeout = SCAN_MS }, vim.schedule_wrap(function(m) cb(nonempty(m.stdout), cut) end))
  end))
end

local function send_comments(items, project, cut)
  if #items == 0 then
    if cut then return end
    return vim.notify(g.todo .. " no @agent comments " .. (project and "in the project" or "in this buffer"))
  end
  local body = "Do each request left as an @agent/@claude/@codex comment below, then delete that marker comment:\n- " .. table.concat(items, "\n- ")
  with_target(function(t)
    transport.send(t, body, true)
    vim.notify(("%s sent %d comment request%s to %s"):format(g.running, #items, #items > 1 and "s" or "", t.kind))
  end)
end

function M.comments(project)
  if not project then return send_comments(buffer_items(), false) end
  project_items(function(items, cut) send_comments(items, true, cut) end)
end

-- Review list: pending hunks first, then files git reports dirty (opened against the index).
local function changes_picker(items)
  require("ui.pick").open({
    title = "agent changes",
    items = items,
    on_choose = function(item)
      if item.data.bufnr then
        vim.api.nvim_set_current_buf(item.data.bufnr)
        return vim.api.nvim_win_set_cursor(0, { item.data.lnum, 0 })
      end
      vim.cmd.edit(vim.fn.fnameescape(item.data.file))
      review.seed_from_index(vim.api.nvim_get_current_buf(), function() review.jump(1) end)
    end,
  })
end

-- Paths come from the repo root and open from there; a cut or failed status still lists the pending hunks.
function M.changes()
  local items, root = review.items(), repo.root()
  repo.run({ "status", "--porcelain" }, root, function(_, out)
    for line in out:gmatch("[^\n]+") do
      local file = line:sub(4)
      items[#items + 1] = { glyph = "○", hl = "AosDim", id = line:sub(1, 2), text = file, data = { file = root and root .. "/" .. file or file } }
    end
    changes_picker(items)
  end, { feature = "agent changes" })
end

-- Called by review when an agent edit lands in `buf`: its open tasks there are done.
function M.on_change(buf, count)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  vim.notify(("%s %s edited %s · %d hunk%s · ]a next, <leader>ay keep, <leader>ar undo"):format(g.reply, M.label(), name, count, count > 1 and "s" or ""))
  for _, task in ipairs(tasks[buf] or {}) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, task.mark)
    local mark = annotate(buf, math.min(task.row, vim.api.nvim_buf_line_count(buf) - 1), ("%s %s · %s"):format(g.done, M.label(), task.text), "AosDone")
    vim.defer_fn(function() pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark) end, 8000)
  end
  tasks[buf] = nil
  vim.cmd.redrawtabline()
end

local function view()
  with_target(function(t) require("agent.view").toggle(t) end)
end

function M.setup()
  review.setup()
  local map = function(modes, lhs, fn, desc) vim.keymap.set(modes, lhs, fn, { desc = desc }) end
  map("n", "<leader>aa", function() M.attach() end, "Agent: attach")
  map({ "n", "v" }, "<leader>ab", function() M.ask() end, "Agent: /btw about selection")
  map({ "n", "v" }, "<leader>at", function() M.task() end, "Agent: task on selection")
  map("v", "<leader>ae", M.add, "Agent: add selection to prompt")
  map("n", "<leader>ac", function() M.comments(false) end, "Agent: send @agent comments (buffer)")
  map("n", "<leader>aC", function() M.comments(true) end, "Agent: send @agent comments (project)")
  map("n", "<leader>av", view, "Agent: live view")
  map("n", "<leader>af", function() with_target(transport.focus) end, "Agent: focus pane")
  map("n", "<leader>al", M.changes, "Agent: changes")
  map("n", "]a", function() review.jump(1) end, "Agent: next hunk")
  map("n", "[a", function() review.jump(-1) end, "Agent: prev hunk")
  map("n", "<leader>ay", function() review.accept() end, "Agent: keep hunk")
  map("n", "<leader>aY", function() review.accept_all() end, "Agent: keep all")
  map("n", "<leader>ar", function() review.revert() end, "Agent: undo hunk")
  map("n", "<leader>aR", function() review.revert_all() end, "Agent: undo all")

  vim.api.nvim_create_user_command("AgentAsk", function(o) M.ask(o.line1, o.line2) end, { range = true })
  vim.api.nvim_create_user_command("AgentTask", function(o) M.task(o.line1, o.line2) end, { range = true })
  vim.api.nvim_create_user_command("Agent", function(o)
    local sub, arg = o.fargs[1], o.fargs[2]
    if sub == "spawn" then return set_target(transport.spawn(arg or "claude")) end
    if sub == "detach" then
      target = nil
      return vim.cmd.redrawtabline()
    end
    local actions = { view = view, changes = M.changes, comments = function() M.comments(o.bang) end }
    return (actions[sub] or M.attach)()
  end, {
    nargs = "*", bang = true,
    complete = function(_, line)
      if line:match("spawn%s+%S*$") then return { "claude", "codex" } end
      return { "attach", "spawn", "view", "changes", "comments", "detach" }
    end,
  })
end

return M
