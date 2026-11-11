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

-- Byte columns of a table row's pipes, as a set (escaped `\|` is not a `|` node), plus their display columns as a key.
local function pipes(ctx, row)
  local cols, shown = {}, {}
  local line = vim.api.nvim_buf_get_lines(ctx.buf, row:start(), row:start() + 1, false)[1] or ""
  for cell in row:iter_children() do
    local _, c = cell:start()
    if cell:type() == "|" then
      cols[c] = true
      shown[#shown + 1] = vim.fn.strdisplaywidth(line:sub(1, c))
    end
  end
  return cols, table.concat(shown, ",")
end

local function blank(ctx, row)
  if row < 0 then return false end
  local line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1]
  return line ~= nil and line:match("^%s*$") ~= nil
end

-- A table's top/bottom rule sits on the neighbouring blank line when there is one, else on a virtual line.
local function edge(ctx, row, near, above, text)
  if blank(ctx, near) then return overlay(ctx, near, 0, text, "AosBorder") end
  put(ctx, row, 0, { virt_lines_above = above, virt_lines = { { { text, "AosBorder" } } } }, true)
end

local function title(ctx, row, col, level, opts)
  opts.virt_text_pos = "inline"
  opts.virt_text = { { ("❯"):rep(level) .. " ", "@markup.heading." .. level .. ".markdown" } }
  put(ctx, row, col, opts)
end

-- One table rule from the delimiter row's pipe columns: ┌─┬─┐, ├─┼─┤ or └─┴─┘.
local function rule(cols, s, e, l, m, r)
  local out = {}
  for c = s, e do out[#out + 1] = not cols[c] and "─" or c == s and l or c == e and r or m end
  return table.concat(out)
end

local function fence(ctx, row, col, lang)
  local chunks = lang ~= "" and { { "─ ", "Whitespace" }, { lang, "AosDim" }, { " ", "Whitespace" } } or {}
  local used = lang ~= "" and vim.fn.strdisplaywidth(lang) + 3 or 0
  chunks[#chunks + 1] = { ("─"):rep(math.max(ctx.width - col - used, 0)), "Whitespace" }
  put(ctx, row, col, { virt_text = chunks, virt_text_pos = "overlay" })
end

local handlers = {
  heading = function(ctx, node)
    local row, col, _, ecol = node:range()
    title(ctx, row, col, tonumber(node:type():match("%d")), { end_col = ecol + 1, conceal = "" })
  end,
  setext = function(ctx, node)
    local row, col = node:parent():start()
    local urow, ucol, _, uecol = node:range()
    title(ctx, row, col, node:type():find("h1") and 1 or 2, {})
    put(ctx, urow, ucol, { end_col = uecol, conceal = "" })
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
    overlay(ctx, row, col, ("─"):rep(ctx.width - col), "Whitespace")
  end,
  code = function(ctx, node)
    local lang, fences = "", {}
    for child in node:iter_children() do
      local kind = child:type()
      if kind == "info_string" then lang = vim.treesitter.get_node_text(child, ctx.buf):match("^%S*") end
      if kind == "fenced_code_block_delimiter" then fences[#fences + 1] = child end
      if kind == "code_fence_content" then
        local s, _, e, ecol = child:range()
        local last = ecol == 0 and e - 1 or e
        local digits = last > s and #tostring(last - s + 1) or 0
        ctx.gutter = math.max(ctx.gutter or 0, digits > 0 and digits + 1 or 0)
        for r = math.max(s, ctx.top), math.min(last, ctx.bot) do
          put(ctx, r, 0, { line_hl_group = "AosMdCode" }, true)
          if digits > 0 then
            put(ctx, r, 0, { virt_text = { { ("%" .. digits .. "d "):format(r - s + 1), "LineNr" } }, virt_text_pos = "inline" }, true)
          end
        end
      end
    end
    for i, delim in ipairs(fences) do
      local row, col = delim:start()
      fence(ctx, row, col, i == 1 and lang or "")
    end
  end,
  table = function(ctx, node)
    local lines, delim, keys = {}, nil, {}
    for row in node:iter_children() do
      lines[#lines + 1] = row
      local cols, key = pipes(ctx, row)
      keys[key] = true
      if row:type() == "pipe_table_delimiter_row" then
        delim = row
      else
        for c in pairs(cols) do overlay(ctx, row:start(), c, "│", "AosBorder") end
      end
    end
    if not delim or vim.tbl_count(keys) > 1 then return end
    local row, s, _, e = delim:range()
    local cols, pad, last = pipes(ctx, delim), (" "):rep(s), e - 1
    local first, final = lines[1]:start(), lines[#lines]:start()
    overlay(ctx, row, s, rule(cols, s, last, "├", "┼", "┤"), "AosBorder")
    edge(ctx, first, first - 1, true, pad .. rule(cols, s, last, "┌", "┬", "┐"))
    edge(ctx, final, final + 1, false, pad .. rule(cols, s, last, "└", "┴", "┘"))
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
      [(setext_h1_underline) (setext_h2_underline)] @setext
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

local function render(parser, ctx)
  parser:parse({ ctx.top, ctx.bot })
  parser:for_each_tree(function(tree, ltree)
    local query, root = queries[ltree:lang()], tree:root()
    local s, _, e = root:range()
    if not query or e < ctx.top or s > ctx.bot then return end
    for id, node in query:iter_captures(root, ctx.buf, ctx.top, ctx.bot) do handlers[query.captures[id]](ctx, node) end
  end)
end

-- Visible range plus a screen of margin per window, overlapping ranges merged so no mark is drawn twice.
local function ranges(buf, wins)
  local out, cursor = {}, -1
  if vim.api.nvim_get_current_buf() == buf then cursor = vim.api.nvim_win_get_cursor(0)[1] - 1 end
  for _, win in ipairs(wins) do
    local info = vim.fn.getwininfo(win)[1]
    local top, bot = math.max(info.topline - 1 - info.height, 0), info.botline + info.height
    out[#out + 1] = { buf = buf, cursor = cursor, top = top, bot = bot, width = info.width - info.textoff }
  end
  table.sort(out, function(a, b) return a.top < b.top end)
  local merged = { out[1] }
  for i = 2, #out do
    local last, r = merged[#merged], out[i]
    if r.top > last.bot then
      merged[#merged + 1] = r
    else
      last.bot, last.width = math.max(last.bot, r.bot), math.max(last.width, r.width)
    end
  end
  return merged
end

-- LSP floats are sized before rendering; grow one only by the virtual lines that would push rows out.
local function fit(win, gutter)
  local config = vim.api.nvim_win_get_config(win)
  if config.relative == "" then return end
  if gutter and gutter > 0 and not vim.w[win].md_gutter then
    vim.w[win].md_gutter = true
    vim.api.nvim_win_set_width(win, math.min(config.width + gutter, vim.o.columns - 4))
  end
  local size, height = vim.api.nvim_win_text_height(win, {}), vim.api.nvim_win_get_height(win)
  if size.all > height and size.all - size.fill <= height then vim.api.nvim_win_set_height(win, size.all) end
end

local function flush()
  for buf in pairs(pending) do
    pending[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      local wins = vim.fn.win_findbuf(buf)
      local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
      if M.enabled and ok and parser and #wins > 0 and not vim.b[buf].bigfile then
        queries = queries or parse_queries()
        local gutter = 0
        for _, ctx in ipairs(ranges(buf, wins)) do
          render(parser, ctx)
          gutter = math.max(gutter, ctx.gutter or 0)
        end
        for _, win in ipairs(wins) do fit(win, gutter) end
      end
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
