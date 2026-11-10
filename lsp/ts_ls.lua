local lsp = require("core.lsp")

local function show(client, uri, pos)
  vim.lsp.util.show_document({ uri = uri, range = { start = pos, ["end"] = pos } }, client.offset_encoding)
end

---@type vim.lsp.Config
return {
  cmd = lsp.node_cmd("typescript-language-server", "--stdio"),
  init_options = { hostInfo = "neovim" },
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  root_dir = lsp.ts_root(true),
  handlers = {
    -- Refactors such as "extract function" ask the client to start a rename at the new symbol.
    ["_typescript.rename"] = function(_, result, ctx)
      show(assert(vim.lsp.get_client_by_id(ctx.client_id)), result.textDocument.uri, result.position)
      vim.lsp.buf.rename()
      return vim.NIL
    end,
  },
  commands = {
    ["editor.action.showReferences"] = function(command, ctx)
      local client = assert(vim.lsp.get_client_by_id(ctx.client_id))
      local uri, pos, refs = unpack(command.arguments)
      local items = vim.lsp.util.locations_to_items(refs, client.offset_encoding)
      vim.fn.setqflist({}, " ", { title = command.title, items = items, context = { command = command, bufnr = ctx.bufnr } })
      show(client, uri, pos)
      vim.cmd("botright copen")
    end,
  },
  on_attach = function(client) client.server_capabilities.documentFormattingProvider = false end,
}
