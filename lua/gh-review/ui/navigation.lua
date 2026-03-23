local M = {}

-- ---------------------------------------------------------------------------
-- Custom jumplist: tracks {file_idx, line, col} across files and cursor moves
-- ---------------------------------------------------------------------------

--- Get the current cursor position as a jumplist entry.
--- @param state GhReviewState
--- @return {file_idx: integer, line: integer, col: integer}|nil
local function current_entry(state)
  if state.pr.current_idx <= 0 then return nil end
  local win = state.layout.right_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = state.layout.left_win
  end
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local pos = vim.api.nvim_win_get_cursor(win)
  return { file_idx = state.pr.current_idx, line = pos[1], col = pos[2] }
end

--- Push the current position onto the jumplist.
--- Truncates any forward entries (like native jumplist behavior).
--- @param state GhReviewState
function M.push_jump(state)
  local entry = current_entry(state)
  if not entry then return end
  local jl = state.pr.jumplist
  local pos = state.pr.jumplist_pos
  -- Truncate forward entries
  if pos > 0 then
    for _ = 1, pos do
      table.remove(jl)
    end
    state.pr.jumplist_pos = 0
  end
  -- Deduplicate: don't push if identical to head
  local head = jl[#jl]
  if head and head.file_idx == entry.file_idx
    and head.line == entry.line then
    return
  end
  table.insert(jl, entry)
  -- Cap at 100 entries
  if #jl > 100 then table.remove(jl, 1) end
end

--- Navigate backward in the jumplist (<C-o>).
--- @param state GhReviewState
function M.jump_back(state)
  local jl = state.pr.jumplist
  local pos = state.pr.jumplist_pos
  local target_idx = #jl - pos
  if target_idx < 1 then return end

  -- Save current position if we're at the head (first <C-o>)
  if pos == 0 then
    M.push_jump(state)
    -- push_jump may have added an entry, recalculate
    target_idx = #jl
  end

  local entry = jl[target_idx]
  if not entry then return end
  state.pr.jumplist_pos = pos + 1

  M._goto_entry(state, entry)
end

--- Navigate forward in the jumplist (<C-i>).
--- @param state GhReviewState
function M.jump_forward(state)
  local jl = state.pr.jumplist
  local pos = state.pr.jumplist_pos
  if pos <= 0 then return end

  state.pr.jumplist_pos = pos - 1
  local target_idx = #jl - (pos - 1)
  local entry = jl[target_idx]
  if not entry then return end

  M._goto_entry(state, entry)
end

--- Go to a jumplist entry: load file if needed, set cursor.
--- @param state GhReviewState
--- @param entry {file_idx: integer, line: integer, col: integer}
function M._goto_entry(state, entry)
  local files = state.pr.review_mode == "commits"
    and state.pr.commit_files
    or  state.pr.files

  if entry.file_idx ~= state.pr.current_idx then
    -- Different file: load it
    local file = files[entry.file_idx]
    if not file then return end
    state.pr.current_idx = entry.file_idx
    if state.pr.review_mode ~= "commits" then
      require("gh-review.ui.picker").select_by_index(state, entry.file_idx)
    end
    require("gh-review.ui.diff").load_file(state, file, entry.file_idx,
      { restore_line = entry.line })
  else
    -- Same file: just move cursor
    local win = vim.api.nvim_get_current_win()
    if win == state.layout.left_win or win == state.layout.right_win then
      pcall(vim.api.nvim_win_set_cursor, win, { entry.line, entry.col })
    elseif state.layout.right_win and vim.api.nvim_win_is_valid(state.layout.right_win) then
      pcall(vim.api.nvim_win_set_cursor, state.layout.right_win,
        { entry.line, entry.col })
    end
  end
end

-- ---------------------------------------------------------------------------
-- File navigation
-- ---------------------------------------------------------------------------

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
  M.push_jump(state)
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
  M.push_jump(state)
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

-- ---------------------------------------------------------------------------
-- Picker / mode toggles
-- ---------------------------------------------------------------------------

--- Toggle focus between the Snacks picker sidebar and the diff area.
--- @param state GhReviewState
function M.toggle_picker(state)
  local current_win = vim.api.nvim_get_current_win()
  local in_diff = current_win == state.layout.left_win
    or current_win == state.layout.right_win

  if in_diff then
    state.layout.last_diff_win = current_win
    if state.layout.picker then
      pcall(function() state.layout.picker:focus("input") end)
    end
  else
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

-- ---------------------------------------------------------------------------
-- Commit navigation
-- ---------------------------------------------------------------------------

--- Internal: load a commit by index.
--- @param state GhReviewState
--- @param idx number
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

--- Navigate to the next commit (wraps around).
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

--- Navigate to the previous commit (wraps around).
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
