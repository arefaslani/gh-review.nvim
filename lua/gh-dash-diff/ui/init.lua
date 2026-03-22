local M = {}

--- Open the full PR review UI.
--- Creates the tab layout, opens the Snacks picker sidebar, and loads the first file diff.
--- @param pr GhPR
--- @param files GhFile[]
function M.open(pr, files)
  -- Validate snacks is available
  local ok, _ = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-dash-diff: requires snacks.nvim (https://github.com/folke/snacks.nvim)", vim.log.levels.ERROR)
    return
  end

  local state_mod = require("gh-dash-diff.state")
  local state = state_mod.state
  local config = require("gh-dash-diff").config

  -- Sync PR data into state (may already be set by init.lua, but ensure consistency)
  state.pr.number = pr.number
  state.pr.title = pr.title
  state.pr.files = files
  state.pr.current_idx = #files > 0 and 1 or 0

  -- Create the tab + windows + picker
  require("gh-dash-diff.ui.layout").open(state, config)

  -- Mark layout as ready (enables WinClosed guard)
  state.layout.ready = true

  -- Load the first file immediately if there are any files
  if #files > 0 then
    require("gh-dash-diff.ui.diff").load_file(state, files[1], 1)
  else
    vim.notify("gh-dash-diff: PR #" .. pr.number .. " has no changed files", vim.log.levels.INFO)
  end
end

return M
