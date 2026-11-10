-- Incoming agent edits as reviewable hunks. Each buffer keeps a base (the last state the
-- human accepted); a reload from disk is diffed against it and drawn as an inline diff:
-- new lines tinted with a sign, removed lines as virtual lines, a `● agent · +n −m` note.
local M = {}
local ns = vim.api.nvim_create_namespace("agent.review")
local base, hunks = {}, {}
local MAX_OLD = 24

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function text(list) return table.concat(list, "\n") .. "\n" end

function M.pending(buf) return #(hunks[buf or vim.api.nvim_get_current_buf()] or {}) end

function M.total()
  local n = 0
  for buf, list in pairs(hunks) do
    if vim.api.nvim_buf_is_valid(buf) then n = n + #list end
  end
  return n
end

local function old_lines(old)
  local out = {}
  for i, l in ipairs(old) do
    if i > MAX_OLD then
      out[#out + 1] = { { ("  … %d more removed"):format(#old - MAX_OLD), "AosDim" } }
      break
    end
    out[#out + 1] = { { "- ", "AosFailed" }, { l, "AosAgentDelete" } }
  end
  return out
end

local function draw(buf, h, label)
  local last = vim.api.nvim_buf_line_count(buf)
  local row, above = h.new_start - 1, true
  if row >= last then row, above = math.max(last - 1, 0), false end
  local note = { { ("● %s · +%d −%d"):format(label, h.new_count, #h.old), "AosDim" } }
  local opts = { virt_text = note, virt_text_pos = "eol", priority = 20 }
  if h.new_count > 0 then
    opts.end_row = row + h.new_count
    opts.line_hl_group = h.old[1] and "AosAgentChange" or "AosAgentAdd"
    opts.sign_text, opts.sign_hl_group = "▌", "AosAgentSign"
  end
  if h.old[1] then
    opts.virt_lines, opts.virt_lines_above = old_lines(h.old), above
  end
  h.mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, opts)
end

-- Recompute and redraw every hunk of `buf` as diff(base, buffer).
function M.render(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local old, now = base[buf], lines(buf)
  if not old then return end
  local list = {}
  local label = require("agent").label()
  for _, d in ipairs(vim.text.diff(text(old), text(now), { result_type = "indices", algorithm = "histogram" })) do
    local a, an, b, bn = unpack(d)
    local h = { old = vim.list_slice(old, a, a + an - 1), base_start = a, base_count = an, new_start = bn == 0 and b + 1 or b, new_count = bn }
    draw(buf, h, label)
    list[#list + 1] = h
  end
  hunks[buf] = #list > 0 and list or nil
  vim.cmd.redrawtabline()
end

local function hunk_at(buf, row)
  for _, h in ipairs(hunks[buf] or {}) do
    local first = h.new_start
    if row >= first - 1 and row <= first + math.max(h.new_count, 1) - 1 then return h end
  end
end

-- noautocmd: a revert must not count as the human accepting the rest (BufWritePost).
local function save(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
end

-- Undo one hunk on disk: restore its removed lines, drop its added ones.
function M.revert(buf, row)
  buf = buf or vim.api.nvim_get_current_buf()
  local h = hunk_at(buf, row or vim.fn.line("."))
  if not h then return vim.notify("○ no agent hunk here") end
  vim.api.nvim_buf_set_lines(buf, h.new_start - 1, h.new_start - 1 + h.new_count, false, h.old)
  save(buf)
  M.render(buf)
end

-- Keep one hunk: fold its current lines into the base.
function M.accept(buf, row)
  buf = buf or vim.api.nvim_get_current_buf()
  local h = hunk_at(buf, row or vim.fn.line("."))
  if not h then return vim.notify("○ no agent hunk here") end
  local now = vim.api.nvim_buf_get_lines(buf, h.new_start - 1, h.new_start - 1 + h.new_count, false)
  local b = base[buf]
  local first = h.base_count == 0 and h.base_start or h.base_start - 1
  for _ = 1, h.base_count do table.remove(b, first + 1) end
  for i, l in ipairs(now) do table.insert(b, first + i, l) end
  M.render(buf)
end

function M.accept_all(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  base[buf] = lines(buf)
  M.render(buf)
end

function M.revert_all(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not base[buf] then return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, base[buf])
  save(buf)
  M.render(buf)
end

function M.jump(dir)
  local buf, row = vim.api.nvim_get_current_buf(), vim.fn.line(".")
  local rows = vim.tbl_map(function(h) return h.new_start end, hunks[buf] or {})
  if dir < 0 then rows = vim.fn.reverse(rows) end
  local target = vim.iter(rows):find(function(r) return dir > 0 and r > row or dir < 0 and r < row end) or rows[1]
  if target then vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(buf)), 0 }) end
end

-- Buffers and rows with pending hunks, for the picker.
function M.items()
  local items = {}
  for buf, list in pairs(hunks) do
    for _, h in ipairs(vim.api.nvim_buf_is_valid(buf) and list or {}) do
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
      items[#items + 1] = {
        glyph = "!", hl = "AosRunning", id = ("%s:%d"):format(name, h.new_start),
        text = ("+%d −%d %s"):format(h.new_count, #h.old, vim.trim(h.old[1] or "")), data = { bufnr = buf, lnum = h.new_start },
      }
    end
  end
  return items
end

-- Seed the base from the git index, so edits made while the file was closed show up too; cb() runs either way.
function M.seed_from_index(buf, cb)
  local path = vim.api.nvim_buf_get_name(buf)
  require("git.repo").run({ "show", ":./" .. vim.fs.basename(path) }, vim.fs.dirname(path), function(ok, out)
    if ok and vim.api.nvim_buf_is_valid(buf) then
      base[buf] = vim.split(out:gsub("\n$", ""), "\n", { plain = true })
      M.render(buf)
    end
    if cb then cb() end
  end, { feature = "agent review" })
end

local function on_read(ev)
  local buf = ev.buf
  if vim.bo[buf].buftype ~= "" or vim.b[buf].bigfile then return end
  if not base[buf] then
    base[buf] = lines(buf)
    return
  end
  M.render(buf)
  if hunks[buf] then require("agent").on_change(buf, #hunks[buf]) end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("AgentReview", {})
  vim.api.nvim_create_autocmd("BufReadPost", { group = group, callback = on_read })
  -- A human save keeps what is on screen: everything pending counts as accepted.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].bigfile then return end
      base[ev.buf] = lines(ev.buf)
      M.render(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev) base[ev.buf], hunks[ev.buf] = nil, nil end,
  })
end

return M
