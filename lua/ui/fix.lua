-- Quick fix, VS Code style: a `◆ fix` hint on the cursor line, <leader>. to apply or pick one
-- (diff preview), fix-all, and Codex or the attached agent when the servers offer no fix.
local M = {}
local pick = require("ui.pick")
local ns = vim.api.nvim_create_namespace("ui.fix")
local cns = vim.api.nvim_create_namespace("ui.fix.codex")
local pns = vim.api.nvim_create_namespace("ui.fix.preview")
local METHOD = "textDocument/codeAction"
local KEY = "⎵."
local DELAY, WAIT_MS, FIX_ALL_CAP, CODEX_TIMEOUT, SPAN = 150, 1500, 40, 30000, 40
local CODEX_INSTRUCTIONS = table.concat({
  "You fix code diagnostics. You get a file path, its filetype, the diagnostics and numbered source lines.",
  "Reply with ONLY one JSON object, no prose, no markdown fences:",
  '{"start": <first line number to replace>, "end": <last line number to replace>, "lines": [<the replacement lines>]}.',
  "start and end are inclusive, 1-based and inside the numbered lines; lines carry no line numbers and keep exact indentation.",
  'Change as little as possible. If you cannot fix it, reply {"error": "<short reason>"}. Never use tools.',
}, " ")

local hint, codex_job = { timer = vim.uv.new_timer(), gen = 0 }, nil

local function rel(path) return vim.fn.fnamemodify(path, ":~:.") end
local function trunc(s, n) return #s > n and (vim.fn.strcharpart(s, 0, n - 1) .. "…") or s end
local function codex_ok() return vim.fn.executable("codex") == 1 end

-- Diagnostics and requests -------------------------------------------------------------------

local function line_diags(buf, first, last)
  local out = vim.tbl_filter(function(d) return d.lnum <= last and (d.end_lnum or d.lnum) >= first end, vim.diagnostic.get(buf))
  table.sort(out, function(a, b) return a.lnum < b.lnum end)
  return out
end

local function covers(d, row, col)
  local er, ec = d.end_lnum or d.lnum, d.end_col or d.col
  if er == d.lnum then ec = math.max(ec, d.col + 1) end
  return (d.lnum < row or d.lnum == row and d.col <= col) and (row < er or row == er and col < ec)
end

-- The diagnostics under the cursor when it sits on one (`at`), else the cursor line's.
local function at_cursor(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local diags = line_diags(buf, row - 1, row - 1)
  local at = vim.tbl_filter(function(d) return covers(d, row - 1, col) end, diags)
  local key = table.concat(vim.tbl_map(function(d) return d.lnum .. ":" .. d.col .. ":" .. tostring(d.end_col) end, at), ",")
  return { row = row - 1, diags = #at > 0 and at or diags, at = #at > 0, key = key }
end

-- The LSP form of the diagnostics `client` published (push or pull namespaces).
local function owned(client, diags)
  local prefix, out = ("nvim.lsp.%s.%d"):format(client.name, client.id), {}
  for _, d in ipairs(diags) do
    local name = vim.diagnostic.get_namespace(d.namespace).name
    local mine = name == prefix or vim.startswith(name, prefix .. ".")
    if mine and d.user_data and d.user_data.lsp then out[#out + 1] = d.user_data.lsp end
  end
  return out
end

local function is_quick(a) return type(a.kind) == "string" and (a.kind == "quickfix" or vim.startswith(a.kind, "quickfix.")) end

local function suppress(e)
  local t = e.action.title:lower()
  return t:find("disable") or t:find("ignore") or t:find("noqa") or t:find("suppress")
end

local function fixes(entries) return vim.tbl_filter(function(e) return e.quick and not suppress(e) end, entries) end

local function collect(buf, results, tick)
  local out = {}
  for id, r in pairs(results) do
    local client = vim.lsp.get_client_by_id(id)
    for _, a in ipairs(client and r.result or {}) do
      if not a.disabled then out[#out + 1] = { action = a, client = client, buf = buf, tick = tick, quick = is_quick(a), preferred = a.isPreferred == true, n = #out } end
    end
  end
  table.sort(out, function(a, b)
    if a.quick ~= b.quick then return a.quick end
    if a.preferred ~= b.preferred then return a.preferred end
    return a.n < b.n
  end)
  return out
end

local function line_range(buf, first, last, enc)
  local text = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  return { start = { line = first, character = 0 }, ["end"] = { line = last, character = vim.lsp.util.character_offset(buf, last, #text, enc) } }
end

local function range_params(buf, opts, enc)
  if opts.cursor then return vim.lsp.util.make_range_params(0, enc) end
  if opts.pos then return vim.lsp.util.make_given_range_params(opts.pos[1], opts.pos[2], buf, enc) end
  return { textDocument = vim.lsp.util.make_text_document_params(buf), range = line_range(buf, opts.first, opts.last, enc) }
end

-- Code actions from every client for rows first..last (0-based), the charwise selection
-- (`opts.pos`) or the cursor (`opts.cursor`). Returns the cancel function of the request.
local function request(buf, opts, cb)
  if #vim.lsp.get_clients({ bufnr = buf, method = METHOD }) == 0 then return cb({}) end
  local diags, tick = opts.diags or line_diags(buf, opts.first, opts.last), vim.b[buf].changedtick
  return vim.lsp.buf_request_all(buf, METHOD, function(client)
    local p = range_params(buf, opts, client.offset_encoding)
    p.context = { diagnostics = owned(client, diags), only = opts.only, triggerKind = opts.trigger or 1 }
    return p
  end, function(results) cb(collect(buf, results, tick)) end)
end

-- Resolving and applying ---------------------------------------------------------------------

local function resolve(e, cb)
  local a = e.action
  if e.resolved or type(a.command) == "string" or a.edit or not e.client:supports_method("codeAction/resolve") then return cb(e.resolved or a) end
  e.client:request("codeAction/resolve", a, function(err, res)
    e.resolved = (not err and res) or a
    cb(e.resolved)
  end, e.buf)
end

-- A server command may edit through workspace/applyEdit; wait for its reply (or WAIT_MS).
local function run_command(e, cmd, tick, done)
  local finished = false
  local function finish()
    if finished then return end
    finished = true
    done(vim.api.nvim_buf_is_valid(e.buf) and vim.b[e.buf].changedtick ~= tick)
  end
  e.client:exec_cmd(cmd, { bufnr = e.buf }, function() vim.schedule(finish) end)
  vim.defer_fn(finish, WAIT_MS)
end

-- Apply the edit, then the command; done(changed, stale). `join` folds it into the previous undo
-- block. An edit computed before the buffer last changed is refused: servers that send version 0
-- (ts_ls) skip apply_workspace_edit's own check.
local function apply(e, done, join)
  done = done or function() end
  resolve(e, function(a)
    local tick = vim.b[e.buf].changedtick
    if e.tick ~= tick then
      if not join then vim.notify("! buffer changed since the fixes were listed · try again", vim.log.levels.WARN) end
      return done(false, true)
    end
    if join then pcall(vim.api.nvim_buf_call, e.buf, function() vim.cmd("silent! undojoin") end) end
    if a.edit then vim.lsp.util.apply_workspace_edit(a.edit, e.client.offset_encoding) end
    local cmd = type(a.command) == "table" and a.command or type(a.command) == "string" and a or nil
    if cmd then return run_command(e, cmd, tick, done) end
    done(vim.b[e.buf].changedtick ~= tick)
  end)
end

-- Diff preview -------------------------------------------------------------------------------

local function byte_col(line, character, enc)
  if enc == "utf-8" then return math.min(character, #line) end
  local ok, col = pcall(vim.str_byteindex, line, enc, character, false)
  return ok and col or #line
end

-- `lines` with the TextEdits applied, as one string; positions count in `enc`.
local function edited(lines, edits, enc)
  local text, starts, off = table.concat(lines, "\n") .. "\n", {}, 0
  for i, l in ipairs(lines) do starts[i], off = off, off + #l + 1 end
  local function offset(pos)
    local l = lines[pos.line + 1]
    return l and starts[pos.line + 1] + byte_col(l, pos.character, enc) or #text
  end
  local list = {}
  for i, e in ipairs(edits) do
    list[i] = { s = offset(e.range.start), e = offset(e.range["end"]), t = e.newText or (e.snippet and e.snippet.value) or "", i = i }
  end
  table.sort(list, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    return a.i > b.i
  end)
  for _, e in ipairs(list) do text = text:sub(1, e.s) .. e.t .. text:sub(e.e + 1) end
  return (text:gsub("\n$", ""))
end

local function file_lines(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  end
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

-- Rows are { text, hl? }.
local function add_diff(rows, path, old, new)
  local diff = vim.text.diff(old .. "\n", new .. "\n", { ctxlen = 3 }) or ""
  rows[#rows + 1] = { "▾ " .. rel(path), "AosArg" }
  if diff == "" then rows[#rows + 1] = { "  ○ no change to this file", "AosDim" } end
  for l in diff:gmatch("[^\n]+") do
    local c = l:sub(1, 1)
    rows[#rows + 1] = { l, c == "+" and "Added" or c == "-" and "Removed" or c == "@" and "AosFaint" or nil }
  end
end

local function resource_row(c)
  local from = rel(vim.uri_to_fname(c.uri or c.oldUri))
  return { ("○ %s %s%s"):format(c.kind, from, c.newUri and (" → " .. rel(vim.uri_to_fname(c.newUri))) or ""), "AosRunning" }
end

local function edit_rows(edit, enc)
  local rows, files, order = {}, {}, {}
  local function add(uri, edits)
    local f = vim.uri_to_fname(uri)
    if not files[f] then files[f], order[#order + 1] = {}, f end
    vim.list_extend(files[f], edits)
  end
  for uri, edits in pairs(edit.changes or {}) do add(uri, edits) end
  for _, c in ipairs(edit.documentChanges or {}) do
    if c.textDocument then add(c.textDocument.uri, c.edits) else rows[#rows + 1] = resource_row(c) end
  end
  for _, f in ipairs(order) do
    local lines = file_lines(f)
    add_diff(rows, f, table.concat(lines, "\n"), edited(lines, files[f], enc))
  end
  return rows
end

local function action_rows(e, a)
  local rows = a.edit and edit_rows(a.edit, e.client.offset_encoding) or {}
  local cmd = type(a.command) == "table" and a.command.command or type(a.command) == "string" and a.command
  if cmd then rows[#rows + 1] = { "⎿ then runs " .. cmd .. " on " .. e.client.name, "AosDim" } end
  if #rows == 0 then rows[1] = { "○ no preview · the server applies it", "AosDim" } end
  return rows
end

local function draw(buf, rows)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(r) return r[1] end, rows))
  vim.api.nvim_buf_clear_namespace(buf, pns, 0, -1)
  for i, r in ipairs(rows) do
    if r[2] then vim.hl.range(buf, pns, r[2], { i - 1, 0 }, { i - 1, #r[1] }) end
  end
end

local function plain(win)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.wrap, wo.list, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, false, false, "no", "0", ""
end

local function draw_win(win, rows, title)
  draw(vim.api.nvim_win_get_buf(win), rows)
  plain(win)
  vim.api.nvim_win_set_config(win, { title = title, title_pos = "left" })
end

-- pick preview: the action's diff, resolved on first view. Items carry an index into `refs`,
-- because matchfuzzy converts items to Vimscript and an LSP client does not convert.
local function previewer(refs)
  local current
  return function(win, item)
    current = item
    if not item then return draw_win(win, {}, " preview ") end
    local e = refs[item.data.i]
    if e.rows then return draw_win(win, e.rows, " ❯ ask · " .. item.id .. " ") end
    draw_win(win, { { "◆ resolving…", "AosRunning" } }, " ❯ preview ")
    resolve(e, function(a)
      if current == item and vim.api.nvim_win_is_valid(win) then draw_win(win, action_rows(e, a), " ❯ preview · " .. e.client.name .. " ") end
    end)
  end
end

-- AI fallback --------------------------------------------------------------------------------

local function diag_text(d)
  local src = d.source and (" (" .. d.source .. (d.code and (" " .. d.code) or "") .. ")") or ""
  return d.message:gsub("\n", " ") .. src
end

local function codex_prompt(buf, row, diags)
  local lo, hi = math.max(1, row + 1 - SPAN), math.min(vim.api.nvim_buf_line_count(buf), row + 1 + SPAN)
  local numbered = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, lo - 1, hi, false)) do numbered[i] = ("%d: %s"):format(lo + i - 1, l) end
  local msgs = vim.tbl_map(function(d) return ("- line %d: %s"):format(d.lnum + 1, diag_text(d)) end, diags)
  local text = ("File: %s\nFiletype: %s\nDiagnostics:\n%s\n\nLines %d-%d:\n%s"):format(
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."), vim.bo[buf].filetype, table.concat(msgs, "\n"), lo, hi, table.concat(numbered, "\n"))
  return text, lo, hi
end

local function parse(reply, lo, hi)
  local ok, obj = pcall(vim.json.decode, (reply or ""):match("{.*}") or "", { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= "table" then return nil, "codex replied without the expected JSON" end
  if obj.error then return nil, "codex: " .. tostring(obj.error) end
  local s, e, lines = obj.start, obj["end"], obj.lines
  local ints = type(s) == "number" and type(e) == "number" and s % 1 == 0 and e % 1 == 0
  if not ints or type(lines) ~= "table" then return nil, "codex reply lacks integer start/end and lines" end
  if s < lo or e > hi or e < s - 1 then return nil, ("codex range %d-%d is outside lines %d-%d"):format(s, e, lo, hi) end
  if not vim.iter(lines):all(function(l) return type(l) == "string" end) then return nil, "codex lines are not all strings" end
  return { start = s, stop = e, lines = vim.iter(lines):map(function(l) return vim.split(l, "\r?\n") end):flatten():totable() }
end

local function codex_preview(buf, fix, tick)
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new = vim.list_slice(old, 1, fix.start - 1)
  vim.list_extend(new, fix.lines)
  vim.list_extend(new, vim.list_slice(old, fix.stop + 1))
  local rows = {}
  add_diff(rows, vim.api.nvim_buf_get_name(buf), table.concat(old, "\n"), table.concat(new, "\n"))
  local fbuf = vim.api.nvim_create_buf(false, true)
  draw(fbuf, rows)
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "cursor", row = 1, col = 0, width = math.min(100, vim.o.columns - 4), height = math.min(#rows, 20),
    title = " ❯ codex fix ", title_pos = "left", footer = { { " ⏎/a apply · q discard ", "AosFaint" } }, footer_pos = "left",
  })
  plain(win)
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  local function accept()
    close()
    if vim.b[buf].changedtick ~= tick then return vim.notify("! buffer changed since codex looked · fix discarded", vim.log.levels.WARN) end
    vim.api.nvim_buf_set_lines(buf, fix.start - 1, fix.stop, false, fix.lines)
    vim.notify("✓ fixed · codex")
  end
  for lhs, fn in pairs({ ["<CR>"] = accept, a = accept, q = close, ["<Esc>"] = close }) do
    vim.keymap.set("n", lhs, fn, { buffer = fbuf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = fbuf, once = true, callback = close })
end

-- Ask Codex for a fix of the diagnostics on `row`; ◆ shows while it works, <C-c> or moving on cancels.
function M.codex(buf, row, diags)
  diags = diags or line_diags(buf, row, row)
  if #diags == 0 then return vim.notify("○ no diagnostics on this line") end
  if codex_job then codex_job("○ codex fix replaced") end
  local text, lo, hi = codex_prompt(buf, row, diags)
  local tick, job, crow = vim.b[buf].changedtick, {}, vim.fn.line(".") - 1
  local group = vim.api.nvim_create_augroup("UiFixCodex", {})
  local timer = assert(vim.uv.new_timer())
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, cns, row, 0, { virt_text = { { "  ◆ codex fixing…", "AosRunning" }, { "  <C-c> cancel", "AosFaint" } }, virt_text_pos = "eol" })
  local function stop(msg, level)
    if job.done then return end
    job.done, codex_job = true, nil
    timer:close()
    vim.api.nvim_del_augroup_by_id(group)
    pcall(vim.api.nvim_buf_clear_namespace, buf, cns, 0, -1)
    pcall(vim.keymap.del, "n", "<C-c>", { buffer = buf })
    if msg then vim.notify(msg, level) end
  end
  local function cancel(msg, level)
    if job.cancel and not job.done then job.cancel() end
    stop(msg, level)
  end
  local function received(err, reply)
    if job.done then return end
    stop()
    if err then return vim.notify("✗ codex fix · " .. err, vim.log.levels.ERROR) end
    local fix, perr = parse(reply, lo, hi)
    if not fix then return vim.notify("✗ " .. perr, vim.log.levels.ERROR) end
    codex_preview(buf, fix, tick)
  end
  codex_job = cancel
  vim.keymap.set("n", "<C-c>", function() cancel("○ codex fix cancelled") end, { buffer = buf, nowait = true })
  timer:start(CODEX_TIMEOUT, 0, vim.schedule_wrap(function() cancel("✗ codex fix timed out after 30 s", vim.log.levels.ERROR) end))
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "TextChanged", "BufLeave" }, {
    group = group,
    callback = function(ev)
      if ev.event == "CursorMoved" and vim.api.nvim_get_current_buf() == buf and vim.fn.line(".") - 1 == crow then return end
      cancel("○ codex fix cancelled")
    end,
  })
  job.cancel = require("core.complete").ask(CODEX_INSTRUCTIONS, text, vim.schedule_wrap(received))
end

local function ask_agent(t, buf, diags)
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  local msgs = vim.tbl_map(function(d) return ("%s:%d: %s"):format(path, d.lnum + 1, diag_text(d)) end, diags)
  local last = math.max(unpack(vim.tbl_map(function(d) return d.end_lnum or d.lnum end, diags)))
  require("agent").send_task(t, buf, diags[1].lnum + 1, last + 1, "Fix " .. table.concat(msgs, "; "))
  vim.notify(("◆ asked %s to fix %s:%d"):format(t.kind, path, diags[1].lnum + 1))
end

-- `diags` sorted by line; Codex and the agent get exactly the diagnostics the preview lists.
local function ai_items(buf, diags)
  if #diags == 0 then return {} end
  local row = diags[1].lnum
  local rows = vim.tbl_map(function(d) return { ("%d: %s"):format(d.lnum + 1, diag_text(d)), "AosDim" } end, diags)
  table.insert(rows, 1, { "✦ sends these diagnostics with the code around them:", "AosSha" })
  local items = {}
  if codex_ok() then
    local item = { glyph = "✦", hl = "AosCodex", id = "codex", text = "Ask Codex to fix" }
    items[1] = { item = item, ref = { rows = rows, run = function() M.codex(buf, row, diags) end } }
  end
  local t = require("agent").attached()
  if t then
    local run = function() ask_agent(t, buf, diags) end
    local item = { glyph = "✦", hl = t.kind == "claude" and "AosClaude" or "AosCodex", id = t.kind, text = ("Ask %s to fix"):format(t.kind) }
    items[#items + 1] = { item = item, ref = { rows = rows, run = run } }
  end
  return items
end

-- Pickers ------------------------------------------------------------------------------------

local function choose(e)
  if e.run then return e.run() end
  apply(e, function(_, stale)
    if not stale then vim.notify("✓ " .. trunc(e.action.title, 80)) end
  end)
end

-- `ai_first` when the servers offer no fix: the AI items lead, as the hint promised.
local function open_picker(entries, extra, ai_first)
  local items, refs = {}, {}
  local function add(item, ref)
    refs[#refs + 1] = ref
    item.data = { i = #refs }
    items[#items + 1] = item
  end
  local function add_extra() for _, x in ipairs(extra) do add(x.item, x.ref) end end
  if ai_first then add_extra() end
  for _, e in ipairs(entries) do
    local glyph, hl = "▸", "AosDim"
    if e.quick then glyph, hl = e.preferred and "◆" or "○", e.preferred and "AosRunning" or "AosDim" end
    add({ glyph = glyph, hl = hl, id = e.client.name, text = (e.action.title:gsub("\n", " ")) }, e)
  end
  if not ai_first then add_extra() end
  if #items == 0 then return vim.notify("○ no code actions here") end
  pick.open({ title = "quick fix", items = items, preview = previewer(refs), on_choose = function(item) choose(refs[item.data.i]) end })
end

-- Request options for the cursor (the diagnostic under it, else its line) or the selection:
-- whole lines, or the exact range of a charwise one.
local function target(buf)
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    local c = at_cursor(buf)
    return { first = c.row, last = c.row, diags = c.diags, cursor = c.at or #c.diags == 0 }
  end
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  if a[2] > b[2] or a[2] == b[2] and a[3] > b[3] then a, b = b, a end
  local opts = { first = a[2] - 1, last = b[2] - 1, diags = line_diags(buf, a[2] - 1, b[2] - 1) }
  if mode == "v" then opts.pos = { { a[2], a[3] - 1 }, { b[2], math.min(b[3], #vim.fn.getline(b[2])) - 1 } } end
  return opts
end

-- `direct`: apply the one preferred (or only) real fix without asking; suppressions never count.
local function code_actions(direct)
  local buf = vim.api.nvim_get_current_buf()
  local opts = target(buf)
  request(buf, opts, function(entries)
    local quick = fixes(entries)
    local preferred = vim.tbl_filter(function(e) return e.preferred end, quick)
    local one = #preferred == 1 and preferred[1] or #quick == 1 and quick[1] or nil
    if not (direct and one) then return open_picker(entries, ai_items(buf, opts.diags), #quick == 0) end
    apply(one, function(_, stale)
      if not stale then vim.notify("✓ fixed · " .. trunc(one.action.title, 80)) end
    end)
  end)
end

function M.quick_fix() code_actions(true) end
function M.actions() code_actions(false) end

-- Fix all ------------------------------------------------------------------------------------

local function wait_diags(buf, cb)
  local fired = false
  local function go()
    if fired then return end
    fired = true
    vim.schedule(cb)
  end
  vim.api.nvim_create_autocmd("DiagnosticChanged", { buffer = buf, once = true, callback = go })
  vim.defer_fn(go, WAIT_MS)
end

local function ident(d) return table.concat({ tostring(d.source), tostring(d.code), d.message }, "\0") end

local function covered(buf, d)
  return table.concat(vim.api.nvim_buf_get_lines(buf, d.lnum, (d.end_lnum or d.lnum) + 1, false), "\n")
end

-- The lines each diagnostic sat on before any edit. rust-analyzer's flycheck (rustc, clippy) only
-- re-checks on save and republishes stale positions; such a diagnostic whose lines changed is skipped.
local function snapshot(buf)
  local seen = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    seen[ident(d)] = seen[ident(d)] or {}
    seen[ident(d)][covered(buf, d)] = true
  end
  return seen
end

local function next_diag(run)
  local diags = vim.diagnostic.get(run.buf)
  table.sort(diags, function(a, b) return a.lnum < b.lnum end)
  for _, d in ipairs(diags) do
    local text, id = covered(run.buf, d), ident(d)
    local fresh = not run.seen[id] or run.seen[id][text] or not (d.source == "rustc" or d.source == "clippy")
    local key = id .. "\0" .. text
    if d.user_data and d.user_data.lsp and fresh and not run.tried[key] then return d, key end
  end
end

-- A source.fixAll edit counts once per diagnostic it cleared.
local function finish(run)
  local n = run.n > 0 and math.max(run.n, run.before - #vim.diagnostic.get(run.buf)) or 0
  vim.notify(n > 0 and ("✓ %d fix%s applied"):format(n, n > 1 and "es" or "") or "○ nothing to fix")
end

local fix_next

local function after_fix(run)
  return function(changed)
    if not changed then return fix_next(run) end
    run.n = run.n + 1
    wait_diags(run.buf, function() fix_next(run) end)
  end
end

-- One remaining diagnostic at a time, re-requested after every edit because positions shift.
fix_next = function(run)
  local d, key = next_diag(run)
  if not d or run.steps >= FIX_ALL_CAP then return finish(run) end
  run.tried[key], run.steps = true, run.steps + 1
  request(run.buf, { first = d.lnum, last = d.end_lnum or d.lnum, diags = { d }, only = { "quickfix" } }, function(entries)
    local e = vim.iter(entries):find(function(x) return x.quick and x.preferred end)
    if not e then return fix_next(run) end
    apply(e, after_fix(run), run.n > 0)
  end)
end

local function fix_all_sources(run, queue)
  local e = table.remove(queue, 1)
  if not e and run.n == 0 then return fix_next(run) end
  if not e then return wait_diags(run.buf, function() fix_next(run) end) end
  apply(e, function(changed)
    if changed then run.n = run.n + 1 end
    fix_all_sources(run, queue)
  end, run.n > 0)
end

-- source.fixAll from every server that has one (ruff, eslint, ts), then preferred quickfixes.
function M.fix_all()
  local buf = vim.api.nvim_get_current_buf()
  local run = { buf = buf, n = 0, steps = 0, tried = {}, seen = snapshot(buf), before = #vim.diagnostic.get(buf) }
  local last = vim.api.nvim_buf_line_count(buf) - 1
  request(buf, { first = 0, last = last, only = { "source.fixAll" } }, function(entries)
    local queue, seen = {}, {}
    for _, e in ipairs(entries) do
      local fix_all = type(e.action.kind) == "string" and vim.startswith(e.action.kind, "source.fixAll")
      if fix_all and not seen[e.client.id] then queue[#queue + 1], seen[e.client.id] = e, true end
    end
    fix_all_sources(run, queue)
  end)
end

-- Lightbulb hint -----------------------------------------------------------------------------

local function eligible(buf)
  return vim.bo[buf].buftype == "" and not vim.b[buf].bigfile and #vim.lsp.get_clients({ bufnr = buf, method = METHOD }) > 0
end

local function clear_hint()
  hint.timer:stop()
  hint.gen = hint.gen + 1
  if hint.cancel then pcall(hint.cancel) end
  if hint.buf and vim.api.nvim_buf_is_valid(hint.buf) then vim.api.nvim_buf_clear_namespace(hint.buf, ns, 0, -1) end
  hint.cancel, hint.buf, hint.last = nil, nil, nil
end

local function footer()
  local win, last = hint.float, hint.last
  if not (win and vim.api.nvim_win_is_valid(win) and last and last.count > 0) then return end
  local text = (" %s quick fix · %d available "):format(KEY, last.count)
  vim.api.nvim_win_set_config(win, { footer = { { text, "AosFaint" } }, footer_pos = "left" })
end

local function show_hint(spot, entries)
  local quick = fixes(entries)
  local best = vim.iter(quick):find(function(e) return e.preferred end) or quick[1]
  local chunks
  if best then
    chunks = { { "  ◆ " .. trunc((best.action.title:gsub("\n", " ")), 60), "AosRunning" } }
    if #quick > 1 then chunks[2] = { " +" .. (#quick - 1), "AosDim" } end
  elseif codex_ok() and vim.iter(spot.diags):any(function(d) return d.severity <= vim.diagnostic.severity.WARN end) then
    chunks = { { "  ◆ ask codex to fix", "AosRunning" } }
  end
  hint.last = vim.tbl_extend("force", spot, { count = #quick })
  if not chunks then return end
  chunks[#chunks + 1] = { "  " .. KEY, "AosFaint" }
  vim.api.nvim__ns_set(ns, { wins = { vim.api.nvim_get_current_win() } })
  -- Below vim.diagnostic's default 4096, so the hint sits right after the code, before the message.
  vim.api.nvim_buf_set_extmark(spot.buf, ns, spot.row, 0, { virt_text = chunks, virt_text_pos = "eol", hl_mode = "combine", priority = 4000 })
  footer()
end

-- Still on the same buffer state, line and diagnostic under the cursor as `spot`.
local function here(spot)
  local buf = spot.buf
  if vim.api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= "n" or vim.b[buf].changedtick ~= spot.tick then return false end
  local c = at_cursor(buf)
  return c.row == spot.row and c.key == spot.key
end

local function probe()
  local buf = vim.api.nvim_get_current_buf()
  if codex_job or vim.fn.mode() ~= "n" or not eligible(buf) then return end
  local c = at_cursor(buf)
  if #c.diags == 0 then return end
  local spot, gen = { buf = buf, row = c.row, key = c.key, tick = vim.b[buf].changedtick, diags = c.diags }, hint.gen
  hint.buf = buf
  local opts = { first = c.row, last = c.row, diags = c.diags, cursor = c.at, only = { "quickfix" }, trigger = 2 }
  hint.cancel = request(buf, opts, function(entries)
    if gen ~= hint.gen then return end
    hint.cancel = nil
    if here(spot) then show_hint(spot, entries) end
  end)
end

local function schedule()
  clear_hint()
  hint.timer:start(DELAY, 0, vim.schedule_wrap(probe))
end

-- The diagnostics float (]d/[d) gets a `⎵. quick fix · n available` footer once fixes are known.
function M.float(win)
  hint.float = win
  local last = hint.last
  if last and here(last) then return footer() end
  schedule()
end

-- Wiring -------------------------------------------------------------------------------------

function M.attach(buf)
  local function map(modes, lhs, fn, desc) vim.keymap.set(modes, lhs, fn, { buffer = buf, desc = desc, nowait = true }) end
  map({ "n", "v" }, "<leader>.", M.quick_fix, "Quick fix")
  map({ "n", "v" }, "<C-.>", M.quick_fix, "Quick fix")
  map({ "n", "v" }, "<leader>ca", M.actions, "Code action")
  map("n", "<leader>cf", M.fix_all, "Fix all in file")
end

function M.setup()
  local group = vim.api.nvim_create_augroup("UiFix", {})
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local last = hint.last
      if not (last and here(last)) then schedule() end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChanged", "BufLeave" }, { group = group, callback = function() clear_hint() end })
  vim.api.nvim_create_autocmd({ "DiagnosticChanged", "InsertLeave" }, {
    group = group,
    callback = function(ev)
      if ev.buf == vim.api.nvim_get_current_buf() and vim.fn.mode() == "n" then schedule() end
    end,
  })
end

return M
