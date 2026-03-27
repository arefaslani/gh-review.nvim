--- Shared scrollbind/cursorbind helpers for floating windows.
--- Disabling scrollbind on the diff windows prevents background scroll-sync
--- while a floating window (AI chat, input float, help, etc.) is focused.
local M = {}

--- Disable scrollbind/cursorbind on both diff windows.
--- @param state GhReviewState|nil
function M.disable(state)
  if not state then return end
  for _, wk in ipairs({ "left_win", "right_win" }) do
    local w = state.layout[wk]
    if w and vim.api.nvim_win_is_valid(w) then
      vim.wo[w].scrollbind = false
      vim.wo[w].cursorbind = false
    end
  end
end

--- Re-enable scrollbind/cursorbind on both diff windows and syncbind.
--- @param state GhReviewState|nil
function M.reenable(state)
  if not state then return end
  for _, wk in ipairs({ "left_win", "right_win" }) do
    local w = state.layout[wk]
    if w and vim.api.nvim_win_is_valid(w) then
      vim.wo[w].scrollbind = true
      vim.wo[w].cursorbind = true
    end
  end
  local sw = state.layout.left_win
  if sw and vim.api.nvim_win_is_valid(sw) then
    vim.api.nvim_win_call(sw, function() pcall(vim.cmd, "syncbind") end)
  end
end

return M
