-- Centred command line (ext_cmdline): a titled float with inline ghost completion; blink.cmp's menu opens below it
-- through vim.g.ui_cmdline_pos. Block mode (`:lua <<`, multi-line input) keeps the native command line.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("ui.cmdline")
local uins = api.nvim_create_namespace("ui.cmdline.attach")
local titles = { [":"] = " ❯ command ", ["/"] = " ❯ search ", ["?"] = " ❯ search back ", ["="] = " ❯ expression " }
local S = {}
local buf, win

local function joined(content)
  local parts = {}
  for _, chunk in ipairs(content) do parts[#parts + 1] = chunk[2] end
  return table.concat(parts)
end

local function ghost()
  if S.firstc ~= ":" or S.pos ~= #S.text or S.text == "" or S.text:find("%s$") then return "" end
  local ok, items = pcall(vim.fn.getcompletion, S.text, "cmdline")
  local word = S.text:match("[^%s]*$")
  local first = ok and items[1] or ""
  if first:sub(1, #word) ~= word then return "" end
  return first:sub(#word + 1)
end

local function close()
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  win, S.ghost, vim.g.ui_cmdline_pos = nil, nil, nil
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
  vim.g.ui_cmdline_pos = { row + 3, col + 1 + #head }
  api.nvim__redraw({ win = win, flush = true })
end

local handlers = {
  cmdline_show = function(content, pos, firstc, prompt, _, level)
    S = { text = joined(content), pos = pos, firstc = firstc, prompt = prompt, level = level }
    render()
  end,
  cmdline_pos = function(pos)
    if not S.text then return end
    S.pos = pos
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

-- <Right> at the end of the line accepts the ghost text when blink's menu is not open.
function M.accept_ghost()
  if S.ghost and S.ghost ~= "" and vim.fn.getcmdpos() > #vim.fn.getcmdline() then return S.ghost end
  return "<Right>"
end

function M.setup()
  vim.ui_attach(uins, { ext_cmdline = true }, function(event, ...)
    local handler = handlers[event]
    if not handler then return end
    local ok, err = pcall(handler, ...)
    if not ok then vim.schedule(function() vim.notify("cmdline: " .. err, vim.log.levels.ERROR) end) end
    return true
  end)
  vim.keymap.set("c", "<C-l>", M.accept_ghost, { expr = true, desc = "Accept command ghost text" })
end

return M
