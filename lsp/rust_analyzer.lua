local home = vim.env.HOME
local cargo_home = vim.env.CARGO_HOME or home .. "/.cargo"
local libraries = {
  (vim.env.RUSTUP_HOME or home .. "/.rustup") .. "/toolchains", cargo_home .. "/registry/src", cargo_home .. "/git/checkouts",
}

-- Files inside the toolchain or a dependency join the running workspace instead of starting a new server.
local function library_root(fname)
  if not vim.iter(libraries):any(function(dir) return vim.fs.relpath(dir, fname) ~= nil end) then return end
  local clients = vim.lsp.get_clients({ name = "rust_analyzer" })
  return clients[#clients] and clients[#clients].config.root_dir
end

local function root_dir(buf, on_dir)
  local fname = vim.api.nvim_buf_get_name(buf)
  local reused = library_root(fname)
  if reused then return on_dir(reused) end
  local crate = vim.fs.root(fname, { "Cargo.toml" })
  if not crate then return on_dir(vim.fs.root(fname, { "rust-project.json", ".git" })) end
  if vim.fn.executable("cargo") == 0 then return vim.notify_once("rust_analyzer: cargo not found", vim.log.levels.WARN) end
  local cmd = { "cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path", crate .. "/Cargo.toml" }
  vim.system(cmd, { text = true }, function(out)
    if out.code ~= 0 then
      return vim.schedule_wrap(vim.notify)("rust_analyzer: cargo metadata failed\n" .. out.stderr, vim.log.levels.WARN)
    end
    local ws = vim.json.decode(out.stdout).workspace_root
    on_dir(ws and vim.fs.normalize(ws) or crate)
  end)
end

-- rustup's rust-analyzer matches the active toolchain; Mason's standalone build may not.
local rustup_ra = home .. "/.cargo/bin/rust-analyzer"

---@type vim.lsp.Config
return {
  cmd = { vim.fn.executable(rustup_ra) == 1 and rustup_ra or "rust-analyzer" },
  filetypes = { "rust" },
  root_dir = root_dir,
  capabilities = { experimental = { serverStatusNotification = true } },
  settings = {
    ["rust-analyzer"] = {
      check = { command = "clippy" },
      cargo = { allFeatures = true },
      procMacro = { enable = true },
    },
  },
  -- rust-analyzer reads its settings from initializationOptions at startup.
  before_init = function(params, config) params.initializationOptions = config.settings["rust-analyzer"] end,
  on_attach = function(client, buf)
    vim.api.nvim_buf_create_user_command(buf, "LspCargoReload", function()
      client:request("rust-analyzer/reloadWorkspace", nil, function(err)
        vim.notify(err and err.message or "Cargo workspace reloaded", err and vim.log.levels.ERROR or nil)
      end, 0)
    end, { desc = "Reload current cargo workspace" })
  end,
}
