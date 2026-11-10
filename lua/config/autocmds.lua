local group = vim.api.nvim_create_augroup("Config", {})
local au = function(event, opts) vim.api.nvim_create_autocmd(event, vim.tbl_extend("force", { group = group }, opts)) end

-- External writes (agents, git): autoread reloads unchanged buffers once nvim checks timestamps.
local function checktime()
  if vim.fn.mode():sub(1, 1) == "c" or vim.fn.getcmdwintype() ~= "" then return end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then return end
  vim.cmd.checktime(buf)
end
au({ "FocusGained", "BufEnter", "TermLeave" }, { callback = function() vim.schedule(checktime) end })
vim.fn.timer_start(1000, function() checktime() end, { ["repeat"] = -1 })

-- Big files: decided on every read, so a file that grew past the cutoff is reclassified.
local BIG = 1.5 * 1024 * 1024
au("BufReadPre", {
  callback = function(ev)
    local stat = vim.uv.fs_stat(ev.match)
    local big = stat and stat.size >= BIG or false
    vim.b[ev.buf].bigfile = big
    if not big then return end
    vim.bo[ev.buf].swapfile, vim.bo[ev.buf].undolevels = false, -1
  end,
})
au("BufReadPost", {
  callback = function(ev)
    if not vim.b[ev.buf].bigfile then return end
    pcall(vim.treesitter.stop, ev.buf)
    vim.bo[ev.buf].syntax = "off"
    -- [0][0] = this window and buffer only (:setlocal); plain vim.wo would also change the global value.
    local wo = vim.wo[0][0]
    wo.foldmethod, wo.list, wo.spell = "manual", false, false
  end,
})

-- Sessions per working directory (replaces persistence.nvim).
local session_dir = vim.fn.stdpath("state") .. "/sessions/"
local function session_file(cwd) return session_dir .. (cwd or vim.fn.getcwd()):gsub("[/\\:]", "%%") .. ".vim" end
au("VimLeavePre", {
  callback = function()
    if #require("ui.tabline").listed() == 0 then return end
    vim.fn.mkdir(session_dir, "p")
    vim.cmd("mksession! " .. vim.fn.fnameescape(session_file()))
    vim.fn.writefile({ vim.fn.getcwd() }, session_dir .. "last")
  end,
})
_G.AosSession = function(last)
  local cwd
  if last then
    if not vim.uv.fs_stat(session_dir .. "last") then return vim.notify("○ no previous session") end
    cwd = vim.fn.readfile(session_dir .. "last")[1]
  end
  local file = session_file(cwd)
  if not vim.uv.fs_stat(file) then return vim.notify("○ no session for " .. vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":~")) end
  vim.cmd("silent! source " .. vim.fn.fnameescape(file))
end

-- Indent guides follow the buffer's shiftwidth (listchars is window-local).
local function guides()
  local sw = vim.fn.shiftwidth()
  vim.opt_local.listchars:append({ leadmultispace = "▏" .. (" "):rep(math.max(sw, 1) - 1) })
end
au({ "BufWinEnter", "FileType" }, { callback = guides })
au("OptionSet", { pattern = { "shiftwidth", "tabstop" }, callback = guides })

au("TextYankPost", { callback = function() vim.hl.on_yank({ timeout = 150 }) end })
