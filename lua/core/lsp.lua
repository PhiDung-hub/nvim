-- Native LSP (vim.lsp.config/enable); nvim-lspconfig supplies only the server defaults.
local M = {}

local home = vim.env.HOME
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

-- typescript-language-server needs a tsserver.js; TypeScript 7 (native) ships none and serves LSP itself.
local function legacy_tsserver(root)
  for dir in vim.fs.parents(root .. "/x") do
    if vim.uv.fs_stat(dir .. "/node_modules/typescript/lib/tsserver.js") then return true end
  end
  return false
end

local function ts_root(buf)
  if vim.fs.root(buf, { "deno.json", "deno.jsonc" }) then return nil end
  local locks = { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock" }
  return vim.fs.root(buf, { locks, { ".git" } }) or vim.fn.getcwd()
end

local function tsc_cmd(dispatchers, config)
  local root = config.root_dir or vim.fn.getcwd()
  local candidates = { root .. "/node_modules/.bin/tsc", root .. "/node_modules/.bin/tsgo", "tsc", "tsgo" }
  local exe = vim.iter(candidates):find(function(c) return vim.fn.executable(c) == 1 end)
  return vim.lsp.rpc.start({ exe, "--lsp", "--stdio" }, dispatchers)
end

local function configure()
  -- One position encoding for every server, so copilot (UTF-16) and the rest agree on a shared buffer.
  vim.lsp.config("*", { root_markers = { ".git" }, capabilities = { general = { positionEncodings = { "utf-16" } } } })
  vim.lsp.config("ts_ls", {
    root_dir = function(buf, on_dir)
      local root = ts_root(buf)
      if root and legacy_tsserver(root) then on_dir(root) end
    end,
    on_attach = function(client) client.server_capabilities.documentFormattingProvider = false end,
  })
  vim.lsp.config("tsc", {
    cmd = tsc_cmd,
    root_dir = function(buf, on_dir)
      local root = ts_root(buf)
      if root and not legacy_tsserver(root) then on_dir(root) end
    end,
    on_attach = function(client) client.server_capabilities.documentFormattingProvider = false end,
  })

  -- rustup's rust-analyzer matches the active toolchain; Mason's standalone build may not.
  local rustup_ra = home .. "/.cargo/bin/rust-analyzer"
  vim.lsp.config("rust_analyzer", {
    cmd = { vim.fn.executable(rustup_ra) == 1 and rustup_ra or "rust-analyzer" },
    settings = {
      ["rust-analyzer"] = {
        check = { command = "clippy" },
        cargo = { allFeatures = true },
        procMacro = { enable = true },
      },
    },
  })

  vim.lsp.config("emmet_ls", {
    filetypes = { "html", "htmldjango", "typescriptreact", "javascriptreact", "css", "sass", "scss", "less" },
    init_options = { html = { options = { ["bem.enabled"] = true, ["jsx.enabled"] = true } } },
  })
  vim.lsp.config("solidity_ls_nomicfoundation", {
    cmd = { "nomicfoundation-solidity-language-server", "--stdio" },
    filetypes = { "solidity" },
    root_markers = { "hardhat.config.js", "hardhat.config.ts", "foundry.toml", ".git" },
  })
  vim.lsp.config("move_analyzer", { cmd = { "move-analyzer" }, filetypes = { "move" }, root_markers = { "Move.toml" }, workspace_required = true })
  vim.lsp.config("lua_ls", {
    settings = { Lua = { runtime = { version = "LuaJIT" }, workspace = { library = { vim.env.VIMRUNTIME } } } },
  })
end

local function on_attach(ev)
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  local buf = ev.buf
  if not client then return end
  if vim.b[buf].bigfile then return vim.schedule(function() vim.lsp.buf_detach_client(buf, client.id) end) end

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

function M.setup()
  configure()
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

return M
