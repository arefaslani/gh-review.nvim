if vim.g.gh_dash_diff_loaded then return end
vim.g.gh_dash_diff_loaded = true

vim.api.nvim_create_user_command("GhDashDiff", function(opts)
  local m = require("gh-dash-diff")
  if not m._initialized then m.setup({}) end
  m.open_pr(opts.args ~= "" and tonumber(opts.args) or nil)
end, { nargs = "?", desc = "Open GitHub PR diff viewer" })

vim.api.nvim_create_user_command("GhDashDiffClose", function()
  require("gh-dash-diff").close()
end, { desc = "Close GitHub PR diff viewer" })

vim.api.nvim_create_user_command("GhDash", function()
  require("gh-dash-diff").open_dash()
end, { desc = "Open gh-dash inside Neovim" })
