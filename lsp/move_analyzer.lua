---@type vim.lsp.Config
return {
  cmd = { "move-analyzer" },
  filetypes = { "move" },
  root_markers = { "Move.toml" },
  workspace_required = true,
}
