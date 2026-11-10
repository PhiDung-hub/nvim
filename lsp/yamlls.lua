---@type vim.lsp.Config
return {
  cmd = require("core.lsp").node_cmd("yaml-language-server", "--stdio"),
  filetypes = { "yaml", "yaml.docker-compose", "yaml.gitlab", "yaml.helm-values" },
  settings = {
    redhat = { telemetry = { enabled = false } },
    yaml = { format = { enable = true } },
  },
  -- Formatting is off by default upstream; yaml.format.enable turns it on, this lets nvim request it.
  on_init = function(client) client.server_capabilities.documentFormattingProvider = true end,
}
