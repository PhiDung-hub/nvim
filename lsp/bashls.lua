---@type vim.lsp.Config
return {
  cmd = { "bash-language-server", "start" },
  -- Upstream's recursive "**/*@(...)" glob scans the whole tree when a script sits in $HOME.
  settings = { bashIde = { globPattern = vim.env.GLOB_PATTERN or "*@(.sh|.inc|.bash|.command)" } },
  filetypes = { "bash", "sh" },
}
