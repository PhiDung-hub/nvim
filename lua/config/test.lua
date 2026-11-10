-- Test mode: on with NVIM_TEST=1, or when -u points into a Claude scratchpad (/tmp/claude-*), so agent
-- test instances stay lean (no LSP, Copilot or llama-server unless NVIM_TEST_ENABLE=lsp,copilot,local)
-- and never outlive their test: quit when the last UI detaches, the parent dies, or NVIM_TEST_TTL s pass.
local M = { on = false, enabled = {} }

local function scratch_init()
  local argv = vim.v.argv
  for i, a in ipairs(argv) do
    if a == "-u" and (argv[i + 1] or ""):match("^/tmp/claude%-") then return true end
  end
end

-- True unless test mode is on and `feature` ("lsp", "copilot", "local") was not opted back in.
function M.allows(feature)
  return not M.on or M.enabled[feature] == true
end

local function quit(why)
  vim.schedule(function()
    io.stderr:write("nvim test mode: quitting (" .. why .. ")\n")
    for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
    vim.cmd("silent! qall!")
  end)
end

local function watch()
  local ppid, had_ui = vim.uv.os_getppid(), false
  vim.api.nvim_create_autocmd("UIEnter", { callback = function() had_ui = true end })
  vim.api.nvim_create_autocmd("UILeave", {
    callback = function()
      vim.defer_fn(function()
        if had_ui and #vim.api.nvim_list_uis() == 0 then quit("last UI detached") end
      end, 1000)
    end,
  })
  vim.uv.new_timer():start(5000, 5000, function()
    if vim.uv.os_getppid() ~= ppid then quit("parent exited") end
  end)
  local ttl = tonumber(vim.env.NVIM_TEST_TTL) or 900
  if ttl > 0 then vim.uv.new_timer():start(ttl * 1000, 0, function() quit("ttl " .. ttl .. " s") end) end
end

M.on = vim.env.NVIM_TEST == "1" or scratch_init() == true
if M.on then
  for f in (vim.env.NVIM_TEST_ENABLE or ""):gmatch("[%w_]+") do M.enabled[f] = true end
  vim.g.test_mode = true
  watch()
end

return M
