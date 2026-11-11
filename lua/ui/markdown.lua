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
    local offset = vim.treesitter.get_node_text(node, ctx.buf):find("[-+*]") or 1
    overlay(ctx, row, col + offset - 1, bullets[(depth - 1) % #bullets + 1], "AosDim")
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
-- Registered once with query.set: disable_pattern() only touched one cached object, and a re-parse brought the
-- conceal back.
local fences_kept = false
local function keep_fences()
  if fences_kept then return end
  fences_kept = true
  local text = {}
  for _, file in ipairs(vim.treesitter.query.get_files("markdown", "highlights")) do
    text[#text + 1] = table.concat(vim.fn.readfile(file), "\n")
  end
  vim.treesitter.query.set("markdown", "highlights", (table.concat(text, "\n"):gsub("%(#set! conceal_lines \"\"%)", "")))
end

-- LSP documentation (hover, signature help, completion docs) ----------------------------------

local doc_ns = vim.api.nvim_create_namespace("ui.markdown.doc")
local function is_rule(l) return l:match("^ ? ? ?[-*_][-*_ ]*$") and select(2, l:gsub("[-*_]", "")) >= 3 end

-- Servers pad sections with blank lines and stack rules (lua_ls: `---` after a code fence); keep one thin rule
-- between sections. `***` because `---` under a paragraph line would turn it into a setext heading.
local literals = { { "%f[%w]0[xXbo]%x+%f[^%w]", "@number" }, { "%f[%w_]%d[%d_]*%.?%d*%f[^%w_]", "@number" },
  { "%f[%w]true%f[^%w]", "@boolean" }, { "%f[%w]false%f[^%w]", "@boolean" }, { "%f[%w]nil%f[^%w]", "@constant.builtin" },
  { "%f[%w]null%f[^%w]", "@constant.builtin" }, { "%f[%w]None%f[^%w]", "@constant.builtin" } }

-- Prose outside code fences gets no treesitter colour; paint literal values (sizes, offsets, defaults) like code.
function M.paint_literals(buf)
  local fence = false
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^%s*```") then fence = not fence elseif not fence then
      for _, lit in ipairs(literals) do
        for s, e in l:gmatch("()" .. lit[1] .. "()") do
          vim.api.nvim_buf_set_extmark(buf, doc_ns, i - 1, s - 1, { end_col = e - 1, hl_group = lit[2], priority = 150 })
        end
      end
    end
  end
end

local function tidy(lines)
  local out, fence, closed = {}, false, false
  for _, l in ipairs(lines) do
    local is_fence = l:match("^%s*```") ~= nil
    if fence or is_fence then
      out[#out + 1] = l
      if is_fence then fence = not fence end
      closed = not fence
    elseif is_rule(l) then
      while out[#out] == "" do out[#out] = nil end
      if #out > 0 and out[#out] ~= "***" and not closed then out[#out + 1] = "***" end
    elseif l ~= "" then
      out[#out + 1], closed = l, false
    elseif #out > 0 and out[#out] ~= "" and out[#out] ~= "***" and not closed then
      out[#out + 1] = l
    end
  end
  while out[#out] == "" or out[#out] == "***" do out[#out] = nil end
  return vim.tbl_map(function(l) return " " .. l end, out)
end

-- Doc-comment tags become grouped lists: lua_ls `@*param* `x` — d`, TypeScript `*@param* `x` — d`, reST `:param x: d`.
local TAGS = { param = "params", parameter = "params", arg = "params", argument = "params", ["return"] = "returns",
  returns = "returns", rtype = "returns", throws = "throws", raise = "raises", raises = "raises", field = "fields" }

local function tag(l)
  local name, rest = l:match("^%s*[*_]?@[*_]?([%a_]+)[*_]*%s*(.*)$")
  if name then return name, rest end
  local field, arg, desc = l:match("^%s*:(%a+)%s*([^:]-)%s*:%s*(.*)$")
  if field and TAGS[field] then return field, arg ~= "" and ("`" .. arg .. "` " .. desc) or desc end
end

local function add_tag(out, group, name, rest)
  local label = TAGS[name] or name
  if not group or group.label ~= label then
    if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
    out[#out + 1] = "*" .. label .. "*"
    group = { label = label }
  end
  local arg, desc = rest:match("^`([^`]+)`%s*(.*)$")
  desc = (desc or rest):gsub("^[—–:%-]+%s*", "")
  group.item = arg ~= nil or desc ~= ""
  if group.item then out[#out + 1] = "- " .. (arg and ("`" .. arg .. "` ") or "") .. desc end
  return group
end

-- Links keep only their text: a concealed URL still counts toward the width, so lines wrapped early.
function M.tags(lines)
  local out, group, fence, blank = {}, nil, false, true
  for _, l in ipairs(lines) do
    local is_fence = l:match("^%s*```") ~= nil
    if is_fence then fence = not fence end
    local name, rest
    if not fence and not is_fence then
      l = l:gsub("%[([^%]]-)%]%b()", "%1")
      name, rest = tag(l)
    end
    if name then
      group = add_tag(out, group, name, rest)
    elseif group and l:match("^%s*$") then
      l = ""
    elseif group and group.item and not is_fence
      and (not blank or (l:match("^%s*%l") and not out[#out]:match("[.!?:]%s*$"))) then
      out[#out] = out[#out] .. " " .. vim.trim(l)
    else
      if group then out[#out + 1], group = "", nil end
      out[#out + 1] = l
    end
    blank = l:match("^%s*$") ~= nil
  end
  return out
end

function M.doc(lines) return tidy(M.tags(lines)) end

function M.toggle()
  M.enabled = not M.enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do schedule(buf) end
end

function M.setup()
  pcall(keep_fences)
  local group = vim.api.nvim_create_augroup("UiMarkdown", {})
  local au = function(event, fn) vim.api.nvim_create_autocmd(event, { group = group, callback = fn }) end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
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
