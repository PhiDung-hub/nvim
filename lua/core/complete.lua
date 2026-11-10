-- AI ghost-text completion. As you type, a local Qwen2.5-Coder 0.5B (llama-server /infill,
-- ~350 ms) suggests; GitHub Copilot Free answers when the local server is missing or failing.
-- Codex (a `codex app-server` on the ChatGPT login, seconds per answer) runs only on <M-]>.
local M = {}
local ns = vim.api.nvim_create_namespace("core.complete")
local function model() return vim.g.complete_codex_model or "gpt-6-luna" end
local EFFORT = "low"
local COPILOT_DELAY, CODEX_DELAY, CODEX_BACKOFF = 200, 600, 5 * 60 * 1000
local LOCAL_DELAY, LOCAL_TOKENS, LOCAL_BUDGET_MS, LOCAL_BEFORE, LOCAL_AFTER = 100, 24, 700, 60, 20
local LLAMA = vim.fn.expand("~/.local/share/llama")
local BEFORE, AFTER = 120, 60
local INSTRUCTIONS = "You are a code completion engine. Output ONLY the code that belongs at <CURSOR>: "
  .. "no prose, no markdown fences, no explanation, never repeat the prefix or the suffix. Never use tools. "
  .. "If nothing fits, output nothing."

M.mode = "auto"
local shown, timers, codex = nil, {}, { pending = {}, threads = {}, id = 0, inflight = nil, down_until = 0, queue = {}, asks = {} }
local llm = { port = 18080, job = nil, req = nil }

-- Rendering ---------------------------------------------------------------------------------

local function clear()
  if shown and vim.api.nvim_buf_is_valid(shown.buf) then vim.api.nvim_buf_clear_namespace(shown.buf, ns, 0, -1) end
  shown = nil
end

local function context()
  local buf, pos = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  return { buf = buf, row = pos[1] - 1, col = pos[2], tick = vim.b[buf].changedtick, line = vim.api.nvim_get_current_line() }
end

local function still(ctx)
  if vim.fn.mode() ~= "i" or vim.api.nvim_get_current_buf() ~= ctx.buf then return false end
  local pos = vim.api.nvim_win_get_cursor(0)
  return vim.b[ctx.buf].changedtick == ctx.tick and pos[1] - 1 == ctx.row and pos[2] == ctx.col
end

local source_hl = { codex = "AosId", ["local"] = "AosDone", copilot = "AosDim" }
local rank = { copilot = 1, ["local"] = 2, codex = 3 }

local function show(ctx, text, source, item)
  if not still(ctx) or text == "" then return end
  if shown and rank[shown.source] > rank[source] then return end
  clear()
  local lines = vim.split(text, "\n", { plain = true })
  local tag = { " ● " .. source, source_hl[source] }
  local opts = { virt_text = { { lines[1], "AosGhost" } }, virt_text_pos = "inline", hl_mode = "combine" }
  if #lines == 1 then table.insert(opts.virt_text, tag) end
  if #lines > 1 then
    opts.virt_lines = vim.tbl_map(function(l) return { { l, "AosGhost" } } end, vim.list_slice(lines, 2))
    table.insert(opts.virt_lines[#opts.virt_lines], tag)
  end
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, ctx.row, ctx.col, opts)
  shown = { buf = ctx.buf, ctx = ctx, text = text, source = source, item = item }
end

-- Drop what the model repeated: indentation already typed and a closing line the suffix holds.
-- Fill-in-the-middle output (`fim`) starts exactly at the cursor, so only the tail is trimmed.
local function tidy(ctx, text, suffix_line, fim)
  local before = ctx.line:sub(1, ctx.col)
  if not fim then
    text = text:gsub("^```%w*\n", ""):gsub("\n```%s*$", "")
    if before:match("^%s*$") then text = text:gsub("^[ \t]+", "") end
    if vim.startswith(text, vim.trim(before)) and vim.trim(before) ~= "" then text = text:sub(#vim.trim(before) + 1) end
  end
  local lines = vim.split(text:gsub("%s+$", ""), "\n", { plain = true })
  if #lines > 1 and suffix_line and vim.trim(lines[#lines]) == vim.trim(suffix_line) then table.remove(lines) end
  return table.concat(lines, "\n")
end

-- Copilot ------------------------------------------------------------------------------------

local function copilot_client(buf) return vim.lsp.get_clients({ bufnr = buf, name = "copilot" })[1] end

local function copilot_item(ctx, item)
  local text = type(item.insertText) == "table" and item.insertText.value or item.insertText or ""
  local start = item.range and item.range.start.character or ctx.col
  local typed = ctx.line:sub(start + 1, ctx.col)
  if not vim.startswith(text, typed) then return nil end
  return text:sub(#typed + 1)
end

local function copilot(ctx)
  local client = copilot_client(ctx.buf)
  if not client then return end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { triggerKind = 2 }
  client:request("textDocument/inlineCompletion", params, function(err, result)
    if err or not result then return end
    local item = (result.items or result)[1]
    local text = item and copilot_item(ctx, item)
    if text then show(ctx, tidy(ctx, text), "copilot", item) end
  end, ctx.buf)
end

-- Text around the cursor: prefix, suffix and the next non-blank line below.
local function around(ctx, before, after)
  local above = vim.api.nvim_buf_get_lines(ctx.buf, math.max(ctx.row - before, 0), ctx.row, false)
  local below = vim.api.nvim_buf_get_lines(ctx.buf, ctx.row + 1, ctx.row + 1 + after, false)
  local prefix = table.concat(above, "\n") .. (#above > 0 and "\n" or "") .. ctx.line:sub(1, ctx.col)
  local suffix = ctx.line:sub(ctx.col + 1) .. "\n" .. table.concat(below, "\n")
  return prefix, suffix, vim.iter(below):find(function(l) return vim.trim(l) ~= "" end)
end

-- Local llama-server (one per machine on a fixed port; any nvim may own it) -------------------

local function llm_paths()
  return vim.g.complete_local_bin or LLAMA .. "/bin/llama-server", vim.g.complete_local_model or LLAMA .. "/qwen2.5-coder-0.5b-q8_0.gguf"
end

local function llm_installed()
  local bin, model_path = llm_paths()
  return vim.fn.executable(bin) == 1 and vim.uv.fs_stat(model_path) ~= nil
end

-- A second nvim's server fails to bind and exits; requests then reach the first one.
local function llm_start()
  if llm.job or not llm_installed() then return end
  local bin, model_path = llm_paths()
  local threads = tostring(math.min(6, #vim.uv.cpu_info()))
  llm.job = vim.fn.jobstart({
    bin, "-m", model_path, "--host", "127.0.0.1", "--port", tostring(llm.port), "-c", "4096", "-np", "1",
    "-t", threads, "-tb", threads, "--cache-reuse", "256", "--log-disable",
  }, { on_exit = function() llm.job = nil end })
  if llm.job <= 0 then llm.job = nil end
end

local function llm_cancel()
  if llm.req then llm.req:kill(9) end
  llm.req = nil
end

local function local_request(ctx)
  if not llm_installed() then return copilot(ctx) end
  llm_cancel()
  local prefix, suffix, next_line = around(ctx, LOCAL_BEFORE, LOCAL_AFTER)
  local body = vim.json.encode({
    input_prefix = prefix, input_suffix = suffix, n_predict = LOCAL_TOKENS, temperature = 0,
    cache_prompt = true, t_max_predict_ms = LOCAL_BUDGET_MS, stop = { "\n\n" },
  })
  local url = ("http://127.0.0.1:%d/infill"):format(llm.port)
  local req
  req = vim.system({ "curl", "-sS", "--max-time", "3", "-H", "Content-Type: application/json", "--data-binary", "@-", url },
    { stdin = body, text = true }, vim.schedule_wrap(function(r)
      if llm.req == req then llm.req = nil end
      if r.signal ~= 0 then return end
      if r.code ~= 0 then
        llm_start()
        return copilot(ctx)
      end
      local ok, res = pcall(vim.json.decode, r.stdout)
      if not ok or type(res) ~= "table" or res.error then return copilot(ctx) end
      local text = res.content or ""
      if res.stop_type == "limit" and text:find("\n") then text = text:gsub("\n[^\n]*$", "") end
      show(ctx, tidy(ctx, text, next_line, true), "local")
    end))
  llm.req = req
end

-- Codex app-server (JSON lines over stdio) ----------------------------------------------------

local function rpc(method, params, cb)
  codex.id = codex.id + 1
  codex.pending[codex.id] = cb
  vim.fn.chansend(codex.job, vim.json.encode({ jsonrpc = "2.0", id = codex.id, method = method, params = params }) .. "\n")
end

-- A one-off M.ask turn: collect its reply, or its error.
local function on_ask(ask, msg)
  local p = msg.params or {}
  if msg.method == "item/completed" and p.item and p.item.type == "agentMessage" then ask.text = p.item.text or "" end
  if msg.method == "error" then ask.err = p.error and p.error.message or vim.inspect(p) end
  if msg.method ~= "turn/completed" then return end
  codex.asks[p.threadId] = nil
  pcall(rpc, "thread/unsubscribe", { threadId = p.threadId }, function() end)
  ask.cb(ask.err or (ask.text == nil and "codex sent no reply" or nil), ask.text)
end

local function on_notification(msg)
  local p = msg.params or {}
  if codex.asks[p.threadId] then return on_ask(codex.asks[p.threadId], msg) end
  local turn = codex.inflight
  if msg.method == "error" and turn and p.threadId == turn.thread then
    codex.down_until = vim.uv.now() + CODEX_BACKOFF
    vim.notify("! codex completion paused 5 min: " .. vim.inspect(p.error and p.error.message or p), vim.log.levels.WARN)
  end
  if not turn or p.threadId ~= turn.thread then return end
  if msg.method == "item/completed" and p.item and p.item.type == "agentMessage" then turn.text = p.item.text or "" end
  if msg.method ~= "turn/completed" then return end
  codex.inflight = nil
  pcall(rpc, "thread/unsubscribe", { threadId = turn.thread }, function() end)
  vim.cmd.redrawtabline()
  if turn.text and turn.text ~= "" then show(turn.ctx, tidy(turn.ctx, turn.text, turn.suffix_line), "codex") end
end

local function on_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  if msg.id and msg.method then
    -- A server request (approval etc.): this client never grants anything.
    return vim.fn.chansend(codex.job, vim.json.encode({ jsonrpc = "2.0", id = msg.id, result = { decision = "decline" } }) .. "\n")
  end
  if msg.id then
    local cb = codex.pending[msg.id]
    codex.pending[msg.id] = nil
    if cb then cb(msg.error, msg.result) end
    return
  end
  on_notification(msg)
end

local function warm_thread()
  rpc("thread/start", {
    model = model(), ephemeral = true, baseInstructions = INSTRUCTIONS, sandbox = "read-only", approvalPolicy = "never",
    cwd = vim.fn.getcwd(),
  }, function(err, res)
    if err or not res then
      codex.down_until = vim.uv.now() + CODEX_BACKOFF
      return
    end
    table.insert(codex.threads, res.thread.id)
    local waiting = codex.waiting
    codex.waiting = nil
    if waiting and still(waiting) then M.codex_request(waiting) end
  end)
end

local function codex_start()
  if codex.job or vim.fn.executable("codex") == 0 then return end
  local partial = ""
  codex.job = vim.fn.jobstart({ "codex", "app-server" }, {
    cwd = vim.fn.getcwd(),
    stdout_buffered = false,
    on_stdout = function(_, data)
      data[1] = partial .. data[1]
      partial = table.remove(data)
      for _, line in ipairs(data) do
        if line ~= "" then on_line(line) end
      end
    end,
    on_exit = function()
      for _, ask in pairs(codex.asks) do ask.cb("codex app-server exited") end
      for _, go in ipairs(codex.queue) do go("codex app-server exited") end
      codex.job, codex.threads, codex.inflight, codex.ready, codex.asks, codex.queue = nil, {}, nil, false, {}, {}
    end,
  })
  if codex.job <= 0 then
    codex.job = nil
    return
  end
  rpc("initialize", { clientInfo = { name = "nvim-complete", version = "0.1" } }, function(err)
    if err then return end
    vim.fn.chansend(codex.job, vim.json.encode({ jsonrpc = "2.0", method = "initialized" }) .. "\n")
    codex.ready = true
    for _, go in ipairs(codex.queue) do go() end
    codex.queue = {}
    warm_thread()
  end)
end

local function codex_cancel()
  local turn = codex.inflight
  if not turn then return end
  codex.inflight = nil
  if turn.id then pcall(rpc, "turn/interrupt", { threadId = turn.thread, turnId = turn.id }, function() end) end
  vim.cmd.redrawtabline()
end

local function prompt(ctx)
  local prefix, suffix, next_line = around(ctx, BEFORE, AFTER)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":.")
  return ("File: %s (%s)\n<PREFIX>%s<CURSOR><SUFFIX>%s</SUFFIX>"):format(name, vim.bo[ctx.buf].filetype, prefix, suffix), next_line
end

function M.codex_request(ctx)
  if vim.uv.now() < codex.down_until then return end
  codex_start()
  local thread = table.remove(codex.threads, 1)
  if not thread then
    codex.waiting = ctx
    return
  end
  codex_cancel()
  local text, next_line = prompt(ctx)
  local turn = { thread = thread, ctx = ctx, suffix_line = next_line }
  codex.inflight = turn
  vim.cmd.redrawtabline()
  rpc("turn/start", { threadId = thread, input = { { type = "text", text = text } }, effort = EFFORT }, function(err, res)
    if err then
      codex.inflight, codex.down_until = nil, vim.uv.now() + CODEX_BACKOFF
      return vim.notify("! codex completion paused 5 min: " .. (err.message or "error"), vim.log.levels.WARN)
    end
    turn.id = res and res.turn and res.turn.id
  end)
  warm_thread()
end

local function ask_turn(state, text, cb)
  codex.asks[state.thread] = { cb = cb }
  rpc("turn/start", { threadId = state.thread, input = { { type = "text", text = text } }, effort = EFFORT }, function(err, res)
    if not err then
      state.turn = res and res.turn and res.turn.id
      return
    end
    codex.asks[state.thread] = nil
    cb(err.message or "turn/start failed")
  end)
end

local function ask_thread(state, instructions, text, cb)
  local params = {
    model = model(), ephemeral = true, baseInstructions = instructions, sandbox = "read-only", approvalPolicy = "never",
    cwd = vim.fn.getcwd(),
  }
  rpc("thread/start", params, function(err, res)
    if err or not res then return cb(err and err.message or "thread/start failed") end
    if state.cancelled then return end
    state.thread = res.thread.id
    ask_turn(state, text, cb)
  end)
end

-- One read-only Codex turn on its own thread: cb(err, reply). Returns a cancel function.
function M.ask(instructions, text, cb)
  if vim.fn.executable("codex") == 0 then
    cb("codex is not installed")
    return function() end
  end
  local state = { cancelled = false }
  local function go(err)
    if state.cancelled then return end
    if err then return cb(err) end
    rpc("account/read", {}, function(aerr, acc)
      if aerr or (acc and acc.requiresOpenaiAuth and not acc.account) then return cb("codex is logged out · run `codex login`") end
      if not state.cancelled then ask_thread(state, instructions, text, cb) end
    end)
  end
  codex_start()
  if not codex.job then
    cb("codex app-server did not start")
    return function() end
  end
  if codex.ready then go() else table.insert(codex.queue, go) end
  return function()
    state.cancelled = true
    if not state.thread then return end
    codex.asks[state.thread] = nil
    if state.turn then pcall(rpc, "turn/interrupt", { threadId = state.thread, turnId = state.turn }, function() end) end
  end
end

-- Triggers and keys ---------------------------------------------------------------------------

local function eligible(buf)
  return M.mode ~= "off" and vim.bo[buf].buftype == "" and not vim.b[buf].bigfile and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function schedule(name, delay, fn)
  timers[name] = timers[name] or vim.uv.new_timer()
  timers[name]:start(delay, 0, vim.schedule_wrap(function()
    local ctx = context()
    if vim.fn.mode() == "i" and eligible(ctx.buf) then fn(ctx) end
  end))
end

local function on_change()
  clear()
  codex_cancel()
  llm_cancel()
  if not eligible(vim.api.nvim_get_current_buf()) then return end
  if M.mode == "auto" then schedule("local", LOCAL_DELAY, local_request) end
  if M.mode == "copilot" then schedule("copilot", COPILOT_DELAY, copilot) end
  local codex_live = vim.uv.now() >= codex.down_until and vim.fn.executable("codex") == 1
  if M.mode == "codex" and codex_live then schedule("codex", CODEX_DELAY, M.codex_request) end
end

function M.accept()
  if not shown or not still(shown.ctx) then return false end
  local s = shown
  clear()
  local lines = vim.split(s.text, "\n", { plain = true })
  local row, col = s.ctx.row, s.ctx.col
  vim.api.nvim_buf_set_text(s.buf, row, col, row, col, lines)
  local last = row + #lines - 1
  vim.api.nvim_win_set_cursor(0, { last + 1, (#lines == 1 and col or 0) + #lines[#lines] })
  local client = s.source == "copilot" and copilot_client(s.buf)
  if client and s.item and s.item.command then client:exec_cmd(s.item.command, { bufnr = s.buf }) end
  return true
end

function M.segment()
  if codex.inflight then return { hl = "AosSegBlue", text = "◆ codex" } end
  if M.mode == "codex" and vim.uv.now() < codex.down_until then return { hl = "AosSegYellow", text = "! codex paused" } end
  if M.mode == "auto" and not llm_installed() then return { hl = "AosSegYellow", text = "! local missing · copilot" } end
end

function M.setup()
  vim.api.nvim_set_hl(0, "AosGhost", { fg = require("design").dim, italic = true })
  local group = vim.api.nvim_create_augroup("CoreComplete", {})
  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI", "CursorMovedI" }, { group = group, callback = on_change })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function()
      clear()
      codex_cancel()
      llm_cancel()
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, once = true, callback = llm_start })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if codex.job then vim.fn.jobstop(codex.job) end
      if llm.job then vim.fn.jobstop(llm.job) end
    end,
  })

  vim.keymap.set("i", "<Tab>", function()
    if not M.accept() then vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "n", false) end
  end, { desc = "Accept AI suggestion" })
  vim.keymap.set("i", "<M-]>", function() codex.down_until = 0 M.codex_request(context()) end, { desc = "Ask Codex now" })
  vim.keymap.set("i", "<C-]>", clear, { desc = "Dismiss AI suggestion" })

  vim.api.nvim_create_user_command("Complete", function(o)
    local mode = o.fargs[1]
    if mode then M.mode, codex.down_until = mode, 0 end
    clear()
    local copilot_on = #vim.lsp.get_clients({ name = "copilot" }) > 0
    local local_state = not llm_installed() and "missing" or llm.job and "running here" or "shared/idle"
    vim.notify(("● complete %s · local %s · codex %s · copilot %s"):format(M.mode, local_state, codex.job and "running" or "idle", copilot_on and "attached" or "not attached"))
  end, { nargs = "?", complete = function() return { "auto", "codex", "copilot", "off" } end })
end

return M
