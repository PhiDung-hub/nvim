-- Local VS Code-style git: gutter hunks + blame (signs), Source Control panel + diff editor (scm), merge editor
-- and inline conflict actions (merge), graph + branches (graph).
local M = {}

function M.setup()
  for _, name in ipairs({ "signs", "scm", "merge", "graph" }) do
    local ok, mod = pcall(require, "git." .. name)
    if ok then mod.setup() elseif not tostring(mod):find("module 'git." .. name .. "' not found", 1, true) then error(mod) end
  end
end

return M
