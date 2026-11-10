-- Insert-mode helpers that replace nvim-autopairs, nvim-ts-autotag (close) and nvim-colorizer.
-- Tag rename is native LSP linked editing; JSX commentstring comes from treesitter query metadata.
local M = {}
local pairs_map = { ["("] = ")", ["["] = "]", ["{"] = "}", ['"'] = '"', ["'"] = "'", ["`"] = "`" }
local closers = { [")"] = true, ["]"] = true, ["}"] = true }
local tag_fts = { html = true, xml = true, svelte = true, vue = true, javascriptreact = true, typescriptreact = true, astro = true }
local void = { area = 1, base = 1, br = 1, col = 1, embed = 1, hr = 1, img = 1, input = 1, link = 1, meta = 1, source = 1, track = 1, wbr = 1 }

local function around()
  local col = vim.fn.col(".")
  local line = vim.api.nvim_get_current_line()
  return line:sub(col - 1, col - 1), line:sub(col, col), line:sub(1, col - 1)
end

local function active() return vim.bo.buftype == "" and vim.fn.reg_recording() == "" end

local function open(char)
  return function()
    if not active() then return char end
    local prev, next = around()
    local quote = pairs_map[char] == char
    if quote and next == char then return "<Right>" end
    if quote and prev:match("[%w_]") then return char end
    if next:match("[%w_]") then return char end
    return char .. pairs_map[char] .. "<Left>"
  end
end

local function close(char)
  return function()
    local _, next = around()
    return next == char and "<Right>" or char
  end
end

local function backspace()
  local prev, next = around()
  if active() and pairs_map[prev] == next and next ~= "" then return "<BS><Del>" end
  return "<BS>"
end

local function enter()
  local prev, next = around()
  if active() and pairs_map[prev] == next and closers[next] then return "<CR><C-o>O" end
  return "<CR>"
end

-- `<div class="x"` + `>` → `<div class="x"></div>`, cursor between. Skips generics like `useState<T>`.
local function tag_close()
  if not tag_fts[vim.bo.filetype] then return ">" end
  local _, _, before = around()
  local name = before:match("^<([%a][%w%.%-_:]*)[^<>]*$") or before:match("[^%w_%.]<([%a][%w%.%-_:]*)[^<>]*$")
  if not name or before:sub(-1) == "/" or void[name:lower()] and vim.bo.filetype == "html" then return ">" end
  local close_tag = "</" .. name .. ">"
  return ">" .. close_tag .. ("<Left>"):rep(#close_tag)
end

local hex_ns = vim.api.nvim_create_namespace("core.hex")
local hex_groups = {}

-- Paint #rrggbb literals in the visible range (LSP documentColor covers CSS/Tailwind names).
local function paint_hex(buf, win)
  vim.api.nvim_buf_clear_namespace(buf, hex_ns, 0, -1)
  local top, bot = vim.fn.line("w0", win) - 1, vim.fn.line("w$", win)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, top, bot, false)) do
    for s, hex in line:gmatch("()#(%x%x%x%x%x%x)%f[^%w]") do
      local group = "Hex" .. hex
      if not hex_groups[group] then
        vim.api.nvim_set_hl(0, group, { fg = "#" .. hex })
        hex_groups[group] = true
      end
      vim.api.nvim_buf_set_extmark(buf, hex_ns, top + i - 1, s - 1, { virt_text = { { "■", group } }, virt_text_pos = "inline" })
    end
  end
end

function M.setup()
  local map = function(lhs, fn) vim.keymap.set("i", lhs, fn, { expr = true, replace_keycodes = true }) end
  for o in pairs(pairs_map) do map(o, open(o)) end
  for c in pairs(closers) do map(c, close(c)) end
  map("<BS>", backspace)
  map("<CR>", enter)
  map(">", tag_close)

  local hex_fts = { lua = true, css = true, scss = true, html = true, svelte = true, toml = true, yaml = true, json = true, conf = true }
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinScrolled", "TextChanged", "InsertLeave" }, {
    group = vim.api.nvim_create_augroup("CoreHex", {}),
    callback = function(ev)
      if hex_fts[vim.bo[ev.buf].filetype] and not vim.b[ev.buf].bigfile then paint_hex(ev.buf, vim.api.nvim_get_current_win()) end
    end,
  })
  hex_groups = {}
  vim.api.nvim_create_autocmd("ColorScheme", { callback = function() hex_groups = {} end })
end

return M
