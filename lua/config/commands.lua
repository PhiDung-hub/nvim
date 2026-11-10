-- Everyday commands in one place, plus a palette (`<leader>:`) over every described keymap and command.
local cmd = vim.api.nvim_create_user_command

for typo, real in pairs({ Q = "q", Qa = "qa", QA = "qa", W = "w", Wq = "wq", WQ = "wq", Wa = "wa", Wqa = "wqa" }) do
  cmd(typo, real .. "<bang> <args>", { bang = true, nargs = "*", complete = "file" })
end

-- nvim-lspconfig's names, over nvim 0.12's built-in `:lsp` and health check.
cmd("LspInfo", "checkhealth vim.lsp", { desc = "LSP clients and config health" })
cmd("LspRestart", "lsp restart <args>", { nargs = "*", desc = "Restart LSP clients on this buffer" })
cmd("LspLog", function() vim.cmd.tabedit(vim.lsp.log.get_filename()) end, { desc = "Open the LSP log" })

-- Palette ranking survives restarts: uppercase globals are saved in shada ('!' flag).
local function uses() return vim.g.AOS_PALETTE or {} end

local function bump(key)
  local counts = uses()
  counts[key] = (counts[key] or 0) + 1
  vim.g.AOS_PALETTE = counts
end

local function entries()
  local items, label = {}, require("ui.keys").label
  local maps = vim.list_extend(vim.api.nvim_get_keymap("n"), vim.api.nvim_buf_get_keymap(0, "n"))
  for _, m in ipairs(maps) do
    if m.desc and not m.lhs:match("^<Plug>") then
      items[#items + 1] = { key = m.lhs, id = label(m.lhs), text = m.desc }
    end
  end
  local commands = vim.tbl_extend("force", vim.api.nvim_get_commands({}), vim.api.nvim_buf_get_commands(0, {}))
  for name, c in pairs(commands) do
    items[#items + 1] = { key = ":" .. name, id = ":" .. name, text = c.definition ~= "" and c.definition or name, nargs = c.nargs }
  end
  local counts = uses()
  for _, it in ipairs(items) do
    it.count = counts[it.key] or 0
    it.glyph, it.hl = it.count > 0 and "●" or "○", it.count > 0 and "AosDone" or "AosFaint"
  end
  table.sort(items, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.id < b.id
  end)
  return items
end

local function run(item)
  bump(item.key)
  if item.key:sub(1, 1) ~= ":" then return vim.api.nvim_feedkeys(vim.keycode(item.key), "m", false) end
  if item.nargs == "0" then return vim.cmd(item.key:sub(2)) end
  vim.api.nvim_feedkeys(item.key .. " ", "n", false)
end

vim.keymap.set("n", "<leader>:", function()
  require("ui.pick").open({ title = "commands", items = entries(), on_choose = run })
end, { desc = "Command palette" })

cmd("Keys", function(o) require("ui.keys").open(o.args) end, {
  nargs = "?", desc = "Hotkey help: every key, one table per tab", complete = function(lead) return require("ui.keys").complete(lead) end,
})
vim.keymap.set("n", "<leader>?", function() require("ui.keys").open() end, { desc = "Hotkey help" })
