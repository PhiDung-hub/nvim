---@type vim.lsp.Config
return {
  cmd = require("core.lsp").node_cmd("svelteserver", "--stdio"),
  filetypes = { "svelte" },
  settings = {
    typescript = {
      inlayHints = {
        parameterNames = { enabled = "literals", suppressWhenArgumentMatchesName = true },
        parameterTypes = { enabled = true },
        variableTypes = { enabled = true },
        propertyDeclarationTypes = { enabled = true },
        functionLikeReturnTypes = { enabled = true },
        enumMemberValues = { enabled = true },
      },
    },
  },
  root_dir = function(buf, on_dir)
    -- svelteserver only handles file:// buffers (sveltejs/language-tools#2777).
    if not vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf)) then return end
    local locks = { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "deno.lock" }
    on_dir(vim.fs.root(buf, { locks, { ".git" } }) or vim.fn.getcwd())
  end,
  on_attach = function(client, buf)
    -- svelteserver misses JS/TS changes made outside .svelte files (sveltejs/language-tools#2008).
    vim.api.nvim_create_autocmd("BufWritePost", {
      pattern = { "*.js", "*.ts" },
      group = vim.api.nvim_create_augroup("lsp.svelte", {}),
      callback = function(ev) client:notify("$/onDidChangeTsOrJsFile", { uri = ev.match }) end,
    })
    vim.api.nvim_buf_create_user_command(buf, "LspMigrateToSvelte5", function()
      local args = { vim.uri_from_bufnr(buf) }
      client:exec_cmd({ title = "Migrate Component to Svelte 5 Syntax", command = "migrate_to_svelte_5", arguments = args })
    end, { desc = "Migrate Component to Svelte 5 Syntax" })
  end,
}
