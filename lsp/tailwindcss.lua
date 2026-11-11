local markers = {
  "tailwind.config.js", "tailwind.config.cjs", "tailwind.config.mjs", "tailwind.config.ts",
  "postcss.config.js", "postcss.config.cjs", "postcss.config.mjs", "postcss.config.ts",
  "theme/static_src/tailwind.config.js", "theme/static_src/tailwind.config.cjs",
  "theme/static_src/tailwind.config.mjs", "theme/static_src/tailwind.config.ts", "theme/static_src/postcss.config.js",
}
-- Manifests that mark a root only when they mention Tailwind (v4 needs no tailwind.config.*).
local manifests = { { { "package.json", "package.json5" }, "tailwindcss" }, { { "mix.lock", "Gemfile.lock" }, "tailwind" } }

local function mentions(file, word)
  local f = io.open(file)
  if not f then return false end
  local text = f:read("*a")
  f:close()
  return text:find(word, 1, true) ~= nil
end

---@type vim.lsp.Config
return {
  cmd = require("core.lsp").node_cmd("tailwindcss-language-server", "--stdio"),
  filetypes = {
    "aspnetcorerazor", "astro", "astro-markdown", "blade", "clojure", "django-html", "htmldjango", "edge", "eelixir",
    "elixir", "ejs", "erb", "eruby", "gohtml", "gohtmltmpl", "haml", "handlebars", "hbs", "html", "htmlangular",
    "html-eex", "heex", "jade", "leaf", "liquid", "markdown", "mdx", "mustache", "njk", "nunjucks", "php", "razor",
    "slim", "twig", "css", "less", "postcss", "sass", "scss", "stylus", "sugarss", "javascript", "javascriptreact",
    "reason", "rescript", "typescript", "typescriptreact", "vue", "svelte", "templ",
  },
  capabilities = { workspace = { didChangeWatchedFiles = { dynamicRegistration = true } } },
  settings = {
    tailwindCSS = {
      validate = true,
      lint = {
        cssConflict = "warning",
        invalidApply = "error",
        invalidScreen = "error",
        invalidVariant = "error",
        invalidConfigPath = "error",
        invalidTailwindDirective = "error",
        recommendedVariantOrder = "warning",
      },
      classAttributes = { "class", "className", "class:list", "classList", "ngClass" },
      includeLanguages = {
        eelixir = "html-eex",
        elixir = "phoenix-heex",
        eruby = "erb",
        heex = "phoenix-heex",
        htmlangular = "html",
        templ = "html",
      },
    },
  },
  before_init = function(_, config)
    config.settings = vim.tbl_deep_extend("keep", config.settings, { editor = { tabSize = vim.lsp.util.get_effective_tabstop() } })
  end,
  workspace_required = true,
  root_dir = function(buf, on_dir)
    local fname = vim.api.nvim_buf_get_name(buf)
    local found = vim.list_extend({}, markers)
    for _, m in ipairs(manifests) do
      local file = vim.fs.find(m[1], { path = vim.fs.dirname(fname), upward = true, type = "file" })[1]
      if file and mentions(file, m[2]) then found[#found + 1] = vim.fs.basename(file) end
    end
    -- No Tailwind marker, no server: a bare git repo no longer counts (it started a Node server for every
    -- markdown, JS or CSS file anywhere).
    local marker = vim.fs.find(found, { path = fname, upward = true })[1]
    if marker then on_dir(vim.fs.dirname(marker)) end
  end,
}
