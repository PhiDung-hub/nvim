---@type vim.lsp.Config
return {
  cmd = { "emmet-ls", "--stdio" },
  filetypes = { "html", "htmldjango", "typescriptreact", "javascriptreact", "css", "sass", "scss", "less" },
  init_options = { html = { options = { ["bem.enabled"] = true, ["jsx.enabled"] = true } } },
}
