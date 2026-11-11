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

local function candidates()
  if vim.b.completion == false or S.text == "" or S.pos ~= #S.text then return {} end
  if S.firstc == ":" then
    local ok, items = pcall(vim.fn.getcompletion, S.text, "cmdline")
    return ok and items or {}
  end
  if S.firstc == "/" or S.firstc == "?" then return vim.fn.matchfuzzy(require("core.cmp").words(), S.text) end
  return {}
end

local function ghost()
  if S.pos ~= #S.text or S.text:find("%s$") then return "" end
  local word = S.text:match("[^%s]*$")
  local first = S.items[S.selected] or S.items[1] or ""
  if first:sub(1, #word) ~= word then return "" end
  return first:sub(#word + 1)
end

local function close()
  close_menu()
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  win = nil
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
  local query = S.text:match("[^%s]*$")
  local positions = vim.fn.matchfuzzypos({ text }, query)[2][1] or {}
  for _, pos in ipairs(positions) do
    local col = #" ❯ " + vim.str_byteindex(text, "utf-32", pos, false)
    local next_col = #" ❯ " + vim.str_byteindex(text, "utf-32", pos + 1, false)
    if next_col <= #line then api.nvim_buf_set_extmark(menu_buf, ns, row, col, { end_col = next_col, hl_group = "AosCmpLabelMatch" }) end
  end
end

local function render_menu(row, col, width)
  if #S.items == 0 then return close_menu() end
  if not (menu_buf and api.nvim_buf_is_valid(menu_buf)) then menu_buf = api.nvim_create_buf(false, true) end
  local height = math.min(#S.items, vim.o.pumheight, math.max(1, vim.o.lines - row - 3))
  S.top = math.max(1, S.selected - height + 1)
  api.nvim_buf_set_lines(menu_buf, 0, -1, false, vim.fn["repeat"]({ "" }, height))
  api.nvim_buf_clear_namespace(menu_buf, ns, 0, -1)
  local commands = S.firstc == ":" and not S.text:find("%s") and api.nvim_get_commands({}) or {}
  for i = 0, height - 1 do draw_item(i, S.items[S.top + i], width, commands) end
  local config = { relative = "editor", row = row, col = col, width = width, height = height, border = "single", style = "minimal", zindex = 201, focusable = false }
  if menu_win and api.nvim_win_is_valid(menu_win) then api.nvim_win_set_config(menu_win, config)
  else
    menu_win = api.nvim_open_win(menu_buf, false, config)
    vim.wo[menu_win].winhighlight = "Normal:Pmenu,FloatBorder:AosCmpMenuBorder"
    vim.wo[menu_win].wrap = false
  end
end

local function render()
  if not (buf and api.nvim_buf_is_valid(buf)) then buf = api.nvim_create_buf(false, true) end
  local head = " " .. S.firstc .. S.prompt
  local width = math.min(math.max(48, math.floor(vim.o.columns * 0.5)), vim.o.columns - 4)
  local row, col = math.floor(vim.o.lines * 0.3), math.floor((vim.o.columns - width) / 2)
  local config = {
    relative = "editor", row = row, col = col, width = width, height = 1, style = "minimal", border = "single",
    title = titles[S.firstc] or " ❯ input ", title_pos = "left", zindex = 200, focusable = false,
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, { head .. S.text })
  if win and api.nvim_win_is_valid(win) then api.nvim_win_set_config(win, config)
  else
    win = api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"
  end
  S.ghost = ghost()
  local cur = #head + S.pos
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = #head, hl_group = "AosArg" })
  local at_end = cur >= #head + #S.text
  local tail = { { at_end and (S.ghost:sub(1, 1) ~= "" and S.ghost:sub(1, 1) or " ") or "", "Cursor" } }
  if at_end and #S.ghost > 1 then tail[2] = { S.ghost:sub(2), "AosGhost" } end
  if at_end then
    api.nvim_buf_set_extmark(buf, ns, 0, cur, { virt_text = tail, virt_text_pos = "inline" })
  else
    api.nvim_buf_set_extmark(buf, ns, 0, cur, { end_col = cur + 1, hl_group = "Cursor" })
  end
  render_menu(row + 3, col + #head, width - #head)
  api.nvim__redraw({ win = win, flush = true })
end

local handlers = {
  cmdline_show = function(content, pos, firstc, prompt, _, level)
    local text = joined(content)
    if text ~= S.text or firstc ~= S.firstc then
      S = { text = text, pos = pos, firstc = firstc, prompt = prompt, level = level, selected = 0 }
      S.items = candidates()
    end
    S.pos = pos
    render()
  end,
  cmdline_pos = function(pos)
    if not S.text then return end
    S.pos = pos
    S.items, S.selected = candidates(), 0
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

function M.accept_ghost()
  if S.ghost and S.ghost ~= "" and vim.fn.getcmdpos() > #vim.fn.getcmdline() then return S.ghost end
  return "<Right>"
end

local function select(delta)
  if not S.items or #S.items == 0 then return end
  S.selected = (S.selected + delta) % (#S.items + 1)
  render()
end

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
    if S.items and S.items[S.selected] then
      local start = S.text:find("[^%s]*$")
      vim.fn.setcmdline(S.text:sub(1, start - 1) .. S.items[S.selected])
    end
    api.nvim_feedkeys(vim.keycode("<CR>"), "ni", false)
  end)
  vim.keymap.set("c", "<C-l>", M.accept_ghost, { expr = true, desc = "Accept command ghost text" })
end

return M
