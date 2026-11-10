---@type vim.lsp.Config
return {
  cmd = function(dispatchers, config)
    local root = config.root_dir or vim.fn.getcwd()
    local candidates = { root .. "/node_modules/.bin/tsc", root .. "/node_modules/.bin/tsgo", "tsc", "tsgo" }
    local exe = vim.iter(candidates):find(function(c) return vim.fn.executable(c) == 1 end)
    return vim.lsp.rpc.start({ exe, "--lsp", "--stdio" }, dispatchers)
  end,
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  root_dir = require("core.lsp").ts_root(false),
  settings = {
    ["js/ts"] = {
      inlayHints = {
        parameterNames = { enabled = "literals", suppressWhenArgumentMatchesName = true },
        parameterTypes = { enabled = true },
        variableTypes = { enabled = true },
        propertyDeclarationTypes = { enabled = true },
        functionLikeReturnTypes = { enabled = true },
        enumMemberValues = { enabled = true },
      },
      referencesCodeLens = { enabled = true, showOnAllFunctions = true },
      implementationsCodeLens = { enabled = true, showOnInterfaceMethods = true, showOnAllClassMethods = true },
    },
  },
  on_attach = function(client) client.server_capabilities.documentFormattingProvider = false end,
}
