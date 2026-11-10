-- Git branch for the tabline and change signs against the index (replaces gitsigns).
local M = {}
local ns = vim.api.nvim_create_namespace("core.git")
local branches = {}

function M.branch()
  local cwd = vim.fn.getcwd()
  if branches[cwd] == nil then
    branches[cwd] = false
    vim.system({ "git", "branch", "--show-current" }, { cwd = cwd, text = true }, function(r)
      branches[cwd] = r.code == 0 and vim.trim(r.stdout) ~= "" and vim.trim(r.stdout) or false
      vim.schedule(function() vim.cmd.redrawtabline() end)
    end)
  end
  return branches[cwd] or nil
end

local function place(buf, hunks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local _, old_n, start, new_n = unpack(h)
    local kind = old_n == 0 and "GitAdd" or new_n == 0 and "GitDelete" or "GitChange"
    local text = kind == "GitDelete" and "▁" or "▎"
    local first = math.max(math.min(start - 1, last - 1), 0)
    for l = first, math.min(first + math.max(new_n, 1) - 1, last - 1) do
      vim.api.nvim_buf_set_extmark(buf, ns, l, 0, { sign_text = text, sign_hl_group = kind, priority = 5 })
    end
  end
end

-- `git show :path` is the index copy; untracked files get no signs.
local function refresh(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" or vim.b[buf].bigfile then return end
  local dir = vim.fs.dirname(path)
  vim.system({ "git", "-C", dir, "show", ":./" .. vim.fs.basename(path) }, { text = true }, function(r)
    if r.code ~= 0 then return end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local now = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
      place(buf, vim.text.diff(r.stdout, now, { result_type = "indices", algorithm = "histogram" }))
    end)
  end)
end

local timers = {}
local function debounced(ev)
  local buf = ev.buf
  timers[buf] = timers[buf] or vim.uv.new_timer()
  timers[buf]:start(300, 0, vim.schedule_wrap(function() refresh(buf) end))
end

local group = vim.api.nvim_create_augroup("CoreGit", {})
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, { group = group, callback = function(ev) refresh(ev.buf) end })
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, { group = group, callback = debounced })
vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained" }, { group = group, callback = function() branches = {} end })
vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(ev)
    if timers[ev.buf] then timers[ev.buf]:close() end
    timers[ev.buf] = nil
  end,
})

return M
