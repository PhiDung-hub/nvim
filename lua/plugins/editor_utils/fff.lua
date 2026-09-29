return {
  "dmtrKovalenko/fff",
  tag = "v0.11.0",
  build = function()
    require("fff.download").download_or_build_binary()
  end,
  cmd = { "FFFFind", "FFFResume", "FFFScan", "FFFRefreshGit", "FFFClearCache", "FFFHealth", "FFFDebug", "FFFOpenLog" },
  keys = {
    { ";f", function() require("fff").find_files() end, desc = "Find files" },
    { ";r", function() require("fff").live_grep() end, desc = "Live grep" },
    { ";;", function() require("fff").resume() end, desc = "Resume file search" },
  },
  opts = {
    preview = { line_numbers = true },
    hl = {
      normal = "Normal",
      border = "FFFBorder",
    },
  },
}
