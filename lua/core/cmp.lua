local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("core.cmp")
local kind_icons = {
  Method = "ƒ", Function = "ƒ", Constructor = "ƒ", Operator = "ƒ",
  Class = "◇", Interface = "◇", Struct = "◇", Enum = "◇", TypeParameter = "◇",
  Module = "▣", File = "▣", Folder = "▸", Reference = "▣",
  Variable = "·", Field = "·", Property = "·",
  Constant = "·", Value = "·", EnumMember = "·", Unit = "·", Color = "·", Event = "·",
  Keyword = "§", Snippet = "≡", Text = "¶",
}
local cache, signature = {}, {}
local startcol, generation, fallback_enter = 0, 0, nil

local function eligible(buf)
  return vim.b[buf].completion ~= false and vim.bo[buf].buftype == ""
end

local function before_cursor()
  return api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
end

local function item(word, kind, source)
  return {
    word = word, abbr = word, kind = kind_icons[kind], kind_hlgroup = "AosCmpKind" .. kind,
    menu = source, dup = 1, user_data = { aos_start = startcol },
  }
end

local function too_big(buf)
  return vim.b[buf].bigfile or api.nvim_buf_get_offset(buf, api.nvim_buf_line_count(buf)) > 512 * 1024
end

local function buffer_words(buf)
  if not api.nvim_buf_is_loaded(buf) or not eligible(buf) or too_big(buf) then return {} end
  local tick = vim.b[buf].changedtick
  if cache[buf] and cache[buf].tick == tick then return cache[buf].words end
  local words, seen = {}, {}
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, math.min(2000, api.nvim_buf_line_count(buf)), false), "\n"):sub(1, 128 * 1024)
  for _, match in ipairs(vim.fn.matchstrlist({ text }, [[\k\{2,}]])) do
    local word = match.text
    if not seen[word] then words[#words + 1], seen[word] = word, true end
    if #words >= 2000 then break end
  end
  cache[buf] = { tick = tick, words = words }
  return words
end

function M.words()
  local words, seen = {}, {}
  local buffers = { api.nvim_get_current_buf() }
  vim.list_extend(buffers, api.nvim_list_bufs())
  for _, buf in ipairs(buffers) do
    for _, word in ipairs(not seen[buf] and buffer_words(buf) or {}) do
      if not seen[word] then words[#words + 1], seen[word] = word, true end
    end
    seen[buf] = true
    if #words >= 4000 then break end
  end
  return words
end

local function path_context(before)
  local quoted = before:match("[\"']([^\"']*)$")
  local path = quoted or before:reverse():match("^[%w_./~%-]*"):reverse()
  local dir, name = path:match("^(.*[/])([^/]*)$")
  dir, name = dir or "./", name or path
  local keyword = vim.fn.match(before, [[\k*$]])
  local file = quoted ~= nil or path:find("/", 1, true) ~= nil or path:match("^[.~]") ~= nil
  local fixed = name:sub(1, math.max(0, keyword - (#before - #name)))
  return dir, keyword, file or (#path > 0 and #path == #before - keyword), fixed
end

function M.source(findstart, base)
  if not eligible(0) or too_big(0) then return findstart == 1 and -3 or {} end
  local dir, col, paths, fixed = path_context(before_cursor())
  if findstart == 1 then startcol = col return col end
  local matches = {}
  for _, word in ipairs(vim.fn.matchfuzzy(M.words(), base)) do
    if word ~= base then matches[#matches + 1] = item(word, "Text", "buf") end
    if #matches >= 80 then break end
  end
  if not paths then return { words = matches, refresh = "always" } end
  local count = 0
  local ok, entries = pcall(vim.fn.readdir, vim.fn.expand(dir), function()
    count = count + 1
    return count <= 256 and 1 or -1
  end)
  for _, name in ipairs(ok and entries or {}) do
    local suffix = name:sub(#fixed + 1)
    if name:sub(1, #fixed) == fixed and (base == "" or #vim.fn.matchfuzzy({ suffix }, base) > 0) then
      local folder = vim.fn.isdirectory(vim.fn.expand(dir) .. name) == 1
      local entry = item(name .. (folder and "/" or ""), folder and "Folder" or "File", "path")
      entry.word = suffix .. (folder and "/" or "")
      matches[#matches + 1] = entry
    end
  end
  return { words = matches, refresh = "always" }
end

local function convert(entry)
  local kind = vim.lsp.protocol.CompletionItemKind[entry.kind] or "Text"
  return { kind = kind_icons[kind] or "¶", kind_hlgroup = "AosCmpKind" .. kind, menu = "" }
end

local function enable(ev)
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  if not client or not eligible(ev.buf) or not client:supports_method("textDocument/completion") then return end
  vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = false, convert = convert })
end

local function clear_ghost(buf)
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

local function docs()
  local info = vim.fn.complete_info({ "selected" })
  local win, buf = info.preview_winid, info.preview_bufnr
  if not win or not api.nvim_win_is_valid(win) then return end
  api.nvim_win_set_config(win, { border = "single", title = " ❯ docs ", title_pos = "left" })
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^%s*[-*_]%s*[-*_]%s*[-*_][-*_ ]*$") then
      api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        virt_text = { { ("─"):rep(api.nvim_win_get_width(win)), "AosCmpDocSeparator" } }, virt_text_pos = "overlay",
      })
    end
  end
end

-- Native convert() is shared by all clients; their identities arrive in user_data afterwards.
local function sources(info)
  local changed, columns, last_client = false, {}, nil
  local row = api.nvim_win_get_cursor(0)[1] - 1
  for _, entry in ipairs(info.items) do
    local id = vim.tbl_get(entry, "user_data", "nvim", "lsp", "client_id")
    local client = id and vim.lsp.get_client_by_id(id)
    if client and entry.menu ~= client.name then entry.menu, changed = client.name, true end
    local raw = vim.tbl_get(entry, "user_data", "nvim", "lsp", "completion_item")
    if not raw then
      local kind = entry.menu == "buf" and "Text" or entry.word:sub(-1) == "/" and "Folder" or "File"
      entry.kind_hlgroup = "AosCmpKind" .. kind
    end
    if raw then
      local edit = raw.textEdit and (raw.textEdit.range or raw.textEdit.insert)
      if client and edit and edit.start.line == row then
        local col = vim.str_byteindex(api.nvim_get_current_line(), client.offset_encoding, edit.start.character, false)
        columns[id], last_client = math.min(columns[id] or col, col), id
      end
      local appearance = convert(raw)
      entry.kind, entry.kind_hlgroup = appearance.kind, appearance.kind_hlgroup
      if raw.deprecated or vim.list_contains(raw.tags or {}, 1) then entry.abbr_hlgroup = "AosCmpLabelDeprecated" end
    end
  end
  if not changed then return end
  startcol = columns[last_client] or startcol
  for _, entry in ipairs(info.items) do
    local col = vim.tbl_get(entry, "user_data", "aos_start")
    if col then
      entry.word = api.nvim_get_current_line():sub(startcol + 1, col) .. entry.word:sub(math.max(1, startcol - col + 1))
      entry.user_data.aos_start = startcol
    end
  end
  vim.fn.complete(startcol + 1, info.items)
  if info.selected >= 0 then api.nvim_select_popupmenu_item(info.selected, false, false, {}) end
end

-- The info popup appears only once the item's documentation resolves, so style it again shortly after.
local function docs_soon()
  docs()
  for _, delay in ipairs({ 40, 150, 400 }) do vim.defer_fn(docs, delay) end
end

local function preview()
  local buf = api.nvim_get_current_buf()
  clear_ghost(buf)
  if vim.fn.pumvisible() == 0 or not eligible(buf) then return end
  local info = vim.fn.complete_info({ "items", "selected", "completed" })
  sources(info)
  local entry = info.completed
  if info.selected < 0 or not entry or not entry.word then return end
  local prefix = before_cursor():sub(startcol + 1)
  local positions = vim.fn.matchfuzzypos({ entry.word }, prefix)[2][1] or {}
  local last = positions[#positions]
  local offset = last and vim.str_byteindex(entry.word, "utf-32", last + 1, false) or #prefix
  local rest = entry.word:sub(offset + 1)
  if rest ~= "" then
    local pos = api.nvim_win_get_cursor(0)
    api.nvim_buf_set_extmark(buf, ns, pos[1] - 1, pos[2], { virt_text = { { rest, "AosGhost" } }, virt_text_pos = "inline" })
  end
  docs_soon()
end

local function feed(keys) api.nvim_feedkeys(vim.keycode(keys), "ni", false) end

local function select(delta)
  if vim.fn.pumvisible() == 0 then return end
  local info = vim.fn.complete_info({ "selected", "matches" })
  local selected = (info.selected + delta + 1) % (#info.matches + 1) - 1
  api.nvim_select_popupmenu_item(selected, false, false, {})
end

local function tab(direction)
  if vim.fn.pumvisible() == 1 then return select(direction) end
  if vim.snippet.active({ direction = direction }) then return vim.snippet.jump(direction) end
  if direction == 1 and require("core.complete").accept() then return end
  feed(direction == 1 and "<Tab>" or "<C-d>")
end

local function scroll(delta, fallback)
  local win = vim.fn.complete_info({ "selected" }).preview_winid
  if not win or not api.nvim_win_is_valid(win) then return feed(fallback) end
  api.nvim_win_call(win, function() vim.cmd("normal! " .. (delta > 0 and "\6" or "\2")) end)
end

local function insert(ev)
  if not eligible(ev.buf) then vim.bo[ev.buf].autocomplete = false return end
  vim.bo[ev.buf].complete = "Fv:lua.require'core.cmp'.source,o"
  vim.bo[ev.buf].autocomplete = true
  local map = function(key, action) vim.keymap.set("i", key, action, { buffer = ev.buf }) end
  map("<Tab>", function() tab(1) end)
  map("<S-Tab>", function() tab(-1) end)
  for key, delta in pairs({ ["<Down>"] = 1, ["<Up>"] = -1, ["<C-n>"] = 1, ["<C-p>"] = -1 }) do
    vim.keymap.set("i", key, function()
      if vim.fn.pumvisible() == 0 then return key end
      return delta > 0 and "<Down>" or "<Up>"
    end, { buffer = ev.buf, expr = true })
  end
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 0 then return fallback_enter and fallback_enter() or "<CR>" end
    return vim.fn.complete_info({ "selected" }).selected >= 0 and "<C-y>" or "<C-e><CR>"
  end, { buffer = ev.buf, expr = true })
  map("<C-e>", function() feed("<C-e>") end)
  map("<C-b>", function() scroll(-1, "<C-b>") end)
  map("<C-f>", function() scroll(1, "<C-f>") end)
end

local function close_signature()
  if signature.win and api.nvim_win_is_valid(signature.win) then api.nvim_win_close(signature.win, true) end
  signature = {}
end

local function call_position()
  return vim.fn.searchpairpos("(", "", ")", "bnW", "", math.max(1, vim.fn.line(".") - 100), 5)
end

local function signature_result(results, buf, tick, serial)
  if serial ~= generation or api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= "i" or vim.b[buf].changedtick ~= tick then return end
  for id, response in pairs(results) do
    local result = response.result
    if result and result.signatures and #result.signatures > 0 then
      local client = vim.lsp.get_client_by_id(id)
      local triggers = client and client.server_capabilities.signatureHelpProvider.triggerCharacters
      local lines, hl = vim.lsp.util.convert_signature_help_to_markdown_lines(result, vim.bo[buf].filetype, triggers)
      if not lines then break end
      -- A closing fence already draws a rule, so drop the `---` servers put right after it.
      lines = vim.iter(ipairs(lines)):filter(function(i, l)
        return not (l:match("^%s*[-*_][-*_%s]*$") and #l:gsub("%s", "") >= 3 and (lines[i - 1] or ""):match("^%s*```%s*$"))
      end):map(function(_, l) return l end):totable()
      close_signature()
      local fbuf, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
        border = "single", title = " ❯ signature ", title_pos = "left", max_width = 80, focusable = false,
        close_events = { "InsertLeave", "BufLeave" },
      })
      signature = { win = win, call = call_position() }
      if hl then vim.hl.range(fbuf, ns, "AosCmpSignatureHelpActiveParameter", { hl[1], hl[2] }, { hl[3], hl[4] }) end
      return
    end
  end
  close_signature()
end

local function changed()
  generation = generation + 1
  local serial, buf = generation, api.nvim_get_current_buf()
  if not eligible(buf) then return end
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/signatureHelp" })
  if #clients == 0 then close_signature() return end
  local call = call_position()
  if signature.call and not vim.deep_equal(signature.call, call) then close_signature() end
  if call[1] == 0 then return end
  local char = before_cursor():sub(-1)
  local triggered = signature.win ~= nil
  for _, client in ipairs(clients) do
    local provider = client.server_capabilities.signatureHelpProvider
    triggered = triggered or vim.list_contains(provider.triggerCharacters or {}, char) or vim.list_contains(provider.retriggerCharacters or {}, char)
  end
  if not triggered or #clients == 0 then return end
  vim.defer_fn(function()
    if serial ~= generation or vim.fn.mode() ~= "i" then return end
    local tick = vim.b[buf].changedtick
    vim.lsp.buf_request_all(buf, "textDocument/signatureHelp", function(client)
      return vim.lsp.util.make_position_params(0, client.offset_encoding)
    end, function(results) signature_result(results, buf, tick, serial) end)
  end, 80)
end

function M.setup(buf)
  for _, keymap in ipairs(api.nvim_get_keymap("i")) do
    if keymap.lhs == "<CR>" then fallback_enter = keymap.callback end
  end
  vim.keymap.del("i", "<Tab>")
  vim.opt.completeopt = { "menu", "menuone", "noselect", "noinsert", "fuzzy", "popup" }
  vim.o.completeitemalign = "kind,abbr,menu"
  vim.o.pumborder, vim.o.pummaxwidth = "single", 80
  vim.o.autocompletedelay = 80
  vim.on_key(function(key)
    -- During collection, native completion consumes Ctrl-N/P before insert mappings.
    local delta = key == "\14" and 1 or key == "\16" and -1 or nil
    if not delta or vim.fn.mode() ~= "i" or not eligible(0) or vim.fn.pumvisible() == 0 then return end
    feed(delta > 0 and "<Down>" or "<Up>")
    return ""
  end, ns)
  local group = api.nvim_create_augroup("CoreCmp", {})
  api.nvim_create_autocmd("InsertEnter", { group = group, callback = insert })
  api.nvim_create_autocmd("LspAttach", { group = group, callback = enable })
  api.nvim_create_autocmd("CompleteChanged", { group = group, callback = function() vim.schedule(preview) end })
  api.nvim_create_autocmd("WinNew", { group = group, callback = function() vim.schedule(docs) end })
  api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, { group = group, callback = changed })
  api.nvim_create_autocmd({ "CompleteDone", "InsertLeave", "BufLeave" }, {
    group = group, callback = function(ev) clear_ghost(ev.buf) end,
  })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group, callback = function() generation = generation + 1 close_signature() end,
  })
  api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev) cache[ev.buf] = nil end })
  for _, client in ipairs(vim.lsp.get_clients()) do
    for attached in pairs(client.attached_buffers) do enable({ buf = attached, data = { client_id = client.id } }) end
  end
  if buf then insert({ buf = buf }) end
end

return M
