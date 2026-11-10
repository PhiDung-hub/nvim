-- Format-on-save and solhint diagnostics (replaces conform.nvim and nvim-lint).
local M = {}

local prettier = {
  { "prettierd", "$FILE" },
  { "prettier", "--stdin-filepath", "$FILE" },
}
local by_ft = {
  lua = { { "stylua", "--search-parent-directories", "--stdin-filepath", "$FILE", "-" } },
  solidity = { { "forge", "fmt", "--raw", "-" } },
}
for _, ft in ipairs({ "javascript", "javascriptreact", "typescript", "typescriptreact", "json", "html", "css", "scss", "markdown", "yaml", "svelte" }) do
  by_ft[ft] = prettier
end

local function formatter(ft)
  for _, cmd in ipairs(by_ft[ft] or {}) do
    if vim.fn.executable(cmd[1]) == 1 then return cmd end
  end
end

-- Only the changed hunks are replaced, so marks, folds and the cursor survive.
local function apply(buf, old, new)
  local hunks = vim.text.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
  for i = #hunks, 1, -1 do
    local a, an, b, bn = unpack(hunks[i])
    local first = an == 0 and a or a - 1
    vim.api.nvim_buf_set_lines(buf, first, first + an, false, vim.list_slice(new, b, b + bn - 1))
  end
end

function M.format(buf, sync)
  buf = buf or vim.api.nvim_get_current_buf()
  local cmd = formatter(vim.bo[buf].filetype)
  if not cmd then return vim.lsp.buf.format({ bufnr = buf, async = not sync }) end
  local file = vim.api.nvim_buf_get_name(buf)
  local argv = vim.tbl_map(function(a) return a == "$FILE" and file or a end, cmd)
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = vim.b[buf].changedtick
  local function done(r)
    if r.code ~= 0 then return vim.notify(("✗ %s: %s"):format(cmd[1], vim.trim(r.stderr or "")), vim.log.levels.WARN) end
    if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then return end
    local new = vim.split(r.stdout:gsub("\n$", ""), "\n", { plain = true })
    apply(buf, old, new)
  end
  local opts = { stdin = table.concat(old, "\n") .. "\n", text = true, cwd = vim.fs.dirname(file) }
  if sync then return done(vim.system(argv, opts):wait(3000)) end
  vim.system(argv, opts, vim.schedule_wrap(done))
end

local lint_ns = vim.api.nvim_create_namespace("core.solhint")
local function solhint(buf)
  if vim.fn.executable("solhint") == 0 then return end
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  vim.system({ "solhint", "stdin" }, { stdin = text, text = true, cwd = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)) }, vim.schedule_wrap(function(r)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local diags = {}
    for lnum, col, sev, msg, code in (r.stdout or ""):gmatch("(%d+):(%d+)%s+(%w+)%s+([^\n]-)%s+(%S+)\n") do
      diags[#diags + 1] = {
        lnum = tonumber(lnum) - 1, col = tonumber(col) - 1, message = msg, code = code, source = "solhint",
        severity = sev == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
      }
    end
    vim.diagnostic.set(lint_ns, buf, diags)
  end))
end

function M.setup()
  local group = vim.api.nvim_create_augroup("CoreFormat", {})
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].bigfile or not vim.g.autoformat then return end
      M.format(ev.buf, true)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, { group = group, pattern = "*.sol", callback = function(ev) solhint(ev.buf) end })
  vim.api.nvim_create_user_command("FormatToggle", function()
    vim.g.autoformat = not vim.g.autoformat
    vim.notify(vim.g.autoformat and "✓ format on save" or "○ format on save off")
  end, {})
end

return M
