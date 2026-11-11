-- WAT design tokens (DESIGN.md). Copy as-is; update with that file.
return {
  ground = '#1c1c1f', surface = '#24283b',
  text = '#d4d4d8', muted = '#a9b1d6', dim = '#9aa0ab', faint = '#6f7584',
  border = '#565f89',
  selection = '#292e42', selection_focus = '#262a3a', selection_soft = '#232531',
  range = '#36426e', track = '#2a2d3a',
  green = '#9ece6a', yellow = '#e0af68', muted_yellow = '#a58352',
  blue = '#7aa2f7', magenta = '#bb9af7', cyan = '#7dcfff', red = '#f7768e',
  font = 'SauceCodePro Nerd Font', weight = 500, bold_weight = 700, size = 11,
  wallpaper = { opacity = 0.15, brightness = 0.5 },
  fade = { keep = 0.4, min_contrast = 2.0 },
  glyphs = {
    done = '✓', running = '◆', todo = '○', reply = '●', failed = '✗',
    attention = '!', question = '?', blocked = '⊘', prompt = '❯',
    result = '⎿', sep = '·', remote = '⇄', folded = '▸', unfolded = '▾',
  },
}
