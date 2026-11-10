-- Diff pane of the git popup: old version (scratch) beside the new one (working file or index scratch) with
-- :diffthis when wide enough, else one float with the old lines as virtual lines. Hunks are staged with
-- 3-line-context patches built from a fresh read of the index, so git refuses one that no longer fits.
local repo = require("git.repo")
local M = {}
local ns = vim.api.nvim_create_namespace("git.diff")
local DIFFOPT = "internal,filler,closeoff,indent-heuristic,inline:char,linematch:60,algorithm:histogram"
local SIDE_BY_SIDE = 120
local CONTEXT = 3
local D = { wins = {}, scratch = {}, mapped = {}, gen = 0 }

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = "git" }) end

-- `git show rev:path` under a feature name; cb(text|nil, timed_out).
local function show(root, rev, path, feature, cb)
  repo.run({ "show", rev .. ":" .. path }, root, function(ok, out, _, slow) cb(ok and out or nil, slow) end, { feature = feature })
end

local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then lines[#lines] = nil end
  return lines, eol
end

local function buf_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n" end
local function new_buf() return D.t and (D.t.real or D.scratch.new) end
local function new_text() return D.t.real and buf_text(D.t.real) or D.t.new or "" end

local function hunks(old, new)
  return vim.text.diff(old, new, { result_type = "indices", algorithm = "histogram", linematch = 60 })
end

-- The hunk whose new side covers `lnum`; a pure deletion matches the lines on either side of it.
local function hunk_at(old, new, lnum)
  for _, h in ipairs(hunks(old, new)) do
    local bs, bc = h[3], h[4]
    if (bc == 0 and (lnum == bs or lnum == bs + 1)) or (lnum >= bs and lnum < bs + bc) then return h end
  end
end

-- `last`: nothing follows these lines in the result, so a missing final newline is real.
local function side(out, sign, lines, eol, from, to, last)
  for i = from, to do
    out[#out + 1] = sign .. lines[i]
    if i == #lines and not eol and last then out[#out + 1] = "\\ No newline at end of file" end
  end
end

-- One hunk with context taken from the text git applies it to (old, or new for `apply -R`).
local function patch(path, old, new, lnum, reverse)
  local h = hunk_at(old, new, lnum)
  if not h then return end
  local as, ac, bs, bc = unpack(h)
  local a, a_eol = split(old)
  local b, b_eol = split(new)
  local base, eol, at, n = a, a_eol, as, ac
  if reverse then base, eol, at, n = b, b_eol, bs, bc end
  -- Appending after a last line without its newline changes that line too.
  if n == 0 and at == #base and at > 0 and not eol then
    if reverse then bs, bc, as, ac = at, 1, as - 1, ac + 1 else as, ac, bs, bc = at, 1, bs - 1, bc + 1 end
    n = 1
  end
  local first = n == 0 and at + 1 or at
  local from, to = math.max(1, first - CONTEXT), math.min(#base, first + n - 1 + CONTEXT)
  local ctx = (first - from) + (to - first - n + 1)
  local function range(count) return (count == 0 and from - 1 or from) .. "," .. count end
  local out = {
    ("diff --git a/%s b/%s"):format(path, path), "--- a/" .. path, "+++ b/" .. path,
    ("@@ -%s +%s @@"):format(range(ctx + ac), range(ctx + bc)),
  }
  local last = first + n - 1 >= #base
  side(out, " ", base, eol, from, first - 1, true)
  side(out, "-", a, a_eol, as, as + ac - 1, last)
  side(out, "+", b, b_eol, bs, bs + bc - 1, last)
  side(out, " ", base, eol, first + n, to, true)
  return table.concat(out, "\n") .. "\n"
end

local function set_text(buf, text)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, (split(text)))
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
end

local function fill(buf, text, path)
  set_text(buf, text)
  local ft = path ~= "" and vim.filetype.match({ filename = path, buf = buf }) or ""
  if vim.bo[buf].filetype ~= ft then vim.bo[buf].filetype = ft end
  return buf
end

-- Inline view: added lines tinted, old lines as virtual lines above them.
local function inline_marks()
  local t, buf = D.t, new_buf()
  if not (t and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if t.plain or not t.inline then return end
  local old, pad, tab = split(t.old), string.rep(" ", vim.o.columns), string.rep(" ", vim.bo[buf].tabstop)
  for _, h in ipairs(hunks(t.old, new_text())) do
    local as, ac, bs, bc = unpack(h)
    for l = bs, bs + bc - 1 do vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = "DiffAdd" }) end
    local virt = {}
    for i = as, as + ac - 1 do virt[#virt + 1] = { { old[i]:gsub("\t", tab) .. pad, "DiffDelete" } } end
    if ac > 0 then vim.api.nvim_buf_set_extmark(buf, ns, math.max(bs - 1, 0), 0, { virt_lines = virt, virt_lines_above = bc > 0 or bs == 0 }) end
  end
end

-- Windows ------------------------------------------------------------------------------------

local function scratch(which)
  if D.scratch[which] and vim.api.nvim_buf_is_valid(D.scratch[which]) then return D.scratch[which] end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].completion = false
  -- Named once: renaming a buffer leaves an unlisted buffer behind under the old name.
  pcall(vim.api.nvim_buf_set_name, buf, "gitdiff://" .. which)
  D.scratch[which] = buf
  return buf
end

local function cfg(row, col, width, height)
  return { relative = "editor", row = row, col = col, width = math.max(width - 2, 1), height = math.max(height - 2, 1), zindex = 40 }
end

local function close_win(which)
  local w = D.wins[which]
  D.wins[which] = nil
  if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
end

local function place_win(which, conf)
  local w = D.wins[which]
  if w and vim.api.nvim_win_is_valid(w) then return vim.api.nvim_win_set_config(w, conf) end
  D.wins[which] = vim.api.nvim_open_win(scratch(which), false, conf)
end

local function place(single)
  local r = D.rect
  if single then
    close_win("old")
    return place_win("new", cfg(r.row, r.col, r.width, r.height))
  end
  local half = math.floor(r.width / 2)
  place_win("old", cfg(r.row, r.col, half, r.height))
  place_win("new", cfg(r.row, r.col + half, r.width - half, r.height))
end

-- Showing a buffer copies its last window's local options; reset the ones the popup must not have.
local function win_opts(w)
  local wo = vim.wo[w]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.foldenable = true, false, "no", "0", false
  wo.wrap, wo.list, wo.spell, wo.winbar, wo.statuscolumn, wo.cursorline = false, false, false, "", "", true
end

-- A buffer swapped out of a diff window stays in the tab's diff until :diffoff, so it goes off first.
local function set_buf(w, buf)
  if vim.api.nvim_win_get_buf(w) == buf then return end
  if vim.wo[w].diff then vim.api.nvim_win_call(w, function() vim.cmd.diffoff() end) end
  vim.api.nvim_win_set_buf(w, buf)
end

-- A rename titles the left (old) side with the old path and the right with the new one.
local function titles(t, single)
  local renamed = not t.message and t.old_path and t.old_path ~= t.path
  local path = t.message and "" or (single and renamed and t.old_path .. " → " or "") .. t.path .. " "
  if renamed and not single then path = t.old_path .. " " end
  local head = { { " ❯ ", "AosPrompt" }, { t.plain and not t.message and "merge " or "diff ", "AosArg" }, { path, "FloatTitle" } }
  local footer = t.staged and " u unstage hunk · ]c [c · ⇥ list · q close " or " s stage hunk · x revert hunk · ]c [c · ⇥ list · q close "
  if t.plain then footer = t.message and " ⇥ list · q close " or " co ct cb accept · ]x [x conflict · ⇥ list · q close " end
  local new = D.wins.new
  if single then
    if not t.plain then vim.list_extend(head, { { t.old_label .. " ", "AosSha" }, { "↔ ", "AosFaint" }, { t.new_label .. " ", "AosDone" } }) end
    return vim.api.nvim_win_set_config(new, { title = head, title_pos = "left", footer = { { footer, "AosFaint" } }, footer_pos = "right" })
  end
  vim.api.nvim_win_set_config(D.wins.old, { title = vim.list_extend(head, { { t.old_label .. " ", "AosSha" } }), title_pos = "left" })
  local right = { { " ↔ ", "AosFaint" }, { renamed and t.path .. " " or "", "FloatTitle" }, { t.new_label .. " ", "AosDone" } }
  vim.api.nvim_win_set_config(new, { title = right, title_pos = "left", footer = { { footer, "AosFaint" } }, footer_pos = "right" })
end

local function diff_mode(single)
  for _, which in ipairs({ "old", "new" }) do
    local w = D.wins[which]
    if w then
      vim.api.nvim_win_call(w, function() vim.cmd(single and "diffoff" or "diffthis") end)
      win_opts(w)
    end
  end
  if not single then vim.cmd.diffupdate() end
  inline_marks()
end

local function first_change(t)
  local h = not t.plain and hunks(t.old, new_text())[1]
  local lnum = h and math.max(h[3], 1) or 1
  local w = D.wins.new
  vim.api.nvim_win_set_cursor(w, { math.min(lnum, vim.api.nvim_buf_line_count(new_buf())), 0 })
  vim.api.nvim_win_call(w, function() vim.cmd("normal! zz") end)
end

-- Keys ---------------------------------------------------------------------------------------

local function after_apply()
  D.applying = false
  M.reload()
  if D.opts then D.opts.refresh() end
end

local function apply_failed(what, err)
  D.applying = false
  if not err then return notify("○ " .. what) end
  notify("✗ " .. what .. " · " .. vim.trim(err):gsub("\n.*", ""), vim.log.levels.ERROR)
end

local function apply(root, p, args)
  if not p then return apply_failed("no change under the cursor") end
  repo.run(vim.list_extend({ "apply", "--cached" }, args), root, function(ok, _, err)
    if not ok then return apply_failed("git apply", err) end
    after_apply()
  end, { stdin = p })
end

local function cursor() return vim.api.nvim_win_get_cursor(D.wins.new)[1] end

local function stage_file(t)
  D.applying = true
  repo.run({ "--literal-pathspecs", "add", "--", t.path }, t.root, function(ok, _, err)
    if not ok then return apply_failed("git add", err) end
    after_apply()
  end)
end

-- VS Code stages from the saved file, so the buffer is written first.
local function stage_hunk()
  local t = D.t
  if D.applying then return end
  if t.staged then return notify("○ staged diff: u unstages a hunk") end
  if t.plain then return notify("○ merge conflict: ⏎ in the list opens the merge editor") end
  if not t.real or t.entry.letter == "U" then return stage_file(t) end
  if vim.bo[t.real].modified then vim.api.nvim_buf_call(t.real, function() vim.cmd("silent write") end) end
  local disk, lnum = table.concat(vim.fn.readfile(vim.api.nvim_buf_get_name(t.real), "b"), "\n"), cursor()
  D.applying = true
  show(t.root, "", t.path, "stage", function(index, slow)
    if slow then return apply_failed("stage paused · slow repo") end
    apply(t.root, patch(t.path, index or "", disk, lnum), { "-" })
  end)
end

local function unstage_hunk()
  local t = D.t
  if D.applying then return end
  if not t.staged then return notify("○ only a staged diff unstages hunks") end
  local lnum = cursor()
  D.applying = true
  show(t.root, "HEAD", t.old_path, "stage", function(head, slow)
    if slow then return apply_failed("unstage paused · slow repo") end
    show(t.root, "", t.path, "stage", function(index, slow2)
      if slow2 then return apply_failed("unstage paused · slow repo") end
      apply(t.root, patch(t.path, head or "", index or "", lnum, true), { "-R", "-" })
    end)
  end)
end

-- The hunk's old side and where it lands, to tell whether a fresh index still yields the same revert.
local function old_side(old, new, lnum)
  local h = hunk_at(old, new, lnum)
  return h and { h[3], h[4], vim.list_slice(split(old), h[1], h[1] + h[2] - 1) }
end

local function write_revert(t, index, lnum)
  local h = hunk_at(index, buf_text(t.real), lnum)
  local as, ac, bs, bc = unpack(h)
  local start = bc == 0 and bs or bs - 1
  vim.api.nvim_buf_set_lines(t.real, start, start + bc, false, vim.list_slice(split(index), as, as + ac - 1))
  vim.api.nvim_buf_call(t.real, function() vim.cmd("silent write") end)
  after_apply()
end

-- The index is read again first: a hunk that changed since the diff was drawn is refused, not reverted stale.
local function revert_hunk()
  local t = D.t
  if D.applying then return end
  if t.plain or t.staged or not t.real or t.entry.letter == "U" then return notify("○ nothing to revert here: x in the list discards the file") end
  local lnum, tick = cursor(), vim.b[t.real].changedtick
  local want = old_side(t.old, buf_text(t.real), lnum)
  if not want then return notify("○ no change under the cursor") end
  D.applying = true
  show(t.root, "", t.path, "stage", function(index, slow)
    if slow then return apply_failed("revert paused · slow repo") end
    if D.t ~= t or vim.b[t.real].changedtick ~= tick then return apply_failed("buffer changed · revert again") end
    if not vim.deep_equal(old_side(index or "", buf_text(t.real), lnum), want) then
      apply_failed("hunk changed in the index · reloaded, nothing reverted")
      return M.reload()
    end
    D.applying = false
    write_revert(t, index or "", lnum)
  end)
end

local function jump(dir)
  if vim.wo.diff then return pcall(vim.cmd, "normal! " .. (dir > 0 and "]c" or "[c")) end
  local lnum, starts = vim.api.nvim_win_get_cursor(0)[1], {}
  for _, h in ipairs(hunks(D.t.old or "", new_text())) do starts[#starts + 1] = math.max(h[3], 1) end
  if dir < 0 then starts = vim.fn.reverse(starts) end
  for _, s in ipairs(starts) do
    if (dir > 0 and s > lnum) or (dir < 0 and s < lnum) then return vim.api.nvim_win_set_cursor(0, { s, 0 }) end
  end
end

local function toggle()
  D.force = not (D.t and D.t.inline)
  M.resize(D.rect)
end

local KEYS = {
  { "q", function() D.opts.close() end, "close" },
  { "<Esc>", function() D.opts.close() end, "close" },
  { "<Tab>", function() D.opts.focus(0) end, "focus the file list" },
  { "<C-h>", function() D.opts.focus(-1) end, "focus left" },
  { "<C-l>", function() D.opts.focus(1) end, "focus right" },
  { "s", stage_hunk, "stage hunk" },
  { "u", unstage_hunk, "unstage hunk (staged diff; undo in the working file)" },
  { "x", revert_hunk, "revert hunk" },
  { "]c", function() jump(1) end, "next hunk" },
  { "[c", function() jump(-1) end, "previous hunk" },
  { "<leader>gd", toggle, "toggle inline / side by side" },
}
M.keys = { { section = "Diff pane", keys = vim.tbl_map(function(k) return { k[1], k[3] } end, KEYS) } }

-- The working file keeps its own buffer-local mappings outside the popup: they are saved and restored.
-- It also keeps native `u` (undo): only the index scratch buffers unstage hunks.
local function map(buf, real)
  if D.mapped[buf] then return end
  local saved, keys = {}, vim.tbl_filter(function(k) return not (real and k[1] == "u") end, KEYS)
  vim.api.nvim_buf_call(buf, function()
    for _, k in ipairs(keys) do
      local old = vim.fn.maparg(k[1], "n", false, true)
      if old.buffer == 1 then saved[#saved + 1] = old end
      vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, desc = k[3] })
    end
  end)
  D.mapped[buf] = { saved = saved, keys = keys }
end

local function unmap(buf)
  local m = D.mapped[buf]
  D.mapped[buf] = nil
  if not m or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_call(buf, function()
    for _, k in ipairs(m.keys) do pcall(vim.keymap.del, "n", k[1], { buffer = buf }) end
    for _, old in ipairs(m.saved) do vim.fn.mapset(old) end
  end)
end

-- A file opened only for the diff does not stay open after it, like VS Code; an edited one joins the buffer list.
local function release(t)
  local buf = t.real
  unmap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if vim.bo[buf].modified then vim.bo[buf].buflisted = true return end
  if t.borrowed and #vim.fn.win_findbuf(buf) == 0 then pcall(vim.api.nvim_buf_delete, buf, {}) end
end

local function real_buf(t)
  local buf = vim.fn.bufadd(t.root .. "/" .. t.path)
  t.borrowed = not vim.api.nvim_buf_is_loaded(buf)
  if t.borrowed then
    local shm = vim.o.shortmess
    vim.opt.shortmess:append("A")
    pcall(vim.fn.bufload, buf)
    vim.o.shortmess = shm
  end
  return buf
end

-- Render -------------------------------------------------------------------------------------

local function render(t, focus, keep)
  local prev = D.t
  D.t = t
  if t.entry and t.new == nil then t.real = real_buf(t) end
  t.inline = t.plain or (D.force == nil and D.rect.width < SIDE_BY_SIDE) or D.force == true
  place(t.inline)
  if not t.inline then set_buf(D.wins.old, fill(scratch("old"), t.old, t.path)) end
  set_buf(D.wins.new, t.real or fill(scratch("new"), t.new, t.path))
  if prev and prev.real and prev.real ~= t.real then release(prev) end
  for _, b in pairs({ D.scratch.old, D.scratch.new, t.real }) do map(b, b == t.real) end
  diff_mode(t.inline)
  -- An empty side (added or deleted file) is all filler in diff mode; its lone empty line gets no number or cursorline.
  local old_shown = not t.inline and t.old ~= ""
  if not t.inline then vim.wo[D.wins.old].number, vim.wo[D.wins.old].cursorline = old_shown, old_shown end
  local new_shown = not t.message and (t.real ~= nil or t.new ~= "")
  vim.wo[D.wins.new].number, vim.wo[D.wins.new].cursorline = new_shown, new_shown
  titles(t, t.inline)
  if not keep then first_change(t) end
  if focus then vim.api.nvim_set_current_win(D.wins.new) end
end

local function content(root, e, section)
  local staged = section == "staged"
  local t = {
    root = root, path = e.path, entry = e, section = section, staged = staged, plain = section == "conflicts",
    key = root .. ":" .. section .. ":" .. e.path, old_path = staged and e.orig or e.path,
    old_label = staged and "HEAD" or "Index",
    new_label = staged and "Index" or e.letter == "D" and "Deleted" or e.letter == "U" and "Untracked" or "Working Tree",
  }
  if e.letter == "D" and not staged then t.new = "" end
  return t
end

local function load(t, done)
  D.gen = D.gen + 1
  local gen = D.gen
  local function finish()
    if gen == D.gen and D.rect then done() end
  end
  if t.plain then return finish() end
  local function slow() return gen == D.gen and D.rect and M.message("○ diff paused · slow repo") end
  show(t.root, t.staged and "HEAD" or "", t.old_path, "diff", function(old, cut)
    if cut then return slow() end
    t.old = old or ""
    if not t.staged then return finish() end
    show(t.root, "", t.path, "diff", function(new, cut2)
      if cut2 then return slow() end
      t.new = new or ""
      finish()
    end)
  end)
end

-- Public -------------------------------------------------------------------------------------

-- rect: the outer rectangle (borders included) the diff pane fills. opts: { close(), focus(dir), refresh() }.
function M.attach(rect, opts)
  D.rect, D.opts, D.force = rect, opts, nil
  D.diffopt = D.diffopt or vim.o.diffopt
  vim.o.diffopt = DIFFOPT
end

-- section "staged": HEAD ↔ Index; "changes": Index ↔ Working Tree (deleted: empty right side, untracked: empty left);
-- "conflicts": the working file with its markers.
function M.show(root, e, section, opts)
  if not D.rect then return end
  local t = content(root, e, section)
  local keep = D.t and D.t.key == t.key
  -- A reload before this one lands must load it, not the file still on screen.
  D.want = { root = root, entry = e, section = section, opts = opts, key = t.key }
  load(t, function()
    D.want = nil
    local w = D.wins.new and vim.api.nvim_win_is_valid(D.wins.new) and D.wins.new
    if keep and w and vim.api.nvim_get_current_win() == w then keep = vim.api.nvim_win_get_cursor(w) end
    render(t, opts and opts.focus, keep)
    if type(keep) == "table" then pcall(vim.api.nvim_win_set_cursor, w, keep) end
  end)
end

function M.message(text)
  if not D.rect then return end
  D.gen, D.want = D.gen + 1, nil
  render({ plain = true, message = true, new = text, path = "", key = "message:" .. text }, false, false)
end

function M.reload()
  local t = D.want or D.t
  if t and t.entry then M.show(t.root, t.entry, t.section, D.want and D.want.opts) end
end

function M.key() return (D.want or D.t or {}).key end

function M.path() return (D.want or D.t or {}).entry and (D.want or D.t).entry.path end

function M.wins()
  local out = {}
  for _, which in ipairs({ "old", "new" }) do
    if D.wins[which] and vim.api.nvim_win_is_valid(D.wins[which]) then out[#out + 1] = D.wins[which] end
  end
  return out
end

function M.resize(rect)
  D.rect = rect
  if D.t then render(D.t, false, true) end
end

function M.close()
  close_win("old")
  close_win("new")
  if D.t and D.t.real then release(D.t) end
  for _, b in pairs(D.scratch) do
    unmap(b)
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  if D.diffopt then vim.o.diffopt = D.diffopt end
  D.t, D.want, D.rect, D.opts, D.scratch, D.diffopt, D.applying = nil, nil, nil, nil, {}, nil, false
  D.gen = D.gen + 1
end

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = vim.api.nvim_create_augroup("GitDiff", {}),
  callback = function(a)
    if D.t and D.t.inline and a.buf == D.t.real then inline_marks() end
  end,
})

return M
