local M = {}

--- Create the PR review tab with side-by-side diff windows.
--- Opens a dedicated tabpage, creates left+right windows via vsplit,
--- then opens the Snacks picker sidebar.
--- @param state GhReviewState
--- @param config GhReviewConfig
function M.open(state, config)
  -- 1. Open dedicated tab
  vim.cmd("tabnew")
  state.layout.tab = vim.api.nvim_get_current_tabpage()

  -- 2. The new tab has one window — use it as the left diff window
  state.layout.left_win = vim.api.nvim_get_current_win()

  -- 3. Create right diff window via vsplit (rightbelow so it opens to the right)
  vim.cmd("rightbelow vsplit")
  state.layout.right_win = vim.api.nvim_get_current_win()

  -- 4. Open the Snacks picker sidebar (creates its own split on the left)
  require("gh-review.ui.picker").open(state, config)

  -- 5. Equalize the two diff windows
  if vim.api.nvim_win_is_valid(state.layout.left_win)
    and vim.api.nvim_win_is_valid(state.layout.right_win) then
    local total = vim.api.nvim_win_get_width(state.layout.left_win)
      + vim.api.nvim_win_get_width(state.layout.right_win)
    local half = math.floor(total / 2)
    vim.api.nvim_win_set_width(state.layout.left_win, half)
  end

  -- 6. Focus the left diff window initially
  if vim.api.nvim_win_is_valid(state.layout.left_win) then
    vim.api.nvim_set_current_win(state.layout.left_win)
  end
end

--- Tear down the entire PR review session.
--- @param state GhReviewState
function M.close(state)
  -- Disable WinClosed guard immediately so closing windows doesn't schedule
  -- a redundant M.close() (which would race with a subsequent open_pr).
  state.layout.ready = false

  -- 1. Close the Snacks picker if open
  if state.layout.picker then
    pcall(function() state.layout.picker:close() end)
    state.layout.picker = nil
  end

  -- 2. Turn off diff mode in all windows
  pcall(vim.cmd, "diffoff!")

  -- 3. Delete all tracked buffers
  for _, buf in ipairs(state.layout.all_bufs or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  -- 4. Close the tab (if it still exists)
  if state.layout.tab and vim.api.nvim_tabpage_is_valid(state.layout.tab) then
    local tabnr = vim.api.nvim_tabpage_get_number(state.layout.tab)
    pcall(vim.cmd, "tabclose " .. tabnr)
  end
end

return M
