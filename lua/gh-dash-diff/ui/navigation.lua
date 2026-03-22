local M = {}

--- Navigate to the next changed file (wraps around).
--- @param state GhDashDiffState
function M.next_file(state)
  local files = state.pr.files
  if #files == 0 then return end
  local idx = (state.pr.current_idx % #files) + 1
  state.pr.current_idx = idx
  require("gh-dash-diff.ui.picker").select_by_index(state, idx)
  require("gh-dash-diff.ui.diff").load_file(state, files[idx], idx)
end

--- Navigate to the previous changed file (wraps around).
--- @param state GhDashDiffState
function M.prev_file(state)
  local files = state.pr.files
  if #files == 0 then return end
  local idx = state.pr.current_idx - 1
  if idx < 1 then idx = #files end
  state.pr.current_idx = idx
  require("gh-dash-diff.ui.picker").select_by_index(state, idx)
  require("gh-dash-diff.ui.diff").load_file(state, files[idx], idx)
end

--- Toggle focus between the Snacks picker sidebar and the diff area.
--- Mirrors the Snacks explorer `t` toggle behavior.
--- @param state GhDashDiffState
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

return M
