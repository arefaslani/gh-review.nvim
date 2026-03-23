if vim.g.gh_review_loaded then return end
vim.g.gh_review_loaded = true

vim.api.nvim_create_user_command("GhReview", function(opts)
  local m = require("gh-review")
  if not m._initialized then m.setup({}) end
  m.open_pr(opts.args ~= "" and tonumber(opts.args) or nil)
end, { nargs = "?", desc = "Open GitHub PR diff viewer" })

vim.api.nvim_create_user_command("GhReviewClose", function()
  require("gh-review").close()
end, { desc = "Close GitHub PR diff viewer" })

vim.api.nvim_create_user_command("GhReviewResume", function()
  require("gh-review").resume_pr()
end, { desc = "Resume last PR review" })

vim.api.nvim_create_user_command("GhPrs", function()
  require("gh-review").open_dash()
end, { desc = "Browse GitHub PRs" })
