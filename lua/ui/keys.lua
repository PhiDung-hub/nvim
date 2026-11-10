-- Hotkey help (`<leader>?`, `:Keys [tab]`): every described map, each module's popup keys (M.keys) and
-- the Vim built-ins worth remembering, as one table per tab.
local M = {}
local ns = vim.api.nvim_create_namespace("ui.keys")
local SEP = " │ "
local TABS = { "Editor", "LSP & Fix", "Git", "Agent", "AI", "Popups", "Vim" }
local MODES = { "n", "x", "s", "o", "i", "c", "t" }
local KNOWN = {
  "git.scm", "git.diff", "git.merge", "git.signs", "git.graph", "git.branch",
  "ui.lsp", "ui.fix", "ui.pick", "ui.term", "ui.keys", "agent", "agent.view", "agent.review",
}
local OWNED = { ui = true, git = true, agent = true, core = true, config = true }
local S = {}

M.keys = {
  {
    section = "Keys",
    keys = {
      { "1", "Editor tab (2–7 the others)" },
      { "<Tab>", "next tab" },
      { "<S-Tab>", "previous tab" },
      { "l", "next tab" },
      { "h", "previous tab" },
      { "<LeftMouse>", "on a tab: switch to it" },
      { "/", "filter rows across all tabs" },
      { "<CR>", "run the row's key in the original window" },
      { "<Esc>", "clear the filter, else close" },
      { "q", "close" },
    },
  },
}

-- First match wins; lhs patterns see the label (leader as ␣), desc patterns the lowercased desc.
local RULES = {
  { tab = "Agent", lhs = { "^␣a", "^[%[%]]a$" }, desc = { "^agent" } },
  { tab = "Git", lhs = { "^␣[gh]", "^[%[%]]h$", "^ih$" }, desc = { "git", "hunk", "blame", "source control" } },
  { tab = "LSP & Fix", lhs = { "^K$", "^g[dpfO]$", "^gr", "^␣[olci.]", "^␣I$", "^<C%-%.>$", "^[%[%]][dD]$" }, desc = { "diagnostic", "lsp", "inlay" } },
  { tab = "AI", lhs = {}, desc = { "ai suggestion", "codex", "copilot" } },
}

local DEFAULT_TEXT = {
  ["&-default"] = "repeat the last :s with its flags",
  ["Y-default"] = "yank to end of line",
  ["CTRL-L-default"] = "clear search highlight, update diff, redraw",
  ["v_#-default"] = "search the selection backward",
  ["v_star-default"] = "search the selection forward",
  ["v_@-default"] = "run a macro on each selected line",
  ["v_Q-default"] = "repeat the last recorded macro on each selected line",
  ["i_CTRL-W-default"] = "delete the word before the cursor (undoable)",
  ["i_CTRL-U-default"] = "delete to the line start (undoable)",
}

local CMD_TEXT = {
  Agent = "attach · spawn claude|codex · view · changes · comments · detach",
  AgentAsk = "/btw about the range",
  AgentTask = "task on the range",
  Complete = "AI source: auto · copilot · codex · off",
}

local VIM = {
  {
    section = "Folds",
    keys = {
      { "za", "toggle the fold under the cursor" },
      { "zA", "toggle it recursively" },
      { "zo", "open fold" },
      { "zO", "open recursively" },
      { "zc", "close fold" },
      { "zC", "close recursively" },
      { "zR", "open all folds" },
      { "zM", "close all folds" },
      { "zr", "open one more level everywhere" },
      { "zm", "close one more level everywhere" },
      { "[z", "start of the current fold" },
      { "]z", "end of the current fold" },
      { "zv", "open folds to show the cursor line" },
      { "zx", "reset folds to foldlevel" },
      { "click ▾/▸", "toggle a fold from the fold column" },
      { "zj/zk", "windows here (Vim: next/previous fold)" },
    },
  },
  {
    section = "Windows",
    keys = {
      { "zh/zj/zk/zl", "move to the window left/down/up/right (here)" },
      { "sv", "vertical split (here)" },
      { "<C-w>s", "split" },
      { "<C-w>v", "vertical split" },
      { "<C-w>c", "close window" },
      { "<C-w>o", "close all other windows" },
      { "<C-w>w", "next window" },
      { "<C-w>p", "previous window" },
      { "<C-w>=", "equalise sizes" },
      { "<C-w>_", "maximise height" },
      { "<C-w>|", "maximise width" },
      { "<C-w>+/-", "taller / shorter" },
      { "<C-w>>/<", "wider / narrower" },
      { "<C-w>T", "move the window to a new tab" },
    },
  },
  {
    section = "Search & replace",
    keys = {
      { "/pat", "search forward" },
      { "?pat", "search backward" },
      { "n", "next match" },
      { "N", "previous match" },
      { "*", "word under the cursor, forward" },
      { "#", "word under the cursor, backward" },
      { "g*", "same, partial matches too" },
      { "gn", "select the next match", "n o" },
      { "cgn", "change the next match (repeat with .)" },
      { ":s/a/b/g", "replace in the line" },
      { ":%s/a/b/gc", "replace in the file, confirm each" },
      { "&", "repeat the last :s" },
      { "<C-l>", "clear search highlight" },
    },
  },
  {
    section = "Marks & jumps",
    keys = {
      { "m{a-z}", "set a mark (A-Z: across files)" },
      { "`{a}", "jump to the mark" },
      { "'{a}", "jump to the mark's line" },
      { "``", "back to the previous position" },
      { "<C-o>", "older jump" },
      { "<C-i>", "newer jump" },
      { "g;", "older change" },
      { "g,", "newer change" },
      { "`.", "last change" },
      { "gi", "insert where insert mode was left" },
      { "%", "matching bracket" },
      { ":marks", "list marks" },
    },
  },
  {
    section = "Macros & registers",
    keys = {
      { "q", "visual block here (Vim: record a macro)" },
      { "@{a}", "play macro a" },
      { "@@", "repeat the last macro" },
      { "Q", "replay the last recorded macro" },
      { ".", "repeat the last change" },
      { '"{a}y', "yank into register a" },
      { '"+y', "yank to the clipboard (<C-c> here)" },
      { "<C-r>{a}", "insert register a", "i c" },
      { ":reg", "list registers" },
    },
  },
  {
    section = "Diff mode",
    keys = {
      { "]c", "next change" },
      { "[c", "previous change" },
      { "do", "obtain the change from the other side" },
      { "dp", "put the change to the other side" },
      { ":diffthis", "add the window to the diff" },
      { ":diffoff", "leave diff mode" },
      { ":diffupdate", "recompute the diff" },
    },
  },
  {
    section = "Text objects",
    keys = {
      { "iw/aw", "word", "o x" },
      { "iW/aW", "WORD (to whitespace)", "o x" },
      { "is/as", "sentence", "o x" },
      { "ip/ap", "paragraph", "o x" },
      { "i(/a(", "parentheses (ib/ab)", "o x" },
      { "i{/a{", "braces (iB/aB)", "o x" },
      { "i[/a[", "brackets", "o x" },
      { "i</a<", "angle brackets", "o x" },
      { 'i"/a"', "double quotes", "o x" },
      { "i'/a'", "single quotes", "o x" },
      { "it/at", "tag block", "o x" },
      { "ih", "git hunk (here)", "o x" },
    },
  },
}

-- A live map's lhs (already <> notation, but leader and space kept raw) as the palette shows it: leading leader as ␣.
function M.label(lhs)
  local leader = vim.g.mapleader or "\\"
  if lhs:sub(1, #leader) == leader then lhs = "␣" .. lhs:sub(#leader + 1) end
  return (lhs:gsub(" ", "<Space>"))
end

local function typed(lhs)
  return (lhs:gsub("^<[Ll]eader>", "␣"):gsub("<[Ll]eader>", vim.fn.keytrans(vim.g.mapleader or "\\")))
end

local function matches(text, patterns)
  for _, p in ipairs(patterns) do
    if text:find(p) then return true end
  end
end

local function is_default(m)
  if m.desc:find("^:help ") then return true end
  return m.callback and debug.getinfo(m.callback, "S").source:find("^@vim/") ~= nil
end

local function classify(row, m)
  local desc, section = row.action:lower(), row.section or "keymaps"
  for _, r in ipairs(RULES) do
    if matches(row.key, r.lhs) or matches(desc, r.desc) then return r.tab, section end
  end
  if is_default(m) then return "Vim", "nvim defaults" end
  return "Editor", section
end

local function modes_text(set)
  local out = {}
  if set.n then out[#out + 1] = "n" end
  if set.x and set.s then out[#out + 1] = "v" elseif set.x then out[#out + 1] = "x" elseif set.s then out[#out + 1] = "s" end
  for _, k in ipairs({ "o", "i", "c", "t" }) do
    if set[k] then out[#out + 1] = k end
  end
  return table.concat(out, " ")
end

local function add_map(acc, m, mode, where)
  if not m.desc or m.lhs:find("^<Plug>") then return end
  local id = where .. "\0" .. m.lhs .. "\0" .. m.desc
  local row = acc.index[id]
  if not row then
    local text = DEFAULT_TEXT[m.desc:match("^:help (.+)$") or ""] or m.desc
    local plugin, rest = text:match("^(%w+%.[%w.]+): (.+)$")
    row = { key = M.label(m.lhs), lhs = m.lhs, action = rest or text, section = plugin, where = where, set = {}, map = m }
    acc.index[id], acc.rows[#acc.rows + 1] = row, row
  end
  row.set[mode] = true
end

local function live_maps(buf)
  local acc = { index = {}, rows = {} }
  for _, mode in ipairs(MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do add_map(acc, m, mode, "global") end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do add_map(acc, m, mode, "buffer") end
  end
  for _, row in ipairs(acc.rows) do
    row.mode, row.run = modes_text(row.set), row.set.n
  end
  table.sort(acc.rows, function(a, b) return a.key:lower() < b.key:lower() end)
  return acc.rows
end

local function command_tab(name)
  if name:find("^Git") then return "Git" end
  if name:find("^Agent") then return "Agent" end
  if name:find("^Lsp") or name:find("^Inspect") then return "LSP & Fix" end
  if name == "Complete" then return "AI" end
  return "Editor"
end

local function commands(buf)
  local rows = {}
  local all = vim.tbl_extend("force", vim.api.nvim_get_commands({}), vim.api.nvim_buf_get_commands(buf, {}))
  for name, c in pairs(all) do
    local text = c.definition ~= "" and c.definition or CMD_TEXT[name]
    local noise = not text or text:find("^%l+<bang> <args>$") or text:find("^call ")
    if not noise then rows[#rows + 1] = { key = ":" .. name, cmd = name, nargs = c.nargs, action = text, mode = ":", where = "command", run = true } end
  end
  table.sort(rows, function(a, b) return a.key < b.key end)
  return rows
end

local function module_tab(name)
  if name:find("^git") then return "Git" end
  if name:find("^agent") then return "Agent" end
  if name == "ui.fix" or name == "ui.lsp" or name == "core.lsp" then return "LSP & Fix" end
  if name == "core.complete" then return "AI" end
  return "Popups"
end

local function valid(sections)
  local first = type(sections) == "table" and sections[1]
  return type(first) == "table" and type(first.section) == "string" and type(first.keys) == "table"
end

-- Known modules are required so their popups show before first use; any other loaded local module with keys joins them.
local function modules()
  local rank = {}
  for i, name in ipairs(KNOWN) do
    rank[name] = i
    pcall(require, name)
  end
  local names = {}
  for name, mod in pairs(package.loaded) do
    if OWNED[name:match("^[^.]+")] and type(mod) == "table" and valid(rawget(mod, "keys")) then names[#names + 1] = name end
  end
  table.sort(names, function(a, b)
    local ra, rb = rank[a] or 99, rank[b] or 99
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return names
end

local function section_rows(sec, where)
  local rows = {}
  if type(sec) ~= "table" or type(sec.keys) ~= "table" then return rows end
  for _, k in ipairs(sec.keys) do
    if type(k) == "table" and type(k[1]) == "string" then
      rows[#rows + 1] = { key = typed(k[1]), action = tostring(k[2] or ""), mode = k[3] or "n", where = where or tostring(sec.section) }
    end
  end
  return rows
end

local function build(buf)
  local tabs, by = {}, {}
  for i, name in ipairs(TABS) do
    tabs[i] = { name = name, sections = {}, by = {} }
    by[name] = tabs[i]
  end
  local function add(tab, section, row)
    local t = by[tab]
    if not t.by[section] then
      t.by[section] = { name = section, rows = {} }
      t.sections[#t.sections + 1] = t.by[section]
    end
    row.tab = tab
    table.insert(t.by[section].rows, row)
  end
  for _, sec in ipairs(VIM) do
    for _, row in ipairs(section_rows(sec, "built-in")) do add("Vim", sec.section, row) end
  end
  for _, row in ipairs(live_maps(buf)) do
    local tab, section = classify(row, row.map)
    add(tab, section, row)
  end
  for _, row in ipairs(commands(buf)) do add(command_tab(row.cmd), "commands", row) end
  for _, name in ipairs(modules()) do
    for _, sec in ipairs(package.loaded[name].keys) do
      for _, row in ipairs(section_rows(sec)) do add(module_tab(name), tostring(sec.section), row) end
    end
  end
  return tabs
end

-- Rendering --------------------------------------------------------------------------------

local function width(s) return vim.fn.strdisplaywidth(s) end

local function clip(s, w)
  if width(s) <= w then return s end
  return vim.fn.strcharpart(s, 0, w - 1) .. "…"
end

local function fit(s, w)
  s = clip(s, w)
  return s .. (" "):rep(math.max(0, w - width(s)))
end

local function columns(tabs)
  local w = { key = 3, action = 6, mode = 4, where = 5 }
  for _, t in ipairs(tabs) do
    for _, sec in ipairs(t.sections) do
      for _, r in ipairs(sec.rows) do
        w.key, w.action = math.max(w.key, width(r.key)), math.max(w.action, width(r.action))
        w.mode, w.where = math.max(w.mode, width(r.mode)), math.max(w.where, width(r.where))
      end
    end
  end
  w.key, w.where, w.action = math.min(w.key, 18), math.min(w.where, 18), math.min(w.action, 64)
  local fixed = 2 + w.key + w.mode + w.where + 3 * #SEP
  w.total = math.min(vim.o.columns - 4, math.max(80, fixed + w.action))
  w.action = math.max(10, w.total - fixed)
  return w
end

local function compose(out, cells, row)
  local line, marks = "  ", {}
  for i, c in ipairs(cells) do
    if i > 1 then
      marks[#marks + 1] = { #line, #line + #SEP, "AosBorder" }
      line = line .. SEP
    end
    if c[2] then marks[#marks + 1] = { #line, #line + #c[1], c[2] } end
    line = line .. c[1]
  end
  local n = #out.lines + 1
  out.lines[n], out.marks[n], out.rows[n] = line, marks, row
end

local WHERE_HL = { global = "AosFaint", buffer = "AosId", command = "AosFaint", ["built-in"] = "AosFaint" }

local function emit_section(out, title, rows, w)
  out.lines[#out.lines + 1] = ""
  out.lines[#out.lines + 1] = "▾ " .. title
  out.marks[#out.lines] = { { 0, #"▾", "AosDim" }, { #"▾ ", #out.lines[#out.lines], "Title" } }
  for _, r in ipairs(rows) do
    local where = { clip(r.where, w.where), WHERE_HL[r.where] or "AosDim" }
    compose(out, { { fit(r.key, w.key), "AosArg" }, { fit(r.action, w.action) }, { fit(r.mode, w.mode), "AosDim" }, where }, r)
  end
end

local function hit(row, section, terms)
  local hay = (row.key .. " " .. row.action .. " " .. row.where .. " " .. section):lower()
  for _, term in ipairs(terms) do
    if not hay:find(term, 1, true) then return false end
  end
  return true
end

local function search(tabs, query)
  local terms, hits = vim.split(query:lower(), "%s+", { trimempty = true }), {}
  for _, t in ipairs(tabs) do
    for _, sec in ipairs(t.sections) do
      local rows = vim.tbl_filter(function(r) return hit(r, sec.name, terms) end, sec.rows)
      if #rows > 0 then hits[#hits + 1] = { name = t.name .. " · " .. sec.name, rows = rows } end
    end
  end
  return hits
end

local function lines_for(sections, w)
  local out = { lines = {}, marks = {}, rows = {} }
  local head = { fit("Key", w.key), fit("Action", w.action), fit("Mode", w.mode), "Where" }
  compose(out, vim.tbl_map(function(h) return { h, "AosDim" } end, head))
  for _, sec in ipairs(sections) do emit_section(out, sec.name, sec.rows, w) end
  if #sections == 0 then out.lines[#out.lines + 1] = "  ○ · no match" end
  return out
end

local function tab_bar()
  local parts = {}
  for i, name in ipairs(TABS) do
    local active = not S.query and i == S.tab
    parts[#parts + 1] = ("%%%d@v:lua.AosKeysTab@%%#%s# %s %d:%s %%X"):format(i, active and "TabLineSel" or "TabLine", active and "●" or "○", i, name)
  end
  return table.concat(parts, "%#NormalFloat# ")
end

local function footer()
  if not S.query then return (" 1-%d tab · ⇥ next · / filter · ⏎ run · q close "):format(#TABS) end
  return (" /%s · %d matches · <Esc> clear "):format(S.query, S.count)
end

local function render()
  local sections = S.query and search(S.tabs, S.query) or S.tabs[S.tab].sections
  local out = lines_for(sections, S.w)
  S.rows, S.count = out.rows, 0
  for _ in pairs(out.rows) do S.count = S.count + 1 end
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, out.lines)
  vim.bo[S.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for n, marks in pairs(out.marks) do
    for _, m in ipairs(marks) do vim.api.nvim_buf_set_extmark(S.buf, ns, n - 1, m[1], { end_col = m[2], hl_group = m[3] }) end
  end
  vim.wo[S.win].winbar = tab_bar()
  vim.api.nvim_win_set_config(S.win, { footer = { { footer(), "AosFaint" } }, footer_pos = "left" })
  local first = 1
  for n = 2, #out.lines do
    if out.rows[n] then first = n break end
  end
  vim.api.nvim_win_set_cursor(S.win, { first, 2 })
  vim.api.nvim_win_call(S.win, function() vim.fn.winrestview({ topline = 1 }) end)
end

-- Popup ------------------------------------------------------------------------------------

local function is_open() return S.win and vim.api.nvim_win_is_valid(S.win) end

function M.close()
  if is_open() then pcall(vim.api.nvim_win_close, S.win, true) end
  S.win = nil
end

function M.switch(i)
  if not is_open() then return end
  S.query, S.tab = nil, (i - 1) % #TABS + 1
  render()
end

_G.AosKeysTab = function(i) M.switch(i) end

local function filter()
  local group = vim.api.nvim_create_augroup("UiKeysFilter", {})
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    callback = function()
      local q = vim.fn.getcmdline()
      S.query = q ~= "" and q or nil
      render()
      vim.cmd.redraw()
    end,
  })
  local ok, q = pcall(vim.fn.input, { prompt = "/", default = S.query or "", cancelreturn = "" })
  vim.api.nvim_del_augroup_by_id(group)
  S.query = ok and q ~= "" and q or nil
  if is_open() then render() end
end

local function run()
  local row = S.rows[vim.fn.line(".")]
  if not row then return end
  if not row.run then return vim.notify(("○ %s · works inside %s"):format(row.key, row.where)) end
  local origin = S.origin
  M.close()
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
  if not row.cmd then return vim.api.nvim_feedkeys(vim.keycode(row.lhs), "m", false) end
  if row.nargs == "0" then return vim.cmd(row.cmd) end
  vim.api.nvim_feedkeys(":" .. row.cmd .. " ", "n", false)
end

local function tab_index(arg)
  if not arg or arg == "" then return S.tab or 1 end
  local n = tonumber(arg)
  if n then return math.max(1, math.min(#TABS, n)) end
  for i, name in ipairs(TABS) do
    if name:lower():find(arg:lower(), 1, true) == 1 then return i end
  end
  return 1
end

function M.complete(lead)
  local names = vim.tbl_map(function(n) return n:lower():match("^%S+") end, TABS)
  return vim.tbl_filter(function(n) return n:find(lead:lower(), 1, true) == 1 end, names)
end

local function keymaps(buf)
  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
  for i = 1, #TABS do map(tostring(i), function() M.switch(i) end) end
  map("<Tab>", function() M.switch(S.tab + 1) end)
  map("l", function() M.switch(S.tab + 1) end)
  map("<S-Tab>", function() M.switch(S.tab - 1) end)
  map("h", function() M.switch(S.tab - 1) end)
  map("/", filter)
  map("<CR>", run)
  map("q", M.close)
  map("<Esc>", function()
    if not S.query then return M.close() end
    S.query = nil
    render()
  end)
end

-- Open on `tab` (index or name prefix), optionally filtered by `query`.
function M.open(tab, query)
  M.close()
  S.origin = vim.api.nvim_get_current_win()
  S.tabs = build(vim.api.nvim_get_current_buf())
  S.tab, S.query, S.w = tab_index(tab and tostring(tab)), query, columns(S.tabs)
  local height = 0
  for _, t in ipairs(S.tabs) do height = math.max(height, #lines_for(t.sections, S.w).lines) end
  height = math.min(height, math.floor(vim.o.lines * 0.85))
  S.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.buf].bufhidden, vim.bo[S.buf].filetype = "wipe", "aoskeys"
  S.win = vim.api.nvim_open_win(S.buf, true, {
    relative = "editor", width = S.w.total, height = height, row = math.floor((vim.o.lines - height - 3) / 2),
    col = math.floor((vim.o.columns - S.w.total - 2) / 2), title = " ❯ keys ", title_pos = "left",
  })
  local wo = vim.wo[S.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, "no", "0", ""
  wo.list, wo.wrap, wo.spell, wo.colorcolumn, wo.cursorline = false, false, false, "", true
  wo.winhighlight = "CursorLine:PmenuSel,WinBar:NormalFloat,WinBarNC:NormalFloat"
  keymaps(S.buf)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = S.buf, once = true, callback = M.close })
  render()
end

return M
