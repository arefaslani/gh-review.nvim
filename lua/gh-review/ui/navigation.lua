local M = {}

--- Push the current file index onto the history stack (for <C-o> navigation).
--- @param state GhReviewState
local function push_history(state)
  if state.pr.current_idx > 0 then
    table.insert(state.pr.file_history, state.pr.current_idx)
    state.pr.file_forward = {}  -- clear forward stack on new navigation
  end
end

--- Navigate to the next changed file (wraps around).
--- In commit mode, navigates within the current commit's files.
--- @param state GhReviewState
function M.next_file(state)
  local files = state.pr.review_mode == "commits"
    and state.pr.commit_files
    or  state.pr.files
  if #files == 0 then return end
  local idx = (state.pr.current_idx % #files) + 1
  if idx == state.pr.current_idx then return end
  push_history(state)
  state.pr.current_idx = idx
  if state.pr.review_mode == "commits" then
    local commit = state.pr.commits[state.pr.current_commit_idx]
    if commit then
      require("gh-review.ui.diff").load_file(
        state, files[idx], idx,
        { base_ref = commit.sha .. "~1", head_ref = commit.sha }
      )
    end
  else
    require("gh-review.ui.picker").select_by_index(state, idx)
    require("gh-review.ui.diff").load_file(state, files[idx], idx)
  end
end

--- Navigate to the previous changed file (wraps around).
--- In commit mode, navigates within the current commit's files.
--- @param state GhReviewState
function M.prev_file(state)
  local files = state.pr.review_mode == "commits"
    and state.pr.commit_files
    or  state.pr.files
  if #files == 0 then return end
  local idx = state.pr.current_idx - 1
  if idx < 1 then idx = #files end
  if idx == state.pr.current_idx then return end
  push_history(state)
  state.pr.current_idx = idx
  if state.pr.review_mode == "commits" then
    local commit = state.pr.commits[state.pr.current_commit_idx]
    if commit then
      require("gh-review.ui.diff").load_file(
        state, files[idx], idx,
        { base_ref = commit.sha .. "~1", head_ref = commit.sha }
      )
    end
  else
    require("gh-review.ui.picker").select_by_index(state, idx)
    require("gh-review.ui.diff").load_file(state, files[idx], idx)
  end
end

--- Go back to the previously viewed file (<C-o>).
--- @param state GhReviewState
function M.file_back(state)
  local history = state.pr.file_history
  if #history == 0 then return end
  local files = state.pr.review_mode == "commits"
    and state.pr.commit_files
    or  state.pr.files
  -- Push current to forward stack
  if state.pr.current_idx > 0 then
    table.insert(state.pr.file_forward, state.pr.current_idx)
  end
  local idx = table.remove(history)
  state.pr.current_idx = idx
  if state.pr.review_mode ~= "commits" then
    require("gh-review.ui.picker").select_by_index(state, idx)
  end
  require("gh-review.ui.diff").load_file(state, files[idx], idx)
end

--- Go forward to the next file in history (<C-i>).
--- @param state GhReviewState
function M.file_forward(state)
  local forward = state.pr.file_forward
  if #forward == 0 then return end
  local files = state.pr.review_mode == "commits"
    and state.pr.commit_files
    or  state.pr.files
  -- Push current to history stack
  if state.pr.current_idx > 0 then
    table.insert(state.pr.file_history, state.pr.current_idx)
  end
  local idx = table.remove(forward)
  state.pr.current_idx = idx
  if state.pr.review_mode ~= "commits" then
    require("gh-review.ui.picker").select_by_index(state, idx)
  end
  require("gh-review.ui.diff").load_file(state, files[idx], idx)
end

--- Toggle focus between the Snacks picker sidebar and the diff area.
--- Mirrors the Snacks explorer `t` toggle behavior.
--- @param state GhReviewState
function M.toggle_picker(state)
  local picker_focused = state.layout.picker
    and pcall(function()
      return state.layout.picker:is_focused()
    end)

  -- More reliable: check if current win belongs to the picker
  local current_win = vim.api.nvim_get_current_win()
  local in_diff = current_win == state.layout.left_win
    or current_win == state.layout.right_win

  if in_diff then
    -- Record current diff window and focus picker input (so user can type to filter)
    state.layout.last_diff_win = current_win
    if state.layout.picker then
      pcall(function() state.layout.picker:focus("input") end)
    end
  else
    -- Return to last diff window (or right diff as fallback)
    local target = state.layout.last_diff_win
    if not target or not vim.api.nvim_win_is_valid(target) then
      target = state.layout.right_win
    end
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
  end
end

--- Toggle between "files" and "commits" review mode.
--- Reopens the picker with the appropriate item list.
--- @param state GhReviewState
function M.toggle_review_mode(state)
  if state.pr.review_mode == "files" then
    if #state.pr.commits == 0 then
      vim.notify("gh-review: Commits not loaded yet, please wait…", vim.log.levels.WARN)
      return
    end
    state.pr.review_mode = "commits"
    state.pr.current_commit_idx = 0
    state.pr.commit_drill_down = false
    vim.notify("gh-review: Commit review mode", vim.log.levels.INFO)
  else
    state.pr.review_mode = "files"
    state.pr.commit_drill_down = false
    vim.notify("gh-review: File review mode", vim.log.levels.INFO)
  end
  require("gh-review.ui.picker").refresh_items(state)
end

--- Internal: load a commit by index — fetch its files and show the first one.
--- @param state GhReviewState
--- @param idx number 1-based index into state.pr.commits
local function load_commit(state, idx)
  state.pr.current_commit_idx = idx
  local commit = state.pr.commits[idx]
  require("gh-review.ui.picker").select_by_index(state, idx)

  local commits_mod = require("gh-review.gh.commits")
  commits_mod.get_files(state.repo.owner, state.repo.name, commit.sha, function(err, files)
    if err then
      vim.notify("gh-review: " .. err, vim.log.levels.ERROR)
      return
    end
    state.pr.commit_files = files or {}
    if #files > 0 then
      state.pr.current_idx = 1
      require("gh-review.ui.diff").load_file(
        state, files[1], 1,
        { base_ref = commit.sha .. "~1", head_ref = commit.sha }
      )
    end
  end)
end

--- Navigate to the next commit (wraps around). Only works in commit mode.
--- @param state GhReviewState
function M.next_commit(state)
  local commits = state.pr.commits
  if #commits == 0 then
    vim.notify("gh-review: No commits loaded yet", vim.log.levels.INFO)
    return
  end
  if state.pr.review_mode ~= "commits" then
    M.toggle_review_mode(state)
    return
  end
  local idx = (state.pr.current_commit_idx % #commits) + 1
  load_commit(state, idx)
end

--- Navigate to the previous commit (wraps around). Only works in commit mode.
--- @param state GhReviewState
function M.prev_commit(state)
  local commits = state.pr.commits
  if #commits == 0 then
    vim.notify("gh-review: No commits loaded yet", vim.log.levels.INFO)
    return
  end
  if state.pr.review_mode ~= "commits" then
    M.toggle_review_mode(state)
    return
  end
  local idx = state.pr.current_commit_idx - 1
  if idx < 1 then idx = #commits end
  load_commit(state, idx)
end

return M
