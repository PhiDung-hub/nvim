return {
  "mfussenegger/nvim-lint",
  event = "VeryLazy",
  config = function()
    local nvim_lint = require("lint")
    nvim_lint.linters_by_ft = {
      solidity = { "solhint" },
    }
    vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "InsertLeave" }, {
      pattern = { "*.sol" },
      callback = function()
        nvim_lint.try_lint()
      end,
    })
  end,
}
