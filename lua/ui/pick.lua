-- Minimal fuzzy picker in the Agent OS row grammar: `glyph · id · text`, prompt `❯ query`.
-- Item: { text = string, id? = string, glyph? = string, hl? = group, data? = any }.
local M = {}
local ns = vim.api.nvim_create_namespace("ui.pick")
local SEP = " · "

local function row(item)
  local parts = {}
  if item.glyph then parts[#parts + 1] = item.glyph end
  if item.id then parts[#parts + 1] = item.id end
  parts[#parts + 1] = item.text
  return table.concat(parts, SEP)
end

local function paint(buf, line, item)
  local col = 0
  if item.glyph then
    vim.hl.range(buf, ns, item.hl or "AosDim", { line, 0 }, { line, #item.glyph })
    col = #item.glyph + #SEP
  end
  if item.id then
    vim.hl.range(buf, ns, "AosId", { line, col }, { line, col + #item.id })
    vim.hl.range(buf, ns, "AosFaint", { line, col + #item.id }, { line, col + #item.id + #SEP })
  end
end

function M.open(opts)
  local items, shown, index = opts.items, opts.items, 1
  local width = math.min(110, vim.o.columns - 6)
  local height = math.min(18, math.max(#items, 3), vim.o.lines - 8)
  local row0 = math.floor((vim.o.lines - height) / 3)
  local col0 = math.floor((vim.o.columns - width) / 2)
  local pbuf, lbuf = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
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

  local function render()
    local lines = vim.tbl_map(row, shown)
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, #lines > 0 and lines or { "○ · no match" })
    vim.api.nvim_buf_clear_namespace(lbuf, ns, 0, -1)
    for i, item in ipairs(shown) do paint(lbuf, i - 1, item) end
    index = math.max(1, math.min(index, #shown))
    if #shown > 0 then vim.api.nvim_win_set_cursor(lwin, { index, 0 }) end
    vim.api.nvim_win_set_config(lwin, { footer = (" %d/%d "):format(#shown, #items), footer_pos = "right" })
  end

  local function filter()
    local query = vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ""
    shown = query == "" and items or vim.fn.matchfuzzy(items, query, { key = "text", limit = 500 })
    index = 1
    render()
  end

  local function close()
    vim.cmd.stopinsert()
    for _, w in ipairs({ pwin, lwin }) do pcall(vim.api.nvim_win_close, w, true) end
  end

  local function choose()
    local item = shown[index]
    close()
    if item then vim.schedule(function() opts.on_choose(item) end) end
  end

  local function move(delta)
    return function()
      index = (index - 1 + delta) % math.max(#shown, 1) + 1
      if #shown > 0 then vim.api.nvim_win_set_cursor(lwin, { index, 0 }) end
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
  vim.cmd.startinsert()
end

local function jump(item)
  local d = item.data
  if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
    vim.api.nvim_set_current_buf(d.bufnr)
  elseif d.filename then
    vim.cmd.edit(vim.fn.fnameescape(d.filename))
  end
  if d.lnum then pcall(vim.api.nvim_win_set_cursor, 0, { d.lnum, math.max((d.col or 1) - 1, 0) }) end
end

local function rel(path) return vim.fn.fnamemodify(path, ":~:.") end

function M.buffers()
  local items = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    items[#items + 1] = {
      glyph = info.changed == 1 and "●" or "○", hl = info.changed == 1 and "AosRunning" or "AosDim",
      id = tostring(info.bufnr), text = info.name ~= "" and rel(info.name) or "[No Name]",
      data = { bufnr = info.bufnr, lnum = info.lnum },
    }
  end
  M.open({ title = "buffers", items = items, on_choose = jump })
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
  M.open({ title = "diagnostics", items = items, on_choose = jump })
end

local function from_qf(title)
  return function(res)
    local items = vim.tbl_map(function(e)
      return {
        id = ("%s:%d"):format(rel(e.filename), e.lnum), text = vim.trim(e.text), glyph = e.kind and "◆" or nil,
        hl = "AosArg", data = e,
      }
    end, res.items)
    if #items == 1 then return jump(items[1]) end
    M.open({ title = title, items = items, on_choose = jump })
  end
end

function M.lsp_references() vim.lsp.buf.references(nil, { on_list = from_qf("references") }) end

function M.lsp_symbols() vim.lsp.buf.document_symbol({ on_list = from_qf("symbols") }) end

return M
