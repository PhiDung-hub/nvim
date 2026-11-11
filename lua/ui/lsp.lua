-- LSP and syntax UI in the Agent OS look: hover, peek, finder, outline, breadcrumbs, rename,
-- call hierarchy, and an inspector for the highlight/treesitter state under the cursor.
local M = {}
local pick = require("ui.pick")
local ns = vim.api.nvim_create_namespace("ui.lsp")
local symbols, timers = {}, {}

M.keys = {
  {
    section = "Peek",
    keys = {
      { "<CR>", "open the definition in the original window" },
      { "q", "close" },
      { "<Esc>", "close" },
    },
  },
  {
    section = "Rename",
    keys = {
      { "<CR>", "apply the new name", "n i s" },
      { "<C-c>", "cancel", "n i s" },
      { "q", "cancel" },
      { "<Esc>", "cancel" },
    },
  },
  {
    section = "Outline",
    keys = {
      { "<CR>", "jump to the symbol" },
      { "o", "jump to the symbol" },
      { "q", "close" },
    },
  },
}

local kind_glyph = {
  File = "▣", Module = "▣", Namespace = "▣", Package = "▣",
  Class = "◇", Interface = "◇", Struct = "◇", Enum = "◇", TypeParameter = "◇",
  Method = "ƒ", Function = "ƒ", Constructor = "ƒ", Operator = "ƒ",
}
local kind_hl = {
  Class = "AosSha", Interface = "AosSha", Struct = "AosSha", Enum = "AosSha", TypeParameter = "AosSha",
  Method = "AosId", Function = "AosId", Constructor = "AosId", Module = "AosArg", Namespace = "AosArg", Package = "AosArg",
}
local function kind(k) return vim.lsp.protocol.SymbolKind[k] or "Symbol" end
local function glyph(k) return kind_glyph[kind(k)] or "·" end
local function rel(path) return vim.fn.fnamemodify(path, ":~:.") end
local function title(verb, rest) return (" ❯ %s%s "):format(verb, rest and (" · " .. rest) or "") end

local function client_for(buf, method)
  return vim.lsp.get_clients({ bufnr = buf, method = method })[1]
end

-- Hover and peek -----------------------------------------------------------------------------

local hover_ns = vim.api.nvim_create_namespace("aos.hover")

function M.hover()
  local params = function(client) return vim.lsp.util.make_position_params(0, client.offset_encoding) end
  vim.lsp.buf_request_all(0, "textDocument/hover", params, function(results)
    local lines = {}
    for _, r in pairs(results) do
      local contents = r.result and r.result.contents
      if contents then
        if #lines > 0 then lines[#lines + 1] = "***" end
        vim.list_extend(lines, vim.lsp.util.convert_input_to_markdown_lines(contents))
      end
    end
    lines = require("ui.markdown").doc(lines)
    if #lines == 0 then return vim.notify("○ no hover information", vim.log.levels.INFO) end
    local buf, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
      focus_id = "textDocument/hover", max_width = 90, max_height = 25, title = title("hover"), title_pos = "left",
    })
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l ~= "" and l:gsub("─", "") == "" then
        vim.api.nvim_buf_set_extmark(buf, hover_ns, i - 1, 0, { end_col = #l, hl_group = "Whitespace", priority = 250 })
      end
    end
    require("ui.markdown").paint_literals(buf)
    local wh = vim.wo[win].winhighlight
    vim.wo[win].winhighlight = (wh ~= "" and wh .. "," or "") .. "Search:None,CurSearch:None,IncSearch:None"
  end)
end

-- Editable float on the definition; <CR> opens it in the origin window, q closes.
function M.peek()
  local origin = vim.api.nvim_get_current_win()
  vim.lsp.buf.definition({
    on_list = function(res)
      local item = res.items[1]
      if not item then return vim.notify("○ no definition") end
      local buf = item.bufnr or vim.fn.bufadd(item.filename)
      vim.fn.bufload(buf)
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor", row = 1, col = 0, width = math.min(100, vim.o.columns - 4), height = 15,
        title = title("peek", ("%s:%d"):format(rel(item.filename), item.lnum)), title_pos = "left",
      })
      vim.wo[win].winbar, vim.wo[win].foldcolumn = "", "0"
      vim.api.nvim_win_set_cursor(win, { item.lnum, math.max(item.col - 1, 0) })
      vim.cmd("normal! zt")
      local function close() pcall(vim.api.nvim_win_close, win, true) end
      local function open()
        local pos = vim.api.nvim_win_get_cursor(win)
        close()
        vim.api.nvim_set_current_win(origin)
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_buf(origin, buf)
        vim.api.nvim_win_set_cursor(origin, pos)
      end
      local keys = { q = close, ["<Esc>"] = close, ["<CR>"] = open }
      for lhs, fn in pairs(keys) do vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
      vim.api.nvim_create_autocmd("WinLeave", { once = true, callback = function() if vim.api.nvim_get_current_win() == win then close() end end })
      vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win), once = true,
        callback = function()
          for lhs in pairs(keys) do pcall(vim.keymap.del, "n", lhs, { buffer = buf }) end
        end,
      })
    end,
  })
end

-- Finder: definitions, implementations and references in one previewed list -----------------

local finder_kinds = {
  { method = "textDocument/definition", glyph = "◆", hl = "AosDone", label = "def" },
  { method = "textDocument/implementation", glyph = "◇", hl = "AosSha", label = "impl" },
  { method = "textDocument/references", glyph = "●", hl = "AosDim", label = "ref", context = { includeDeclaration = false } },
}

local function locations(buf, spec, cb)
  if not client_for(buf, spec.method) then return cb({}) end
  local function params(client)
    local p = vim.lsp.util.make_position_params(0, client.offset_encoding)
    p.context = spec.context
    return p
  end
  vim.lsp.buf_request_all(buf, spec.method, params, function(results)
    local out = {}
    for id, r in pairs(results) do
      local client = vim.lsp.get_client_by_id(id)
      if r.result and client then
        local list = vim.islist(r.result) and r.result or { r.result }
        vim.list_extend(out, vim.lsp.util.locations_to_items(list, client.offset_encoding))
      end
    end
    cb(out)
  end)
end

function M.finder()
  local buf, word = vim.api.nvim_get_current_buf(), vim.fn.expand("<cword>")
  local items, seen, pending = {}, {}, #finder_kinds
  local rank = { def = 1, impl = 2, ref = 3 }
  local function finish()
    if #items == 0 then return vim.notify("○ nothing found for " .. word) end
    local counts = {}
    for _, it in ipairs(items) do counts[it.kind] = (counts[it.kind] or 0) + 1 end
    table.sort(items, function(a, b)
      if a.kind ~= b.kind then return rank[a.kind] < rank[b.kind] end
      return a.id < b.id
    end)
    local summary = vim.tbl_map(function(k) return ("%d %s"):format(counts[k.label] or 0, k.label) end, finder_kinds)
    pick.open({ title = ("finder · %s · %s"):format(word, table.concat(summary, " ")), items = items, on_choose = pick.jump, preview = true })
  end
  for _, spec in ipairs(finder_kinds) do
    locations(buf, spec, function(found)
      -- Requests finish in any order; a location keeps its strongest kind (def > impl > ref).
      for _, e in ipairs(found) do
        local key = ("%s:%d:%d"):format(e.filename, e.lnum, e.col)
        local item = seen[key]
        if not item then
          item = { id = ("%s:%d"):format(rel(e.filename), e.lnum), text = vim.trim(e.text or ""), data = e }
          seen[key], items[#items + 1] = item, item
        end
        if not item.kind or rank[spec.label] < rank[item.kind] then
          item.glyph, item.hl, item.kind = spec.glyph, spec.hl, spec.label
        end
      end
      pending = pending - 1
      if pending == 0 then vim.schedule(finish) end
    end)
  end
end

function M.definition() vim.lsp.buf.definition({ on_list = pick.list("definitions") }) end

-- Call hierarchy ------------------------------------------------------------------------------

function M.calls(direction)
  local buf = vim.api.nvim_get_current_buf()
  local client = client_for(buf, "textDocument/prepareCallHierarchy")
  if not client then return vim.notify("○ no call hierarchy for this buffer") end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/prepareCallHierarchy", params, function(err, res)
    if err or not res or not res[1] then return vim.notify("○ no call hierarchy here") end
    client:request("callHierarchy/" .. direction .. "Calls", { item = res[1] }, function(_, calls)
      local items = {}
      for _, c in ipairs(calls or {}) do
        local it = c.from or c.to
        local pos, file = it.selectionRange.start, vim.uri_to_fname(it.uri)
        items[#items + 1] = {
          glyph = glyph(it.kind), hl = kind_hl[kind(it.kind)] or "AosDim", id = ("%s:%d"):format(rel(file), pos.line + 1),
          text = it.name .. (it.detail and it.detail ~= "" and ("  " .. it.detail) or ""),
          data = { filename = file, lnum = pos.line + 1, col = pos.character + 1 },
        }
      end
      if #items == 0 then return vim.notify(("○ no %s calls for %s"):format(direction, res[1].name)) end
      pick.open({ title = ("%s calls · %s"):format(direction, res[1].name), items = items, on_choose = pick.jump, preview = true })
    end, buf)
  end, buf)
end

-- Rename ------------------------------------------------------------------------------------

function M.rename()
  local old = vim.fn.expand("<cword>")
  local src = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].completion = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { old })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = math.max(30, #old + 12), height = 1, title = title("rename", old), title_pos = "left",
  })
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, "no"
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    vim.cmd.stopinsert()
  end
  local function apply()
    local new = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
    close()
    if new == "" or new == old then return end
    vim.schedule(function()
      vim.api.nvim_buf_call(src, function() vim.lsp.buf.rename(new) end)
      vim.notify(("✓ renamed %s → %s"):format(old, new))
    end)
  end
  for _, mode in ipairs({ "i", "n", "s" }) do
    vim.keymap.set(mode, "<CR>", apply, { buffer = buf })
    vim.keymap.set(mode, "<C-c>", close, { buffer = buf })
  end
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  -- Start with the whole name selected: typing replaces it, <Right>/<Esc> keep it for editing.
  vim.cmd("normal! 0v$h")
  vim.api.nvim_feedkeys(vim.keycode("<C-g>"), "n", false)
end

-- Document symbols: shared by the outline and the breadcrumbs --------------------------------

local function normalize(list, depth, out)
  for _, s in ipairs(list or {}) do
    local range = s.range or (s.location and s.location.range)
    local sel = s.selectionRange or range
    out[#out + 1] = { name = s.name, detail = s.detail, kind = s.kind, depth = depth, range = range, pos = sel.start }
    if s.children then normalize(s.children, depth + 1, out) end
  end
  return out
end

local function fetch(buf, cb)
  local client = client_for(buf, "textDocument/documentSymbol")
  if not client then return cb and cb(nil) end
  local tick = vim.b[buf].changedtick
  client:request("textDocument/documentSymbol", { textDocument = vim.lsp.util.make_text_document_params(buf) }, function(err, res)
    if not err and res and vim.api.nvim_buf_is_valid(buf) then
      symbols[buf] = { tick = tick, list = normalize(res, 0, {}) }
      vim.cmd.redrawstatus({ bang = true })
    end
    if cb then cb(symbols[buf]) end
  end, buf)
end

local function refresh_later(buf, cb)
  timers[buf] = timers[buf] or vim.uv.new_timer()
  timers[buf]:start(350, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then fetch(buf, cb) end
  end))
end

local function contains(range, row, col)
  local s, e = range.start, range["end"]
  if row < s.line or row > e.line then return false end
  if row == s.line and col < s.character then return false end
  return not (row == e.line and col > e.character)
end

-- Innermost-last chain of symbols that contain (row, col); indices into the flat list.
local function chain(buf, row, col)
  local list, out = symbols[buf] and symbols[buf].list or {}, {}
  for i, s in ipairs(list) do
    if s.depth == #out and contains(s.range, row, col) then out[#out + 1] = i end
  end
  return out
end

-- Breadcrumbs -------------------------------------------------------------------------------

local WINBAR = "%{%v:lua.require'ui.lsp'.winbar()%}"

local function esc(s) return (s:gsub("%%", "%%%%")) end

function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local path = rel(vim.api.nvim_buf_get_name(buf))
  local dir, file = vim.fs.dirname(path), vim.fs.basename(path)
  local out = { "%#AosPrompt# ❯ " }
  if dir ~= "." then out[#out + 1] = "%#AosDim#" .. esc(dir) .. "/" end
  out[#out + 1] = "%#AosArg#" .. esc(file)
  local pos = vim.api.nvim_win_get_cursor(win)
  local list = symbols[buf] and symbols[buf].list or {}
  for _, i in ipairs(chain(buf, pos[1] - 1, pos[2])) do
    local s = list[i]
    out[#out + 1] = ("%%#AosFaint# › %%#%s#%s %%#WinBar#%s"):format(kind_hl[kind(s.kind)] or "AosDim", glyph(s.kind), esc(s.name))
  end
  return table.concat(out)
end

local function set_winbar(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local wanted = vim.bo[buf].buftype == "" and client_for(buf, "textDocument/documentSymbol") ~= nil
  if wanted then
    vim.wo[win].winbar = WINBAR
  elseif vim.wo[win].winbar == WINBAR then
    vim.wo[win].winbar = ""
  end
end

-- Outline -----------------------------------------------------------------------------------

local outline = { buf = nil, win = nil, src = nil, rows = {} }

local function outline_open() return outline.win and vim.api.nvim_win_is_valid(outline.win) end

local function src_win()
  local win = vim.fn.bufwinid(outline.src or -1)
  return win ~= -1 and win or nil
end

local function outline_render()
  if not outline_open() then return end
  local data = symbols[outline.src]
  local lines, rows = {}, {}
  for _, s in ipairs(data and data.list or {}) do
    rows[#rows + 1] = s
    lines[#lines + 1] = ("%s%s %s%s"):format(string.rep("  ", s.depth), glyph(s.kind), s.name, s.detail and s.detail ~= "" and ("  " .. s.detail:gsub("\n", " ")) or "")
  end
  if #lines == 0 then lines = { "○ no symbols" } end
  vim.bo[outline.buf].modifiable = true
  vim.api.nvim_buf_set_lines(outline.buf, 0, -1, false, lines)
  vim.bo[outline.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(outline.buf, ns, 0, -1)
  for i, s in ipairs(rows) do
    local col = s.depth * 2
    local g = glyph(s.kind)
    vim.hl.range(outline.buf, ns, kind_hl[kind(s.kind)] or "AosDim", { i - 1, col }, { i - 1, col + #g })
    local detail_col = col + #g + 1 + #s.name
    vim.hl.range(outline.buf, ns, "AosFaint", { i - 1, detail_col }, { i - 1, #lines[i] })
  end
  outline.rows = rows
  vim.wo[outline.win].winbar = ("%%#AosPrompt# ❯ %%#AosArg#outline %%#AosDim#· %s"):format(esc(vim.fs.basename(vim.api.nvim_buf_get_name(outline.src))))
end

-- Keep the outline row of the symbol under the source cursor selected.
local function outline_follow()
  local win = src_win()
  if not outline_open() or not win or vim.api.nvim_get_current_win() == outline.win then return end
  local pos = vim.api.nvim_win_get_cursor(win)
  local c = chain(outline.src, pos[1] - 1, pos[2])
  if c[#c] then pcall(vim.api.nvim_win_set_cursor, outline.win, { c[#c], 0 }) end
end

local function outline_target()
  local s = outline.rows[vim.api.nvim_win_get_cursor(outline.win)[1]]
  local win = src_win()
  if s and win then return s, win end
end

local function outline_show(buf)
  outline.src = buf
  fetch(buf, function()
    outline_render()
    outline_follow()
  end)
end

function M.outline()
  if outline_open() then return vim.api.nvim_win_close(outline.win, true) end
  local src = vim.api.nvim_get_current_buf()
  if not client_for(src, "textDocument/documentSymbol") then return vim.notify("○ no document symbols for this buffer") end
  if not (outline.buf and vim.api.nvim_buf_is_valid(outline.buf)) then
    outline.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[outline.buf].filetype = "aosoutline"
    local function jump(focus)
      return function()
        local s, win = outline_target()
        if not s then return end
        vim.api.nvim_win_set_cursor(win, { s.pos.line + 1, s.pos.character })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
        if focus then vim.api.nvim_set_current_win(win) end
      end
    end
    local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = outline.buf, nowait = true }) end
    map("<CR>", jump(true))
    map("o", jump(true))
    map("q", function() vim.api.nvim_win_close(0, true) end)
    vim.api.nvim_create_autocmd("CursorMoved", { buffer = outline.buf, callback = jump(false) })
  end
  vim.cmd("botright 34vsplit")
  outline.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(outline.win, outline.buf)
  local wo = vim.wo[outline.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.list = false, false, "no", "0", false
  wo.cursorline, wo.wrap, wo.winfixwidth, wo.foldenable = true, false, true, false
  vim.cmd.wincmd("p")
  outline_show(src)
end

-- Inspect ------------------------------------------------------------------------------------

local function hl_hex(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl.fg and ("#%06x"):format(hl.fg) or "-"
end

-- What paints the text under the cursor: treesitter captures, LSP semantic tokens, extmarks,
-- and the syntax-node path, each as a `glyph · source · group → colour` row.
function M.inspect()
  local buf, pos = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local info = vim.inspect_pos(buf, pos[1] - 1, pos[2])
  local rows = {}
  local function add(g, source, group, extra) rows[#rows + 1] = { g = g, source = source, group = group, extra = extra } end
  for _, c in ipairs(info.treesitter) do add("◆", "ts", c.hl_group, ("%s → %s"):format(c.lang, hl_hex(c.hl_group_link or c.hl_group))) end
  for _, t in ipairs(info.semantic_tokens) do
    local group = t.opts and t.opts.hl_group or "?"
    add("●", "lsp", group, ("prio %d → %s"):format(t.opts and t.opts.priority or 0, hl_hex(group)))
  end
  for _, s in ipairs(info.syntax) do add("○", "syntax", s.hl_group, hl_hex(s.hl_group_link or s.hl_group)) end
  for _, e in ipairs(info.extmarks) do
    local group = e.opts and e.opts.hl_group
    if group then add("·", "mark", group, e.ns or "") end
  end
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf })
  local path = {}
  while ok and node do
    table.insert(path, 1, node:type())
    node = node:parent()
  end
  if #path == 0 and #rows == 0 then return vim.notify("○ nothing to inspect here") end

  local lines, marks = {}, {}
  for _, r in ipairs(rows) do
    local prefix = ("%s · %-6s · "):format(r.g, r.source)
    lines[#lines + 1] = prefix .. r.group .. "  " .. r.extra
    marks[#marks + 1] = { #lines - 1, #prefix, #prefix + #r.group, r.group }
  end
  if #path > 0 then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "▾ " .. table.concat(vim.list_slice(path, math.max(1, #path - 5)), " › ")
  end
  local fbuf = vim.lsp.util.open_floating_preview(lines, "", {
    title = title("inspect", vim.fn.expand("<cword>")), title_pos = "left", focus_id = "ui.inspect", max_width = 100,
  })
  for _, m in ipairs(marks) do vim.hl.range(fbuf, ns, m[4], { m[1], m[2] }, { m[1], m[3] }) end
  for i, l in ipairs(lines) do
    vim.hl.range(fbuf, ns, "AosFaint", { i - 1, #l - #(l:match("%s%s.*$") or "") }, { i - 1, #l })
    if vim.startswith(l, "▾") then vim.hl.range(fbuf, ns, "AosArg", { i - 1, 0 }, { i - 1, #l }) end
  end
end

function M.tree()
  vim.treesitter.inspect_tree({ command = "botright 60vnew", title = function() return "❯ tree" end })
end

-- Wiring ------------------------------------------------------------------------------------

-- Buffer-local keys for an LSP buffer; called from core.lsp on attach.
function M.attach(buf, client)
  local function map(lhs, rhs, desc, mode) vim.keymap.set(mode or "n", lhs, rhs, { buffer = buf, desc = desc, nowait = true }) end
  map("K", M.hover, "Hover")
  map("gd", M.definition, "Definition")
  map("gp", M.peek, "Peek definition")
  map("gr", M.rename, "Rename")
  map("gf", M.finder, "Finder: defs, impls, refs")
  map("<leader>o", M.outline, "Outline")
  map("<leader>li", function() M.calls("incoming") end, "Incoming calls")
  map("<leader>lo", function() M.calls("outgoing") end, "Outgoing calls")
  require("ui.fix").attach(buf)
  if client:supports_method("textDocument/documentSymbol") then
    fetch(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do set_winbar(win) end
  end
end

function M.setup()
  vim.ui.select = pick.select
  vim.api.nvim_set_hl(0, "AosPreviewLine", { link = "Visual", default = true })
  vim.keymap.set("n", "<leader>i", M.inspect, { desc = "Inspect under cursor" })
  vim.keymap.set("n", "<leader>I", M.tree, { desc = "Syntax tree" })

  local group = vim.api.nvim_create_augroup("UiLsp", {})
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function() set_winbar(vim.api.nvim_get_current_win()) end })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      if not symbols[ev.buf] then return end
      refresh_later(ev.buf, function()
        if outline.src == ev.buf then outline_render() end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(ev)
      if symbols[ev.buf] then vim.cmd.redrawstatus() end
      if outline_open() and ev.buf == outline.src then outline_follow() end
    end,
  })
  -- The outline follows whichever LSP buffer gets focus, and closes when it is the last window.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if not outline_open() then return end
      if ev.buf == outline.buf and #vim.api.nvim_tabpage_list_wins(0) == 1 then return vim.cmd("quit") end
      if ev.buf ~= outline.src and vim.bo[ev.buf].buftype == "" and client_for(ev.buf, "textDocument/documentSymbol") then outline_show(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev) symbols[ev.buf] = nil end })
end

return M
