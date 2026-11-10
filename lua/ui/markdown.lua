-- Markdown rendered in-buffer with extmarks (replaces render-markdown.nvim).
-- Only the visible range plus a screen of margin is drawn; the cursor line stays raw.
local M = { enabled = true }
local ns = vim.api.nvim_create_namespace("ui.markdown")
local bullets = { "·", "○", "◆" }
local pending, rows = {}, {}
local timer = vim.uv.new_timer()
local queries

local function put(ctx, row, col, opts, keep)
  if row == ctx.cursor and not keep then return end
  opts.strict = false
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, opts)
end

local function overlay(ctx, row, col, text, hl)
  put(ctx, row, col, { virt_text = { { text, hl } }, virt_text_pos = "overlay" })
end

-- Byte columns of a table row's pipes, as a set (escaped `\|` is not a `|` node).
local function pipes(row)
  local cols = {}
  for cell in row:iter_children() do
    if cell:type() == "|" then cols[select(2, cell:start())] = true end
  end
  return cols
end

-- One table rule from the delimiter row's pipe columns: ┌─┬─┐, ├─┼─┤ or └─┴─┘.
local function rule(cols, s, e, l, m, r)
  local out = {}
  for c = s, e do out[#out + 1] = not cols[c] and "─" or c == s and l or c == e and r or m end
  return table.concat(out)
end

local function fence(ctx, row, col, lang)
  local chunks = lang ~= "" and { { "─ ", "AosBorder" }, { lang, "AosDim" }, { " ", "AosBorder" } } or {}
  local used = lang ~= "" and vim.fn.strdisplaywidth(lang) + 3 or 0
  chunks[#chunks + 1] = { ("─"):rep(math.max(ctx.width - col - used, 0)), "AosBorder" }
  put(ctx, row, col, { virt_text = chunks, virt_text_pos = "overlay" })
end

local handlers = {
  heading = function(ctx, node)
    local row, col, _, ecol = node:range()
    local level = tonumber(node:type():match("%d"))
    put(ctx, row, col, {
      end_col = ecol + 1, conceal = "", virt_text_pos = "inline",
      virt_text = { { ("❯"):rep(level) .. " ", "@markup.heading." .. level .. ".markdown" } },
    })
  end,
  bullet = function(ctx, node)
    local after = node:next_sibling()
    if after and after:type():find("^task_list_marker") then return end
    local depth, p = 0, node:parent()
    while p do
      depth = depth + (p:type() == "list" and 1 or 0)
      p = p:parent()
    end
    local row, col = node:start()
    overlay(ctx, row, col, bullets[(depth - 1) % #bullets + 1], "AosDim")
  end,
  check = function(ctx, node)
    local row, _, _, ecol = node:range()
    local done = node:type() == "task_list_marker_checked"
    local _, col = (node:prev_sibling() or node):start()
    put(ctx, row, col, {
      end_col = ecol, conceal = "", virt_text_pos = "inline",
      virt_text = { { done and "✓" or "○", done and "AosDone" or "AosDim" } },
    })
  end,
  quote = function(ctx, node)
    local row, col = node:start()
    for i in vim.treesitter.get_node_text(node, ctx.buf):gmatch("()>") do overlay(ctx, row, col + i - 1, "▏", "AosFaint") end
  end,
  rule = function(ctx, node)
    local row, col = node:start()
    overlay(ctx, row, col, ("─"):rep(ctx.width - col), "AosFaint")
  end,
  code = function(ctx, node)
    local lang, fences = "", {}
    for child in node:iter_children() do
      local kind = child:type()
      if kind == "info_string" then lang = vim.treesitter.get_node_text(child, ctx.buf):match("^%S*") end
      if kind == "fenced_code_block_delimiter" then fences[#fences + 1] = child end
    end
    for i, delim in ipairs(fences) do
      local row, col = delim:start()
      fence(ctx, row, col, i == 1 and lang or "")
    end
  end,
  table = function(ctx, node)
    local lines, delim = {}, nil
    for row in node:iter_children() do
      lines[#lines + 1] = row
      if row:type() == "pipe_table_delimiter_row" then
        delim = row
      else
        for c in pairs(pipes(row)) do overlay(ctx, row:start(), c, "│", "AosBorder") end
      end
    end
    if not delim then return end
    local row, s, _, e = delim:range()
    local cols, pad, last = pipes(delim), (" "):rep(s), e - 1
    overlay(ctx, row, s, rule(cols, s, last, "├", "┼", "┤"), "AosBorder")
    put(ctx, lines[1]:start(), 0, { virt_lines_above = true, virt_lines = { { { pad .. rule(cols, s, last, "┌", "┬", "┐"), "AosBorder" } } } }, true)
    put(ctx, lines[#lines]:start(), 0, { virt_lines = { { { pad .. rule(cols, s, last, "└", "┴", "┘"), "AosBorder" } } } }, true)
  end,
  code_span = function(ctx, node)
    local row, col, erow, ecol = node:range()
    put(ctx, row, col, { end_row = erow, end_col = ecol, hl_group = "AosMdCode" }, true)
  end,
}

local function parse_queries()
  return {
    markdown = vim.treesitter.query.parse("markdown", [[
      [(atx_h1_marker) (atx_h2_marker) (atx_h3_marker) (atx_h4_marker) (atx_h5_marker) (atx_h6_marker)] @heading
      [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet
      [(task_list_marker_unchecked) (task_list_marker_checked)] @check
      [(block_quote_marker) (block_continuation)] @quote
      (thematic_break) @rule
      (fenced_code_block) @code
      (pipe_table) @table
    ]]),
    markdown_inline = vim.treesitter.query.parse("markdown_inline", "(code_span) @code_span"),
  }
end

local function render(buf, win)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then return end
  queries = queries or parse_queries()
  local info = vim.fn.getwininfo(win)[1]
  local top, bot = math.max(info.topline - 1 - info.height, 0), info.botline + info.height
  parser:parse({ top, bot })
  local current = win == vim.api.nvim_get_current_win()
  local ctx = { buf = buf, width = info.width - info.textoff, cursor = current and vim.api.nvim_win_get_cursor(win)[1] - 1 or -1 }
  parser:for_each_tree(function(tree, ltree)
    local query, root = queries[ltree:lang()], tree:root()
    local s, _, e = root:range()
    if not query or e < top or s > bot then return end
    for id, node in query:iter_captures(root, buf, top, bot) do handlers[query.captures[id]](ctx, node) end
  end)
end

local function window(buf)
  if vim.api.nvim_get_current_buf() == buf then return vim.api.nvim_get_current_win() end
  return vim.fn.win_findbuf(buf)[1]
end

local function flush()
  for buf in pairs(pending) do
    pending[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      local win = window(buf)
      if M.enabled and win and not vim.b[buf].bigfile then render(buf, win) end
    end
  end
end

local function schedule(buf)
  if vim.bo[buf].filetype ~= "markdown" then return end
  pending[buf] = true
  timer:start(20, 0, vim.schedule_wrap(flush))
end

-- The highlights query hides fence lines (conceal_lines); keep them so the borders have a line to sit on.
local function keep_fences()
  local query = vim.treesitter.query.get("markdown", "highlights")
  for id, directives in pairs(query and query.info.patterns or {}) do
    for _, d in ipairs(directives) do
      if d[1] == "set!" and d[2] == "conceal_lines" then query.query:disable_pattern(id) end
    end
  end
end

function M.toggle()
  M.enabled = not M.enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do schedule(buf) end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("UiMarkdown", {})
  local au = function(event, fn) vim.api.nvim_create_autocmd(event, { group = group, callback = fn }) end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      pcall(keep_fences)
      vim.keymap.set("n", "<leader>p", M.toggle, { buffer = ev.buf, desc = "Toggle markdown render" })
      schedule(ev.buf)
    end,
  })
  au({ "TextChanged", "InsertLeave", "BufWinEnter" }, function(ev) schedule(ev.buf) end)
  au("WinScrolled", function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do schedule(vim.api.nvim_win_get_buf(win)) end
  end)
  au({ "CursorMoved", "CursorMovedI" }, function(ev)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if rows[ev.buf] == row or vim.bo[ev.buf].filetype ~= "markdown" then return end
    rows[ev.buf] = row
    schedule(ev.buf)
  end)
  vim.api.nvim_create_user_command("Markdown", M.toggle, { desc = "Toggle markdown rendering" })
end

return M
