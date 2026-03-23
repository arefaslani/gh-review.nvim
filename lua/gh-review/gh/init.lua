--- gh/ data layer — re-exports all sub-modules for convenience.
--- Usage: local gh = require("gh-review.gh")
---        gh.exec.run(...)  or  gh.repo.detect(...)
---
--- Rule: gh/* modules NEVER require ui/* modules.

local M = {}

M.exec    = require("gh-review.gh.exec")
M.repo    = require("gh-review.gh.repo")
M.prs     = require("gh-review.gh.prs")
M.files   = require("gh-review.gh.files")
M.reviews = require("gh-review.gh.reviews")

return M
