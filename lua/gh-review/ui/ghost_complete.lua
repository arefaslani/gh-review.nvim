local M = {}

local _ns = vim.api.nvim_create_namespace("gh-ghost-complete")

--- Filter candidates by case-insensitive prefix match.
local function filter_matches(typed, candidates)
  if typed == "" then return vim.deepcopy(candidates) end
  local lower = typed:lower()
  local matches = {}
  for _, c in ipairs(candidates) do
    if c:lower():sub(1, #lower) == lower then
      table.insert(matches, c)
    end
  end
  return matches
end

--- Set (or clear) inline ghost text showing the completion suffix.
local function set_ghost_text(buf, typed, match)
  vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
  if not match or #match <= #typed then return end
  local suffix = match:sub(#typed + 1)
  local line_text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  vim.api.nvim_buf_set_extmark(buf, _ns, 0, #line_text, {
    virt_text     = { { suffix, "GhGhostText" } },
    virt_text_pos = "inline",
  })
end

--- Attach inline ghost-text completion to an existing buffer.
--- Completes the value portion of `author:<prefix>` as the user types.
--- Tab accepts the suggestion; C-n/C-p cycle matches.
--- @param buf number  Buffer handle to attach to
--- @param win number  Window handle (for cursor positioning on accept)
--- @param candidates string[]  List of usernames
--- @return fun()  Detach function to remove the autocompletion
function M.attach(buf, win, candidates)
  if #candidates == 0 then return function() end end

  local matches   = {}
  local match_idx = 0
  local _accepting = false

  --- Extract the author prefix being typed, if any.
  --- Returns (before, prefix) where `before` is everything up to and including "author:"
  --- and `prefix` is the text after it.  Returns nil when the cursor is not inside an author: token.
  local function get_author_context()
    if not vim.api.nvim_buf_is_valid(buf) then return nil end
    local line = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
    -- Match when the line ends with author:<prefix> (user is actively typing it)
    local before, prefix = line:match("^(.*author:)([^%s]*)$")
    if before then return before, prefix end
    return nil
  end

  local function refresh()
    if _accepting then return end
    local base, prefix = get_author_context()
    if not base then
      vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
      matches = {}
      match_idx = 0
      return
    end
    matches = filter_matches(prefix, candidates)
    match_idx = #matches > 0 and 1 or 0
    set_ghost_text(buf, prefix, matches[match_idx])
  end

  local function cycle(delta)
    if #matches < 2 then return end
    match_idx = ((match_idx - 1 + delta) % #matches) + 1
    local _, prefix = get_author_context()
    if prefix then
      set_ghost_text(buf, prefix, matches[match_idx])
    end
  end

  local function accept()
    local current = matches[match_idx]
    if not current then return end
    local base, _ = get_author_context()
    if not base then return end
    _accepting = true
    local new_line = base .. current
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { new_line })
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { 1, #new_line })
    end
    vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
    matches = filter_matches(current, candidates)
    match_idx = #matches > 0 and 1 or 0
    vim.schedule(function() _accepting = false end)
  end

  -- Listen for text changes
  local detached = false
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if detached then return true end  -- returning true detaches
      vim.schedule(function()
        if detached or not vim.api.nvim_buf_is_valid(buf) then return end
        refresh()
      end)
      return false
    end,
  })

  -- Set keymaps (only active while attached)
  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("i", "<Tab>",   accept, o)
  vim.keymap.set("i", "<S-Tab>", function() cycle(-1) end, o)

  -- Return detach function
  return function()
    detached = true
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
      pcall(vim.keymap.del, "i", "<Tab>",   { buffer = buf })
      pcall(vim.keymap.del, "i", "<S-Tab>", { buffer = buf })
    end
  end
end

return M
