---@type vim.lsp.Config
return {
  cmd = { "clangd" },
  filetypes = { "c", "c.doxygen", "cpp", "cpp.doxygen", "objc", "objcpp", "cuda" },
  root_markers = {
    ".clangd", ".clang-tidy", ".clang-format", "compile_commands.json", "compile_flags.txt", "configure.ac", ".git",
  },
  get_language_id = function(_, ft)
    return ({ objc = "objective-c", objcpp = "objective-cpp", cuda = "cuda-cpp" })[ft] or ft
  end,
  capabilities = {
    textDocument = { completion = { editsNearCursor = true } },
    offsetEncoding = { "utf-8", "utf-16" },
  },
  on_init = function(client, result)
    if result.offsetEncoding then client.offset_encoding = result.offsetEncoding end
  end,
  on_attach = function(client, buf)
    vim.api.nvim_buf_create_user_command(buf, "LspClangdSwitchSourceHeader", function()
      client:request("textDocument/switchSourceHeader", vim.lsp.util.make_text_document_params(buf), function(err, uri)
        if err or not uri then return vim.notify("No matching source/header", vim.log.levels.WARN) end
        vim.cmd.edit(vim.uri_to_fname(uri))
      end, buf)
    end, { desc = "Switch between source/header" })
    vim.api.nvim_buf_create_user_command(buf, "LspClangdShowSymbolInfo", function()
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
      client:request("textDocument/symbolInfo", params, function(err, res)
        if err or not res or #res == 0 then return end
        local container = res[1].containerName
        local lines = { "name: " .. res[1].name, "container: " .. (type(container) == "string" and container or "") }
        vim.lsp.util.open_floating_preview(lines, "", { focusable = false, focus = false, title = "Symbol Info" })
      end, buf)
    end, { desc = "Show symbol info" })
  end,
}
