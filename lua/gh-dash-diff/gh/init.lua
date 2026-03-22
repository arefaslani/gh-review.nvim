--- gh/ data layer — re-exports all sub-modules for convenience.
--- Usage: local gh = require("gh-dash-diff.gh")
---        gh.exec.run(...)  or  gh.repo.detect(...)
---
--- Rule: gh/* modules NEVER require ui/* modules.

local M = {}

M.exec    = require("gh-dash-diff.gh.exec")
M.repo    = require("gh-dash-diff.gh.repo")
M.prs     = require("gh-dash-diff.gh.prs")
M.files   = require("gh-dash-diff.gh.files")
M.reviews = require("gh-dash-diff.gh.reviews")

return M
