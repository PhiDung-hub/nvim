---@type vim.lsp.Config
return {
  cmd = require("core.lsp").node_cmd("vscode-json-language-server", "--stdio"),
  filetypes = { "json", "jsonc" },
  init_options = { provideFormatter = true },
}
