local function request(client, method, done)
  client:request(method, vim.empty_dict(), function(err, result)
    if err then return vim.notify(err.message, vim.log.levels.ERROR) end
    done(result)
  end)
end

local function sign_in(client, buf)
  request(client, "signIn", function(result)
    if result.status == "AlreadySignedIn" then return vim.notify("Already signed in as " .. result.user .. ".") end
    if result.status == "PromptUserDeviceFlow" then
      vim.notify("Enter your one-time code " .. result.userCode .. " in " .. result.verificationUri)
    end
    if not result.command then return end
    vim.fn.setreg("+", result.userCode)
    vim.fn.setreg("*", result.userCode)
    local open = vim.fn.confirm("Copied your one-time code to clipboard.\nOpen the browser to complete the sign-in process?", "&Yes\n&No")
    if open ~= 1 then return end
    client:exec_cmd(result.command, { bufnr = buf }, function(err, res)
      if err then return vim.notify(err.message, vim.log.levels.ERROR) end
      if res.status == "OK" then vim.notify("Signed in as " .. res.user .. ".") end
    end)
  end)
end

-- `vim.version()` builds the whole API description (1.4 ms a call); the banner is 30x cheaper.
local version = vim.fn.execute("version"):match("NVIM v(%S+)") or "0"

---@type vim.lsp.Config
return {
  cmd = { "copilot-language-server", "--stdio" },
  init_options = {
    editorInfo = { name = "Neovim", version = version },
    editorPluginInfo = { name = "Neovim", version = version },
  },
  settings = { telemetry = { telemetryLevel = "off" } },
  on_attach = function(client, buf)
    vim.api.nvim_buf_create_user_command(buf, "LspCopilotSignIn", function() sign_in(client, buf) end,
      { desc = "Sign in Copilot with GitHub" })
    vim.api.nvim_buf_create_user_command(buf, "LspCopilotSignOut", function()
      request(client, "signOut", function(result)
        if result.status == "NotSignedIn" then vim.notify("Not signed in.") end
      end)
    end, { desc = "Sign out Copilot with GitHub" })
  end,
}
