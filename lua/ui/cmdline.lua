-- ext_cmdline cannot reposition the native pum, so its list is drawn beneath the centred float.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("ui.cmdline")
local uins = api.nvim_create_namespace("ui.cmdline.attach")
local titles = { [":"] = " ❯ command ", ["/"] = " ❯ search ", ["?"] = " ❯ search back ", ["="] = " ❯ expression " }
local S = {}
local buf, win, menu_buf, menu_win

local function joined(content)
  local parts = {}
  for _, chunk in ipairs(content) do parts[#parts + 1] = chunk[2] end
  return table.concat(parts)
end

local function close_menu()
  if menu_win and api.nvim_win_is_valid(menu_win) then api.nvim_win_close(menu_win, true) end
  menu_win = nil
end

local function close()
  close_menu()
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  win = nil
end

-- The text being completed; getcmdcomplpat() knows option values (`ft=l` → `l`), paths and arguments.
local function pattern()
  if S.firstc == ":" then
    local ok, pat = pcall(vim.fn.getcmdcomplpat)
    if ok and (pat == "" or S.text:sub(-#pat) == pat) then return pat end
  end
  return S.text:match("[^%s]*$")
end

local function ranked(items)
  local prefixed, rest = {}, {}
  for _, item in ipairs(items) do table.insert(vim.startswith(item, S.word) and prefixed or rest, item) end
  return vim.list_extend(prefixed, rest)
end

local function candidates()
  if S.text == "" or S.pos ~= #S.text then return {} end
  if S.firstc == ":" then
    local ok, items = pcall(vim.fn.getcompletion, S.text, "cmdline")
    return ok and ranked(items) or {}
  end
  if S.firstc == "/" or S.firstc == "?" then return ranked(vim.fn.matchfuzzy(require("core.cmp").words(), S.word)) end
  return {}
end

local function refresh()
  S.word = pattern()
  S.items, S.selected = candidates(), 0
end

-- A history line whose file argument no longer exists (`:w out1.lua`) is not suggested.
local function stale(entry)
  if S.firstc ~= ":" then return false end
  local ok, kind = pcall(vim.fn.getcompletiontype, entry)
  if not ok or not (kind:match("^file") or kind:match("^dir")) then return false end
  local arg = entry:match("%s(%S+)$")
  return arg ~= nil and vim.uv.fs_stat(vim.fn.expand(arg)) == nil
end

local function from_history()
  local kind = ({ [":"] = ":", ["/"] = "/", ["?"] = "/" })[S.firstc]
  if not kind or S.text == "" then return end
  for i = 1, math.min(vim.fn.histnr(kind), 200) do
    local entry = vim.fn.histget(kind, -i)
    if #entry > #S.text and vim.startswith(entry, S.text) and not stale(entry) then return entry:sub(#S.text + 1) end
  end
end

-- A selected item extends the pattern as ghost text, or replaces it when it is a fuzzy match;
-- with nothing selected the newest matching history line, then the first completion, extend it.
local function preview()
  S.ghost, S.replace = "", nil
  if S.pos ~= #S.text then return end
  local item = S.items[S.selected]
  if item then
    if vim.startswith(item, S.word) then S.ghost = item:sub(#S.word + 1) else S.replace = item end
    return
  end
  local first = S.items[1]
  local extends = first and S.word ~= "" and vim.startswith(first, S.word)
  S.ghost = from_history() or (extends and first:sub(#S.word + 1)) or ""
end

local function draw_item(row, text, width, commands)
  local command = commands[text]
  local description = command and (command.desc or command.definition):gsub("%s+", " ") or ""
  local label = " ❯ " .. text
  local line = vim.fn.strcharpart(label .. (description ~= "" and "  " .. description or ""), 0, width)
  api.nvim_buf_set_lines(menu_buf, row, row + 1, false, { line })
  if row + S.top == S.selected then
    api.nvim_buf_set_extmark(menu_buf, ns, row, 0, { end_row = row + 1, hl_group = "PmenuSel", hl_eol = true, priority = 90 })
  end
  if description ~= "" and #label + 2 < #line then
    api.nvim_buf_set_extmark(menu_buf, ns, row, #label + 2, { end_col = #line, hl_group = "AosCmpSource" })
  end
  local positions = vim.fn.matchfuzzypos({ text }, S.word)[2][1] or {}
  for _, pos in ipairs(positions) do
    local col = #" ❯ " + vim.str_byteindex(text, "utf-32", pos, false)
    local next_col = #" ❯ " + vim.str_byteindex(text, "utf-32", pos + 1, false)
    if next_col <= #line then api.nvim_buf_set_extmark(menu_buf, ns, row, col, { end_col = next_col, hl_group = "AosCmpLabelMatch" }) end
  end
end

-- Hangs off the prompt at the same width: no top border, the prompt's ▁ divides them.
local function render_menu(row, col, width)
  if #S.items == 0 then return close_menu() end
  if not (menu_buf and api.nvim_buf_is_valid(menu_buf)) then menu_buf = api.nvim_create_buf(false, true) end
  local height = math.min(#S.items, vim.o.pumheight, math.max(1, vim.o.lines - row - 2))
  S.top = math.max(1, S.selected - height + 1)
  api.nvim_buf_set_lines(menu_buf, 0, -1, false, vim.fn["repeat"]({ "" }, height))
  api.nvim_buf_clear_namespace(menu_buf, ns, 0, -1)
  local commands = S.firstc == ":" and not S.text:find("%s") and api.nvim_get_commands({}) or {}
  for i = 0, height - 1 do draw_item(i, S.items[S.top + i], width, commands) end
  local e = vim.split(vim.o.winborder, ",")
  local config = { relative = "editor", row = row, col = col, width = width, height = height, border = { "", "", "", e[4], e[5], e[6], e[7], e[8] }, style = "minimal", zindex = 201, focusable = false }
  if menu_win and api.nvim_win_is_valid(menu_win) then return api.nvim_win_set_config(menu_win, config) end
  menu_win = api.nvim_open_win(menu_buf, false, config)
  vim.wo[menu_win].winhighlight = "Normal:Pmenu,FloatBorder:AosCmpMenuBorder"
  vim.wo[menu_win].wrap = false
end

local function cursor_marks(head, line)
  local cur = S.replace and #line or #head + S.pos
  if cur < #line then
    return api.nvim_buf_set_extmark(buf, ns, 0, cur, { end_col = cur + #vim.fn.strcharpart(line:sub(cur + 1), 0, 1), hl_group = "Cursor" })
  end
  local first = vim.fn.strcharpart(S.ghost, 0, 1)
  local tail = { { first ~= "" and first or " ", "Cursor" } }
  if first ~= "" then tail[2] = { vim.fn.strcharpart(S.ghost, 1), "AosGhost" } end
  api.nvim_buf_set_extmark(buf, ns, 0, cur, { virt_text = tail, virt_text_pos = "inline" })
end

local function render()
  if not (buf and api.nvim_buf_is_valid(buf)) then buf = api.nvim_create_buf(false, true) end
  preview()
  local head = " " .. S.firstc .. S.prompt
  local typed = S.replace and S.text:sub(1, #S.text - #S.word) or S.text
  local line = head .. typed .. (S.replace or "")
  local width = math.min(math.max(48, math.floor(vim.o.columns * 0.5)), vim.o.columns - 4)
  local height = math.min(5, math.ceil((vim.fn.strdisplaywidth(line .. S.ghost) + 1) / width))
  local row, col = math.floor(vim.o.lines * 0.3), math.floor((vim.o.columns - width) / 2)
  local config = {
    relative = "editor", row = row, col = col, width = width, height = height, style = "minimal",
    title = titles[S.firstc] or " ❯ input ", title_pos = "left", zindex = 200, focusable = false,
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  if win and api.nvim_win_is_valid(win) then api.nvim_win_set_config(win, config)
  else
    win = api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"
    vim.wo[win].wrap, vim.wo[win].breakindent = true, true
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = #head, hl_group = "AosArg" })
  if S.replace then api.nvim_buf_set_extmark(buf, ns, 0, #head + #typed, { end_col = #line, hl_group = "AosGhost" }) end
  cursor_marks(head, line)
  render_menu(row + height + 2, col, width)
  api.nvim__redraw({ win = win, flush = true })
end

local handlers = {
  cmdline_show = function(content, pos, firstc, prompt, _, level)
    local text = joined(content)
    if text ~= S.text or firstc ~= S.firstc then
      S = { text = text, pos = pos, firstc = firstc, prompt = prompt, level = level }
      refresh()
    end
    S.pos = pos
    render()
  end,
  cmdline_pos = function(pos)
    if not S.text then return end
    S.pos = pos
    refresh()
    render()
  end,
  cmdline_special_char = function(char)
    if not S.text then return end
    S.text = S.text:sub(1, S.pos) .. char .. S.text:sub(S.pos + 1)
    render()
  end,
  cmdline_hide = function()
    S = {}
    close()
  end,
}

-- Keys typed ahead of a redraw arrive before cmdline_show, so they read the line themselves.
local function sync()
  local text, pos = vim.fn.getcmdline(), vim.fn.getcmdpos() - 1
  if text == S.text and pos == S.pos then return end
  S.text, S.pos, S.firstc, S.prompt = text, pos, vim.fn.getcmdtype(), S.prompt or ""
  refresh()
end

-- Takes the selected item or the ghost text into the line without running it.
local function accept()
  sync()
  preview()
  if S.pos ~= #S.text then return false end
  if S.replace then vim.fn.setcmdline(S.text:sub(1, #S.text - #S.word) .. S.replace)
  elseif S.ghost ~= "" then vim.fn.setcmdline(S.text .. S.ghost)
  else return false end
  return true
end

local function select(delta)
  sync()
  if not S.items or #S.items == 0 then return accept() end
  S.selected = (S.selected + delta) % (#S.items + 1)
  render()
end

local function feed(keys) api.nvim_feedkeys(vim.keycode(keys), "n", false) end

function M.setup()
  vim.opt.wildoptions = { "pum", "fuzzy" }
  vim.o.wildmode = "noselect:full,full"
  vim.ui_attach(uins, { ext_cmdline = true }, function(event, ...)
    local handler = handlers[event]
    if not handler then return end
    local ok, err = pcall(handler, ...)
    if not ok then vim.schedule(function() vim.notify("cmdline: " .. err, vim.log.levels.ERROR) end) end
    return true
  end)
  vim.keymap.set("c", "<Tab>", function() select(1) end)
  vim.keymap.set("c", "<S-Tab>", function() select(-1) end)
  vim.keymap.set("c", "<CR>", function()
    sync()
    local item = S.items and S.items[S.selected]
    if item then vim.fn.setcmdline(S.text:sub(1, #S.text - #S.word) .. item) end
    api.nvim_feedkeys(vim.keycode("<CR>"), "ni", false)
  end)
  vim.keymap.set("c", "<C-l>", accept, { desc = "Accept command ghost text" })
  vim.keymap.set("c", "<Right>", function()
    if not accept() then feed("<Right>") end
  end, { desc = "Accept command ghost text at the end, else move right" })
end

return M
