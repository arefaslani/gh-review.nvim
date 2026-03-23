local M = {}

local STATUS_ICONS = {
  added    = "+",
  modified = "~",
  removed  = "-",
  renamed  = "R",
  copied   = "C",
  changed  = "~",
}

local STATUS_HL = {
  added    = "GhFileAdded",
  modified = "GhFileModified",
  removed  = "GhFileDeleted",
  renamed  = "GhFileRenamed",
  copied   = "GhFileAdded",
  changed  = "GhFileModified",
}

--- Shorten a file path for display: show parent dir + filename.
--- e.g. "lib/uss/services/entitlements_service.rb" -> "services/entitlements_service.rb"
--- @param filepath string
--- @return string
local function short_path(filepath)
  local parts = vim.split(filepath, "/")
  if #parts <= 2 then return filepath end
  return parts[#parts - 1] .. "/" .. parts[#parts]
end

--- Build picker items from a PR file list with directory grouping.
--- Returns items (with dir_header entries interspersed) and a file-idx→picker-row map.
--- @param files GhFile[]
--- @return table[] items, table file_idx_to_picker_idx
local function build_file_items(files)
  -- Sort a copy by filename so directories are naturally grouped
  local sorted = {}
  for _, f in ipairs(files) do
    table.insert(sorted, f)
  end
  table.sort(sorted, function(a, b) return a.filename < b.filename end)

  local items = {}
  local file_idx_to_picker_idx = {}
  local current_dir = nil

  for i, f in ipairs(sorted) do
    local dir = f.filename:match("^(.*)/[^/]+$")  -- nil for root-level files

    if dir ~= current_dir then
      current_dir = dir
      if dir then
        table.insert(items, { type = "dir_header", text = dir, display = dir, idx = 0 })
      end
    end

    file_idx_to_picker_idx[i] = #items + 1

    local icon  = STATUS_ICONS[f.status] or "?"
    local stats = string.format("+%d -%d", f.additions or 0, f.deletions or 0)
    table.insert(items, {
      idx         = i,
      type        = "file",
      text        = f.filename,      -- used for fuzzy filtering
      file        = f.filename,
      filename    = f.filename,
      display     = f.filename:match("[^/]+$") or f.filename,
      status      = f.status or "modified",
      icon        = icon,
      stats       = stats,
      additions   = f.additions or 0,
      deletions   = f.deletions or 0,
      indent      = dir ~= nil,      -- true when nested under a directory header
      _file_entry = f,               -- raw GhFile for downstream use
    })
  end
  return items, file_idx_to_picker_idx
end

--- Build picker items from a commit list.
--- @param commits GhCommit[]
--- @return table[] items Snacks picker items
local function build_commit_items(commits)
  local items = {}
  for i, c in ipairs(commits) do
    local short_sha = c.sha:sub(1, 7)
    local first_line = c.message:match("^[^\n]*") or c.message
    table.insert(items, {
      idx           = i,
      type          = "commit",
      text          = short_sha .. " " .. first_line,  -- fuzzy filter text
      sha           = c.sha,
      short_sha     = short_sha,
      display       = first_line,
      _commit_entry = c,
    })
  end
  return items
end

--- Refresh the picker display so the active-file indicator re-renders.
--- Safe to call even if the picker is closed or doesn't support refresh.
--- @param state GhDashDiffState
function M.refresh(state)
  if state.layout.picker then
    pcall(function() state.layout.picker:refresh() end)
  end
end

--- Load the diff for a picker item. Used by confirm, on_change, and <CR>/<l>.
--- @param state GhDashDiffState
--- @param item table Snacks picker item
local function load_item_diff(state, item)
  if not item then return end
  if item.type == "dir_header" then return end  -- headers are not selectable

  if item.type == "commit" then
    -- Commit mode: fetch files for this commit then show first file
    state.pr.current_commit_idx = item.idx
    M.refresh(state)
    local commits_mod = require("gh-dash-diff.gh.commits")
    commits_mod.get_files(state.repo.owner, state.repo.name, item.sha, function(err, files)
      if err then
        vim.notify("gh-dash-diff: " .. err, vim.log.levels.ERROR)
        return
      end
      state.pr.commit_files = files or {}
      if #files > 0 then
        state.pr.current_idx = 1
        require("gh-dash-diff.ui.diff").load_file(
          state, files[1], 1,
          { base_ref = item.sha .. "~1", head_ref = item.sha }
        )
      end
    end)
  else
    -- Files mode: existing behavior
    state.pr.current_idx = item.idx
    M.refresh(state)
    require("gh-dash-diff.ui.diff").load_file(state, item._file_entry, item.idx)
  end
end

--- Open the Snacks picker sidebar showing PR changed files or commits.
--- Keeps itself open after selection (acts as a persistent sidebar).
--- @param state GhDashDiffState
--- @param config GhDashDiffConfig
function M.open(state, config)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-dash-diff requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local is_commit_mode = state.pr.review_mode == "commits"
  local items
  if is_commit_mode then
    items = build_commit_items(state.pr.commits)
  else
    local file_map
    items, file_map = build_file_items(state.pr.files)
    state.layout.picker_file_map = file_map
  end

  local title = is_commit_mode
    and string.format("PR #%d — Commits", state.pr.number)
    or  string.format("PR #%d", state.pr.number)

  -- Direct function confirm: avoids the confirm→string→action resolution chain
  -- which can fall through to "jump" via the circular-reference guard in
  -- picker/core/actions.lua (action == "confirm" || name == "confirm" → "jump").
  local function confirm_fn(picker, item)
    load_item_diff(state, item or picker:current())
    -- Return nothing (nil) — picker stays open because jump.close = false
    -- and we never called picker:close().
  end

  local function close_fn(_picker)
    require("gh-dash-diff").close()
  end

  state.layout.picker = Snacks.picker.pick({
    source     = "gh_pr_files",
    title      = title,
    items      = items,
    auto_close = false,

    -- confirm is a direct function — never goes through the string→action
    -- resolution chain that falls through to "jump".
    confirm = confirm_fn,

    -- Safety net: even if jump runs somehow, don't close the picker.
    jump = { close = false },

    -- Sidebar layout (mirrors Snacks explorer)
    layout = {
      preset  = "sidebar",
      preview = false,
      width   = config.picker.width or 35,
    },

    -- Custom line format: handles dir_header, file, and commit items
    format = function(item, _picker)
      if item.type == "dir_header" then
        return {
          { item.display .. "/", "Comment" },
        }
      elseif item.type == "commit" then
        local is_active = item.idx == state.pr.current_commit_idx
        local prefix    = is_active and "▶ " or "  "
        local name_hl   = is_active and "Special" or "Normal"
        return {
          { prefix,             is_active and "Special" or "Normal" },
          { item.short_sha .. " ", "Comment" },
          { item.display,       name_hl },
        }
      else
        local is_active = item.idx == state.pr.current_idx
        local is_viewed = state.review.viewed_files[item.filename]
        local hl        = STATUS_HL[item.status] or "Normal"
        local stat_hl   = item.additions > 0 and "GhStatAdd" or "GhStatDel"
        local indent    = item.indent and "  " or ""
        local prefix    = is_active and "▶ " or "  "
        local name_hl   = is_active and "Special" or "Normal"
        local viewed_chunk = is_viewed
          and { "✔ ", "DiagnosticOk" }
          or  { "  ", "Normal" }
        return {
          { indent .. prefix .. item.icon .. " ", is_active and "Special" or hl },
          viewed_chunk,
          { item.display .. " ",                  name_hl },
          { item.stats,                           stat_hl },
        }
      end
    end,

    actions = {
      close_review = close_fn,
    },

    win = {
      input = {
        keys = {
          ["q"] = "close_review",
        },
      },
      list = {
        keys = {
          ["q"] = "close_review",
        },
      },
    },
  })

  -- Bypass Snacks action system entirely for <CR>/<o>/<l>:
  -- Set raw vim keymaps on the picker's list and input windows.
  local picker = state.layout.picker
  if picker then
    local function open_current()
      load_item_diff(state, picker:current())
    end

    local cfg = require("gh-dash-diff").config.keymaps

    -- List window keymaps
    local list_win = picker.layout and picker.layout.wins and picker.layout.wins.list
    if list_win and list_win:valid() then
      local buf = list_win.buf
      vim.keymap.set("n", "<CR>", open_current, { buffer = buf, silent = true })
      vim.keymap.set("n", "o", open_current, { buffer = buf, silent = true })
      vim.keymap.set("n", "l", open_current, { buffer = buf, silent = true })
      if cfg.toggle_explorer then
        vim.keymap.set("n", cfg.toggle_explorer, function()
          M.toggle(state)
        end, { buffer = buf, silent = true })
      end
      if cfg.toggle_viewed then
        vim.keymap.set("n", cfg.toggle_viewed, function()
          local item = picker:current()
          if item and item.type == "file" and item.filename then
            local viewed = state.review.viewed_files
            if viewed[item.filename] then
              viewed[item.filename] = nil
              vim.notify("Unmarked: " .. item.filename)
            else
              viewed[item.filename] = true
              vim.notify("Viewed: " .. item.filename)
            end
            M.refresh(state)
          end
        end, { buffer = list_win.buf, silent = true })
      end
    end

    -- Input window keymaps
    local input_win = picker.layout and picker.layout.wins and picker.layout.wins.input
    if input_win and input_win:valid() then
      local buf = input_win.buf
      vim.keymap.set({ "n", "i" }, "<CR>", open_current, { buffer = buf, silent = true })
      if cfg.toggle_explorer then
        vim.keymap.set("n", cfg.toggle_explorer, function()
          M.toggle(state)
        end, { buffer = buf, silent = true })
      end
    end
  end
end

--- Close and reopen the picker with items matching the current review_mode.
--- Uses vim.schedule to avoid Snacks WinResized errors during teardown.
--- @param state GhDashDiffState
function M.refresh_items(state)
  local config = require("gh-dash-diff").config

  -- Temporarily disable WinClosed guard during picker swap
  state.layout.ready = false

  if state.layout.picker then
    pcall(function() state.layout.picker:close() end)
    state.layout.picker = nil
  end

  -- Defer reopen to next tick so Snacks finishes cleanup
  vim.schedule(function()
    M.open(state, config)

    -- Re-equalize diff windows after picker reopens
    local left_win = state.layout.left_win
    local right_win = state.layout.right_win
    if left_win and vim.api.nvim_win_is_valid(left_win)
      and right_win and vim.api.nvim_win_is_valid(right_win) then
      local total = vim.api.nvim_win_get_width(left_win)
        + vim.api.nvim_win_get_width(right_win)
      local half = math.floor(total / 2)
      vim.api.nvim_win_set_width(left_win, half)
    end

    state.layout.ready = true
  end)
end

--- Toggle the picker sidebar: close it if open, reopen it if closed.
--- @param state GhDashDiffState
function M.toggle(state)
  local config = require("gh-dash-diff").config

  state.layout.ready = false

  if state.layout.picker then
    pcall(function() state.layout.picker:close() end)
    state.layout.picker = nil
    state.layout.ready = true
  else
    vim.schedule(function()
      M.open(state, config)

      -- Re-equalize diff windows after picker reopens
      local left_win  = state.layout.left_win
      local right_win = state.layout.right_win
      if left_win  and vim.api.nvim_win_is_valid(left_win)
        and right_win and vim.api.nvim_win_is_valid(right_win) then
        local total = vim.api.nvim_win_get_width(left_win)
          + vim.api.nvim_win_get_width(right_win)
        local half = math.floor(total / 2)
        vim.api.nvim_win_set_width(left_win, half)
      end

      state.layout.ready = true
    end)
  end
end

--- Programmatically move the picker cursor to an item by index.
--- Used by ]f/[f and ]g/[g navigation keymaps.
--- @param state GhDashDiffState
--- @param idx number 1-based file index
function M.select_by_index(state, idx)
  if not state.layout.picker then return end
  -- In file mode, items include dir_header rows, so map file idx → picker row
  local picker_row = state.layout.picker_file_map and state.layout.picker_file_map[idx] or idx
  pcall(function() state.layout.picker:set_cursor(picker_row) end)
  M.refresh(state)
end

return M
