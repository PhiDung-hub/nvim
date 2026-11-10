---@type vim.lsp.Config
return {
  cmd = require("core.lsp").node_cmd("vscode-html-language-server", "--stdio"),
  filetypes = { "html" },
  root_markers = { "package.json", ".git" },
  settings = {},
  init_options = {
    provideFormatter = true,
    embeddedLanguages = { css = true, javascript = true },
    configurationSection = { "html", "css", "javascript" },
  },
}
