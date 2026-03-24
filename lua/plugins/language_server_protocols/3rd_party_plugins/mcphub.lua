return {
  "ravitemer/mcphub.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  build = "npm install -g mcp-hub@latest",
  cmd = "MCPHub",
  opts = {
    config = vim.fn.expand("~/.config/mcphub/servers.json"),
    port = 37373,
    shutdown_delay = 5 * 60 * 1000,
    auto_approve = false,
    auto_toggle_mcp_servers = true,
  },
}
