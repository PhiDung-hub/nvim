---@type vim.lsp.Config
return {
  cmd = { "pyright-langserver", "--stdio" },
  filetypes = { "python" },
  root_markers = { "pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", ".git" },
  settings = {
    pyright = { disableTaggedHints = true },
    python = { analysis = { autoSearchPaths = true, useLibraryCodeForTypes = true, diagnosticMode = "openFilesOnly" } },
  },
  on_attach = function(client, buf)
    vim.api.nvim_buf_create_user_command(buf, "LspPyrightOrganizeImports", function()
      -- Private command (not advertised), so client:exec_cmd() refuses it.
      local params = { command = "pyright.organizeimports", arguments = { vim.uri_from_bufnr(buf) } }
      client:request("workspace/executeCommand", params, nil, buf)
    end, { desc = "Organize Imports" })
  end,
}
