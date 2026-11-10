-- Native LSP (vim.lsp.config/enable); each server lives in lsp/<name>.lua.
local M = {}

-- Servers that are always wanted; extras are enabled only when their binary is installed.
local servers = {
  "ts_ls", "tsc", "rust_analyzer", "emmet_ls", "tailwindcss", "svelte", "jsonls", "html", "cssls", "ruff",
  "solidity_ls_nomicfoundation", "move_analyzer",
}
local extras = {
  pyright = "pyright-langserver", clangd = "clangd", bashls = "bash-language-server", lua_ls = "lua-language-server",
  taplo = "taplo", yamlls = "yaml-language-server", prismals = "prisma-language-server",
  copilot = "copilot-language-server",
}

-- cmd that prefers the project's node_modules/.bin copy of `bin`.
function M.node_cmd(bin, ...)
  local args = { ... }
  return function(dispatchers, config)
    local root = config and config.root_dir
    local local_bin = root and vim.fs.joinpath(root, "node_modules/.bin", bin)
    local exe = local_bin and vim.fn.executable(local_bin) == 1 and local_bin or bin
    return vim.lsp.rpc.start({ exe, unpack(args) }, dispatchers)
  end
end

-- typescript-language-server needs a tsserver.js; TypeScript 7 (native) ships none and serves LSP itself.
local function legacy_tsserver(root)
  for dir in vim.fs.parents(root .. "/x") do
    if vim.uv.fs_stat(dir .. "/node_modules/typescript/lib/tsserver.js") then return true end
  end
  return false
end

-- root_dir for ts_ls (legacy = true) or tsc (legacy = false); Deno projects get neither.
function M.ts_root(legacy)
  return function(buf, on_dir)
    if vim.fs.root(buf, { "deno.json", "deno.jsonc" }) then return end
    local locks = { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock" }
    local root = vim.fs.root(buf, { locks, { ".git" } }) or vim.fn.getcwd()
    if legacy_tsserver(root) == legacy then on_dir(root) end
  end
end

local LSP_MAX_BYTES = 512 * 1024

-- Servers get the whole file on didOpen, so a big file is refused before any server starts (`:let b:lsp_force = 1 | e` overrides).
local function too_big(buf)
  if vim.b[buf].lsp_force then return false end
  local size = vim.fn.getfsize(vim.api.nvim_buf_get_name(buf))
  if not vim.b[buf].bigfile and size <= LSP_MAX_BYTES then return false end
  if not vim.b[buf].lsp_off then
    vim.b[buf].lsp_off = true
    vim.notify(("○ LSP off · big file (%d KiB)"):format(size / 1024))
  end
  return true
end

local function on_attach(ev)
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  local buf = ev.buf
  if not client then return end

  require("ui.lsp").attach(buf, client)
  vim.keymap.set("n", "<leader>lh", function()
    vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = buf }), { bufnr = buf })
  end, { buffer = buf, desc = "Toggle inlay hints" })

  if client:supports_method("textDocument/documentHighlight") then
    local group = vim.api.nvim_create_augroup("LspHighlight" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, { buffer = buf, group = group, callback = vim.lsp.buf.document_highlight })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { buffer = buf, group = group, callback = vim.lsp.buf.clear_references })
  end
  if client:supports_method("textDocument/documentColor") then vim.lsp.document_color.enable(true, { bufnr = buf }) end
  if client:supports_method("textDocument/linkedEditingRange") then vim.lsp.linked_editing_range.enable(true, { client_id = client.id }) end
end

local function start()
  -- Requiring blink.cmp loads it before the first client starts, so every server gets its capabilities.
  -- One position encoding for every server, so copilot (UTF-16) and the rest agree on a shared buffer.
  local caps = require("blink.cmp").get_lsp_capabilities({ general = { positionEncodings = { "utf-16" } } })
  vim.lsp.config("*", { root_markers = { ".git" }, capabilities = caps })
  local lsp_start = vim.lsp.start
  vim.lsp.start = function(config, opts)
    local buf = opts and opts.bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(buf) and too_big(buf) then return end
    return lsp_start(config, opts)
  end
  vim.lsp.enable(servers)
  for name, bin in pairs(extras) do
    if vim.fn.executable(bin) == 1 then vim.lsp.enable(name) end
  end
  vim.api.nvim_create_autocmd("LspAttach", { group = vim.api.nvim_create_augroup("CoreLsp", {}), callback = on_attach })

  local s = vim.diagnostic.severity
  local glyphs = { [s.ERROR] = "✗", [s.WARN] = "!", [s.INFO] = "●", [s.HINT] = "·" }
  local hls = { [s.ERROR] = "AosFailed", [s.WARN] = "AosRunning", [s.INFO] = "AosId", [s.HINT] = "AosDim" }
  vim.diagnostic.config({
    underline = true,
    severity_sort = true,
    virtual_text = { spacing = 4, prefix = "" },
    float = {
      source = "if_many", header = "", title = " ❯ diagnostics ", title_pos = "left",
      prefix = function(d) return glyphs[d.severity] .. " ", hls[d.severity] end,
    },
    jump = { on_jump = function(_, bufnr) vim.diagnostic.open_float({ bufnr = bufnr, scope = "cursor", focus = false }) end },
    signs = { text = glyphs },
  })
  require("ui.lsp").setup()
end

-- Deferred to the first file read or created, so starting nvim without a file does no LSP work.
function M.setup()
  vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, { once = true, callback = start })
end

return M
