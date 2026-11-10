local M = {}

local MAX_HIGHLIGHT_BYTES = 512 * 1024

local function too_big(buf)
  if vim.b[buf].bigfile then return true end
  local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  return stat ~= nil and stat.size > MAX_HIGHLIGHT_BYTES
end

local function attach(ev)
  local buf = ev.buf
  if vim.bo[buf].buftype ~= "" then return end
  -- Runtime ftplugins (lua, markdown, help) start treesitter on their own; undo that here.
  if too_big(buf) then return pcall(vim.treesitter.stop, buf) end
  local lang = vim.treesitter.language.get_lang(ev.match)
  if not lang or not pcall(vim.treesitter.language.add, lang) then return end
  if not pcall(vim.treesitter.start, buf, lang) then return end
  if vim.treesitter.query.get(lang, "indents") then
    vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", { group = vim.api.nvim_create_augroup("TsAttach", {}), callback = attach })
  -- Buffers opened before the plugin finished loading.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
      attach({ buf = buf, match = vim.bo[buf].filetype })
    end
  end
end

return M
