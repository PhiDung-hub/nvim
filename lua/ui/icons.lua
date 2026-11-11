-- File glyphs by name, extension or filetype in WAT colours (replaces nvim-web-devicons).
-- Glyphs stay as \u{} escapes: literal Nerd Font characters have been lost to empty strings in this repo before.
local M = {}

local code, markup, config, shell, meta, plain =
  "AosIconBlue", "AosIconCyan", "AosIconYellow", "AosIconGreen", "AosIconMagenta", "AosIconDim"

M.file = { "\u{e612}", plain }
M.directory = { "\u{e5ff}", markup }
M.directory_open = { "\u{e5fe}", markup }

local git = { "\u{e702}", meta }
local lock = { "\u{e672}", plain }
local image = { "\u{e60d}", meta }
local sh = { "\u{e795}", shell }
local js = { "\u{e60c}", code }
local react = { "\u{e7ba}", code }
local json = { "\u{e60b}", config }
local yaml = { "\u{e8eb}", config }
local md = { "\u{f48a}", markup }
local generic = { "\u{f121}", code }
local header = { "\u{f0fd}", code }

local by_ext = {
  lua = { "\u{e620}", code }, ts = { "\u{e628}", code }, tsx = react, jsx = react, js = js, mjs = js, cjs = js,
  json = json, jsonc = json, rs = { "\u{e68b}", code }, toml = { "\u{e6b2}", config }, py = { "\u{e606}", code },
  md = md, mdx = md, html = { "\u{e736}", markup }, css = { "\u{e6b8}", markup }, scss = { "\u{e603}", markup },
  svelte = { "\u{e697}", markup }, sol = { "\u{e656}", code }, move = generic, lean = generic,
  sh = sh, zsh = sh, bash = sh, yaml = yaml, yml = yaml,
  c = { "\u{e61e}", code }, h = header, cpp = { "\u{e61d}", code }, hpp = header,
  go = { "\u{e627}", code }, sql = { "\u{e706}", config },
  png = image, jpg = image, jpeg = image, gif = image, webp = image, ico = image, svg = { "\u{f0721}", meta },
  log = { "\u{f0331}", plain }, txt = { "\u{f0219}", plain }, lock = lock,
  vim = { "\u{e62b}", code }, diff = { "\u{e728}", meta },
}

local by_name = {
  dockerfile = { "\u{f0868}", meta }, makefile = { "\u{e779}", meta },
  terminal = { "\u{f489}", shell }, license = { "\u{e60a}", plain }, [".env"] = { "\u{f462}", config },
  [".zshrc"] = sh, [".zshenv"] = sh, [".zprofile"] = sh, [".bashrc"] = sh, [".bash_profile"] = sh, [".profile"] = sh,
  ["package-lock.json"] = lock, ["yarn.lock"] = lock, ["pnpm-lock.yaml"] = lock, ["bun.lockb"] = lock,
  ["cargo.lock"] = lock, ["lazy-lock.json"] = lock, ["flake.lock"] = lock, ["uv.lock"] = lock, ["go.sum"] = lock,
}

local by_ft = {
  typescript = by_ext.ts, typescriptreact = react, javascript = js, javascriptreact = react, rust = by_ext.rs,
  python = by_ext.py, markdown = md, solidity = by_ext.sol, text = by_ext.txt,
  dockerfile = by_name.dockerfile, make = by_name.makefile, gitignore = git, gitcommit = git, gitconfig = git,
}

local function unpack_icon(icon, opts)
  icon = icon or (opts and opts.default and M.file)
  if icon then return icon[1], icon[2] end
end

---@return string?, string? glyph and highlight group; the default file icon only when opts.default is set
function M.get_icon(name, ext, opts)
  name = (name or ""):lower()
  local icon = by_name[name] or (name:match("^%.git") and git) or by_ext[ext and ext:lower() or name:match("%.([^.]+)$")]
  return unpack_icon(icon, opts)
end

function M.get_icon_by_filetype(ft, opts)
  return unpack_icon(by_ft[ft] or by_ext[ft], opts)
end

return M
