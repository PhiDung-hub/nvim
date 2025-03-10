return {
  "nvimtools/none-ls.nvim",  -- Use Neovim as a language server to inject LSP diagnostics, code actions, and more via Lua.
  dependencies = {
    "nvim-lua/plenary.nvim", -- premade lua functions
  },
  config = function()
    local status, null_ls = pcall(require, "null-ls")
    if not status then
      print("WARNING: null-ls is unavailable")
      return
    end

    -- https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/formatting
    local formatting = null_ls.builtins.formatting
    -- https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/diagnostics
    local diagnostics = null_ls.builtins.diagnostics
    -- https://github.com/nvimtools/none-ls.nvim/tree/main/lua/null-ls/builtins/completion
    local completion = null_ls.builtins.completion

    local augroup = vim.api.nvim_create_augroup("LspFormatting", {})

    -- WARNING: Make sure to install these tools using Mason.
    null_ls.setup({
      debug = false,
      autostart = true,
      sources = {
        -- lua
        formatting.stylua,

        -- python
        -- diagnostics.pylint,
        formatting.black,

        -- go
        formatting.gofumpt.with({
          extra_args = { "-l", "140" }, -- Set the line length limit to 140 characters
        }),

        -- JS, JSX, TSX
        -- diagnostics.eslint.with({
        --   diagnostics_format = "[eslint] #{m}\n(#{c})",
        -- }),
        formatting.prettierd,
      },
    })

    vim.api.nvim_create_user_command("DisableLspFormatting", function()
      vim.api.nvim_clear_autocmds({ group = augroup, buffer = 0 })
    end, { nargs = 0 })
  end,
}

-- ** EXAMPLE CUSTOM DIAGNOSTIC MESSAGE **
--[[ local unwrap = { ]]
--[[   method = null_ls.methods.DIAGNOSTICS, ]]
--[[   filetypes = { "rust" }, ]]
--[[   generator = { ]]
--[[     fn = function(params) ]]
--[[       local diag = {} ]]
--[[       -- sources have access to a params object ]]
--[[       -- containing zhinfo about the current file and editor state ]]
--[[       for i, line in ipairs(params.content) do ]]
--[[         local col, end_col = line:find("unwrap()") ]]
--[[         if col and end_col then ]]
--[[           -- null-ls fills in undefined positions ]]
--[[           -- and converts source diagnostics into the required format ]]
--[[           table.insert(diag, { ]]
--[[             row = i, ]]
--[[             col = col, ]]
--[[             end_col = end_col, ]]
--[[             source = "unwrap", ]]
--[[             message = "hey " .. os.getenv("USER") .. ", don't forget to handle this", ]]
--[[             severity = 2, ]]
--[[           }) ]]
--[[         end ]]
--[[       end ]]
--[[       return diag ]]
--[[     end, ]]
--[[   }, ]]
--[[ } ]]
--[[]]
--[[ null_ls.register(unwrap) ]]
