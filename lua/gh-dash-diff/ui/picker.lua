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

--- Build picker items from a PR file list.
--- @param files GhFile[]
--- @return table[] items Snacks picker items
local function build_items(files)
  local items = {}
  for i, f in ipairs(files) do
    local icon  = STATUS_ICONS[f.status] or "?"
    local stats = string.format("+%d -%d", f.additions or 0, f.deletions or 0)
    table.insert(items, {
      idx        = i,
      text       = f.filename,      -- used for fuzzy filtering
      file       = f.filename,
      display    = short_path(f.filename),
      status     = f.status or "modified",
      icon       = icon,
      stats      = stats,
      additions  = f.additions or 0,
      deletions  = f.deletions or 0,
      _file_entry = f,              -- raw GhFile for downstream use
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
  state.pr.current_idx = item.idx
  M.refresh(state)
  require("gh-dash-diff.ui.diff").load_file(state, item._file_entry, item.idx)
end

--- Open the Snacks picker sidebar showing PR changed files.
--- Keeps itself open after selection (acts as a persistent sidebar).
--- @param state GhDashDiffState
--- @param config GhDashDiffConfig
function M.open(state, config)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-dash-diff requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local items = build_items(state.pr.files)

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
    title      = string.format("PR #%d", state.pr.number),
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

    -- Custom line format: active indicator + icon + short filename + diff stats
    format = function(item, _picker)
      local is_active = item.idx == state.pr.current_idx
      local is_viewed = state.review.viewed_files[item.filename]
      local hl        = STATUS_HL[item.status] or "Normal"
      local stat_hl   = item.additions > 0 and "GhStatAdd" or "GhStatDel"
      local prefix    = is_active and "▶ " or "  "
      local name_hl   = is_active and "Special" or "Normal"
      local viewed_chunk = is_viewed
        and { "✔ ", "DiagnosticOk" }
        or  { "  ", "Normal" }
      return {
        { prefix .. item.icon .. " ", is_active and "Special" or hl },
        viewed_chunk,
        { item.display .. " ",        name_hl },
        { item.stats,                 stat_hl },
      }
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

    -- List window keymaps
    local list_win = picker.layout and picker.layout.wins and picker.layout.wins.list
    if list_win and list_win:valid() then
      local buf = list_win.buf
      vim.keymap.set("n", "<CR>", open_current, { buffer = buf, silent = true })
      vim.keymap.set("n", "o", open_current, { buffer = buf, silent = true })
      vim.keymap.set("n", "l", open_current, { buffer = buf, silent = true })
    end

    -- Input window keymaps
    local input_win = picker.layout and picker.layout.wins and picker.layout.wins.input
    if input_win and input_win:valid() then
      local buf = input_win.buf
      vim.keymap.set({ "n", "i" }, "<CR>", open_current, { buffer = buf, silent = true })
    end
  end
end

--- Programmatically move the picker cursor to a file by index.
--- Used by ]f/[f navigation keymaps.
--- @param state GhDashDiffState
--- @param idx number 1-based file index
function M.select_by_index(state, idx)
  if state.layout.picker then
    pcall(function() state.layout.picker:set_cursor(idx) end)
    M.refresh(state)
  end
end

return M
