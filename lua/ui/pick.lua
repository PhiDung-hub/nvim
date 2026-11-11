-- Minimal fuzzy picker in the WAT row grammar: `glyph · id · text`, prompt `❯ query`.
-- Item: { text = string, id? = string, glyph? = string, hl? = group, data? = any }.
-- `opts.preview` adds a right pane showing `data.filename`/`data.bufnr` at `data.lnum`,
-- or, as a function(win, item), whatever it draws into that pane.
-- `opts.live(query, set)` replaces fuzzy filtering: it finds the rows itself and calls set(items).
-- `opts.query` starts with that text; `opts.boost(item)` adds to an item's fuzzy score.
local M = {}
local ns = vim.api.nvim_create_namespace("ui.pick")
local pns = vim.api.nvim_create_namespace("ui.pick.preview")
local SEP = " · "

M.keys = {
  {
    section = "Picker",
    keys = {
      { "<CR>", "choose the row", "n i" },
      { "<Down>", "next row", "n i" },
      { "<C-n>", "next row", "n i" },
      { "<Up>", "previous row", "n i" },
      { "<C-p>", "previous row", "n i" },
      { "<Esc>", "close", "n i" },
      { "<C-c>", "close", "n i" },
    },
  },
}

local function row(item)
  local parts = {}
  if item.glyph then parts[#parts + 1] = item.glyph end
  if item.id then parts[#parts + 1] = item.id end
  parts[#parts + 1] = item.text
  return table.concat(parts, SEP)
end

local function mark(buf, line, from, to, hl)
  vim.api.nvim_buf_set_extmark(buf, ns, line, from, { end_col = to, hl_group = hl, ephemeral = true })
end

local function paint(buf, line, item)
  local col = 0
  if item.glyph then
    mark(buf, line, 0, #item.glyph, item.hl or "AosDim")
    col = #item.glyph + #SEP
  end
  if item.id then
    mark(buf, line, col, col + #item.id, "AosId")
    mark(buf, line, col + #item.id, col + #item.id + #SEP, "AosFaint")
  end
end

-- Rows are painted as they are drawn, so a 12k-row list (refs of a big repo) costs only what is on screen.
local painted = {} -- list buf -> shown items
vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf) return painted[buf] ~= nil end,
  on_line = function(_, _, buf, line)
    local item = painted[buf][line + 1]
    if item then paint(buf, line, item) end
  end,
})

local function rel(path) return vim.fn.fnamemodify(path, ":~:.") end

-- Fuzzy score plus opts.boost(item), so recent files outrank equal matches.
local function ranked(items, query, boost)
  if not boost then return vim.fn.matchfuzzy(items, query, { key = "text", limit = 500 }) end
  local found, _, scores = unpack(vim.fn.matchfuzzypos(items, query, { key = "text", limit = 2000 }))
  local order = {}
  for i, item in ipairs(found) do order[i] = { item = item, score = scores[i] + boost(item) } end
  table.sort(order, function(a, b) return a.score > b.score end)
  return vim.tbl_map(function(o) return o.item end, vim.list_slice(order, 1, 500))
end

local function item_buf(d)
  if not d then return end
  if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then return d.bufnr end
  local stat = d.filename and vim.uv.fs_stat(d.filename)
  if stat and stat.size <= 1572864 then return vim.fn.bufadd(d.filename) end
end

-- Show the item's file around its line in `win`, the target line tinted.
local function preview(win, item, state)
  local buf = item_buf(item and item.data)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then vim.api.nvim_buf_clear_namespace(state.buf, pns, 0, -1) end
  if not buf then return end
  vim.fn.bufload(buf)
  state.buf = buf
  vim.api.nvim_win_set_buf(win, buf)
  -- Showing a buffer copies its last window's local options; reset the ones a preview must not have.
  local wo = vim.wo[win]
  wo.winbar, wo.relativenumber, wo.number, wo.foldcolumn, wo.signcolumn, wo.foldenable = "", false, true, "0", "no", false
  local lnum = math.max(1, math.min(item.data.lnum or 1, vim.api.nvim_buf_line_count(buf)))
  vim.api.nvim_buf_set_extmark(buf, pns, lnum - 1, 0, { line_hl_group = "AosPreviewLine", priority = 200 })
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
  local title = (" %s:%d "):format(rel(vim.api.nvim_buf_get_name(buf)), lnum)
  vim.api.nvim_win_set_config(win, { title = title, title_pos = "left" })
end

function M.open(opts)
  if opts.resumable then M.last = { opts = opts, query = opts.query or "" } end
  local items, shown, index = opts.items or {}, opts.items or {}, 1
  local total = math.min(opts.preview and 180 or 110, vim.o.columns - 6)
  local width = opts.preview and math.floor(total * 0.45) or total
  local height = opts.preview and math.min(22, vim.o.lines - 8) or math.min(18, math.max(#items, 3), vim.o.lines - 8)
  local row0 = math.floor((vim.o.lines - height) / 3)
  local col0 = math.floor((vim.o.columns - total) / 2)
  local pbuf, lbuf = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
  vim.b[pbuf].completion = false
  local vwin, vstate
  local show = type(opts.preview) == "function" and opts.preview or function(w, item) preview(w, item, vstate) end
  if opts.preview then
    vstate = {}
    vwin = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor", row = row0, col = col0 + width + 2, width = total - width - 2, height = height + 3,
      focusable = false, title = " preview ", title_pos = "left",
    })
  end
  local lwin = vim.api.nvim_open_win(lbuf, false, {
    relative = "editor", row = row0 + 3, col = col0, width = width, height = height, focusable = false,
    footer = (" %d items "):format(#items), footer_pos = "right",
  })
  local pwin = vim.api.nvim_open_win(pbuf, true, {
    relative = "editor", row = row0, col = col0, width = width, height = 1,
    title = " ❯ " .. (opts.title or "pick") .. " ", title_pos = "left",
  })
  vim.wo[lwin].cursorline = true
  vim.wo[lwin].winhighlight = "CursorLine:PmenuSel"
  for _, w in ipairs({ lwin, pwin }) do
    vim.wo[w].number, vim.wo[w].relativenumber, vim.wo[w].signcolumn, vim.wo[w].foldcolumn = false, false, "no", "0"
    vim.wo[w].list = false
  end

  local last_query = ""
  local done = false
  local function render()
    local lines = vim.tbl_map(row, shown)
    local empty = opts.live and last_query == "" and "○ · type to search" or "○ · no match"
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, #lines > 0 and lines or { empty })
    painted[lbuf] = shown
    index = math.max(1, math.min(index, #shown))
    if #shown > 0 then vim.api.nvim_win_set_cursor(lwin, { index, 0 }) end
    vim.api.nvim_win_set_config(lwin, { footer = (" %d/%d "):format(#shown, #items), footer_pos = "right" })
    if vwin then show(vwin, shown[index]) end
  end

  local function filter()
    local query = vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ""
    if query == last_query then return end
    last_query = query
    if M.last and M.last.opts == opts then M.last.query = query end
    if opts.live then
      return opts.live(query, function(found)
        if done or query ~= last_query then return end
        items, shown, index = found, found, 1
        render()
      end)
    end
    shown = query == "" and items or ranked(items, query, opts.boost)
    index = 1
    render()
  end

  local function close()
    painted[lbuf] = nil
    if not done and opts.on_cancel then vim.schedule(opts.on_cancel) end
    done = true
    vim.cmd.stopinsert()
    if vstate and vstate.buf and vim.api.nvim_buf_is_valid(vstate.buf) then vim.api.nvim_buf_clear_namespace(vstate.buf, pns, 0, -1) end
    for _, w in ipairs({ pwin, lwin, vwin }) do
      if w then pcall(vim.api.nvim_win_close, w, true) end
    end
  end

  local function choose()
    filter() -- TextChangedI waits for typeahead to drain; fast typing reaches <CR> first.
    local item = shown[index]
    done = true
    close()
    if item then vim.schedule(function() opts.on_choose(item) end) end
  end

  local function move(delta)
    return function()
      index = (index - 1 + delta) % math.max(#shown, 1) + 1
      if #shown > 0 then vim.api.nvim_win_set_cursor(lwin, { index, 0 }) end
      if vwin then show(vwin, shown[index]) end
    end
  end

  local function map(lhs, fn) vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = pbuf, nowait = true }) end
  map("<CR>", choose)
  map("<Esc>", close)
  map("<C-c>", close)
  map("<Down>", move(1))
  map("<C-n>", move(1))
  map("<Up>", move(-1))
  map("<C-p>", move(-1))
  vim.api.nvim_create_autocmd("TextChangedI", { buffer = pbuf, callback = filter })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = pbuf, once = true, callback = close })
  render()
  if opts.query and opts.query ~= "" then
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { opts.query })
    filter()
  end
  vim.cmd.startinsert({ bang = true })
end

function M.jump(item)
  local d = item.data
  vim.cmd("normal! m'")
  if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
    vim.api.nvim_set_current_buf(d.bufnr)
  elseif d.filename then
    vim.cmd.edit(vim.fn.fnameescape(d.filename))
  end
  if d.lnum then pcall(vim.api.nvim_win_set_cursor, 0, { d.lnum, math.max((d.col or 1) - 1, 0) }) end
end

function M.buffers()
  local items = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    items[#items + 1] = {
      glyph = info.changed == 1 and "●" or "○", hl = info.changed == 1 and "AosRunning" or "AosDim",
      id = tostring(info.bufnr), text = info.name ~= "" and rel(info.name) or "[No Name]",
      data = { bufnr = info.bufnr, lnum = info.lnum },
    }
  end
  M.open({ title = "buffers", items = items, on_choose = M.jump })
end

function M.help()
  local items = {}
  for _, file in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
    for line in io.lines(file) do items[#items + 1] = { text = line:match("^[^\t]+") } end
  end
  M.open({ title = "help", items = items, on_choose = function(item) vim.cmd.help(item.text) end })
end

local severity_glyph = { "✗", "!", "●", "·" }
local severity_hl = { "AosFailed", "AosRunning", "AosId", "AosDim" }

function M.diagnostics()
  local items = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    items[#items + 1] = {
      glyph = severity_glyph[d.severity], hl = severity_hl[d.severity],
      id = ("%s:%d"):format(vim.fn.fnamemodify(name, ":t"), d.lnum + 1),
      text = d.message:gsub("\n", " "), data = { bufnr = d.bufnr, lnum = d.lnum + 1, col = d.col + 1, severity = d.severity },
    }
  end
  table.sort(items, function(a, b) return a.data.severity < b.data.severity end)
  M.open({ title = "diagnostics", items = items, on_choose = M.jump, preview = true })
end

-- on_list handler for vim.lsp.buf.* location requests: one result jumps, more open a previewed list.
function M.list(title)
  return function(res)
    local items = vim.tbl_map(function(e)
      return {
        id = ("%s:%d"):format(rel(e.filename), e.lnum), text = vim.trim(e.text), glyph = e.kind and "◆" or nil,
        hl = "AosArg", data = e,
      }
    end, res.items)
    if #items == 1 then return M.jump(items[1]) end
    M.open({ title = title, items = items, on_choose = M.jump, preview = true })
  end
end

-- vim.ui.select (code actions, LSP choices, any plugin) through the picker.
function M.select(choices, opts, on_choice)
  opts = opts or {}
  local fmt = opts.format_item or tostring
  local items = {}
  for i, c in ipairs(choices) do items[i] = { glyph = tostring(i), hl = "AosDim", text = fmt(c), data = { choice = c, idx = i } } end
  M.open({
    title = (opts.prompt or "select"):gsub("[:%s]+$", ""):lower(),
    items = items,
    on_choose = function(item) on_choice(item.data.choice, item.data.idx) end,
    on_cancel = function() on_choice(nil, nil) end,
  })
end

-- Files and text under the working directory (replaces fff): rg, cut off at 3 s like every other scan.
local function recency()
  local score, cwd = {}, vim.fn.getcwd() .. "/"
  for i, f in ipairs(vim.list_slice(vim.v.oldfiles, 1, 100)) do
    if vim.startswith(f, cwd) then score[f:sub(#cwd + 1)] = 100 - i end
  end
  for _, b in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local path = vim.startswith(b.name, cwd) and b.name:sub(#cwd + 1)
    if path then score[path] = (score[path] or 0) + 50 end
  end
  return score
end

local function file_item(path)
  local glyph, hl = require("ui.icons").get_icon(path:match("[^/]*$"), nil, { default = true })
  return { glyph = glyph, hl = hl, text = path, data = { filename = path } }
end

function M.files(query)
  vim.system({ "rg", "--files", "--hidden", "--glob", "!.git" }, { cwd = vim.fn.getcwd(), text = true, timeout = 3000 }, function(r)
    vim.schedule(function()
      if r.code == 124 then vim.notify("○ files · listing cut off at 3 s", vim.log.levels.WARN) end
      local boost, recent, rest = recency(), {}, {}
      for path in (r.stdout or ""):gmatch("[^\n]+") do table.insert(boost[path] and recent or rest, file_item(path)) end
      table.sort(recent, function(a, b) return boost[a.text] > boost[b.text] end)
      M.open({
        title = "files", items = vim.list_extend(recent, rest), query = query, preview = true, resumable = true,
        on_choose = M.jump, boost = function(item) return boost[item.text] or 0 end,
      })
    end)
  end)
end

local function grep_items(out)
  local items = {}
  for line in out:gmatch("[^\n]+") do
    local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if file then
      items[#items + 1] = { id = file .. ":" .. lnum, text = vim.trim(text), data = { filename = file, lnum = tonumber(lnum), col = tonumber(col) } }
    end
    if #items >= 2000 then break end
  end
  return items
end

-- Literal, smart-case; each keystroke cancels the previous rg after an 80 ms pause.
local grep_job, grep_timer
function M.grep(query)
  grep_timer = grep_timer or vim.uv.new_timer()
  local function live(q, set)
    local job, timer = grep_job, grep_timer
    if job then job:kill(15) end
    timer:stop()
    if q == "" then return set({}) end
    timer:start(80, 0, vim.schedule_wrap(function()
      local cmd = { "rg", "--vimgrep", "--smart-case", "--fixed-strings", "--max-count", "100", "--max-columns", "300", "--max-columns-preview", "--", q }
      grep_job = vim.system(cmd, { cwd = vim.fn.getcwd(), text = true, timeout = 3000 }, function(r)
        vim.schedule(function() set(grep_items(r.stdout or "")) end)
      end)
    end))
  end
  M.open({ title = "grep", query = query, live = live, preview = true, resumable = true, on_choose = M.jump })
end

function M.resume()
  if not M.last then return M.files() end
  M.open(vim.tbl_extend("force", M.last.opts, { query = M.last.query }))
end

return M
