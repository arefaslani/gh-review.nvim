local M = {}

-- Module-level filter state — survives recursive M.open calls.
-- Keys are qualifier strings (e.g. "author:@me"), values are true.
local _active_filters = {}
local _filter_ns = vim.api.nvim_create_namespace("gh-pr-picker-filter")

--- Build the combined search string from active filters.
local function build_search()
  local parts = {}
  for q, _ in pairs(_active_filters) do
    table.insert(parts, q)
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return table.concat(parts, " ")
end

--- Build a display label for the active filters.
local function filter_label()
  local s = build_search()
  return s or ""
end

local REVIEW_ICONS = {
  APPROVED           = "✔",
  CHANGES_REQUESTED  = "✗",
  REVIEW_REQUIRED    = "○",
  draft              = "◌",
}

--- Format PR stats as "+42/-10"
local function fmt_stats(pr)
  return string.format("+%d/-%d", pr.additions or 0, pr.deletions or 0)
end

--- Get review status icon for a PR.
local function review_icon(pr)
  if pr.isDraft then return REVIEW_ICONS.draft end
  return REVIEW_ICONS[pr.reviewDecision] or REVIEW_ICONS.REVIEW_REQUIRED
end

--- Build picker items from a PR list.
--- @param prs table[]
--- @return table[]
local function build_items(prs)
  local items = {}
  for i, pr in ipairs(prs) do
    local author = pr.author and pr.author.login or "unknown"
    table.insert(items, {
      idx       = i,
      text      = string.format("#%d %s @%s", pr.number, pr.title, author),
      number    = pr.number,
      title     = pr.title,
      author    = author,
      icon      = review_icon(pr),
      stats     = fmt_stats(pr),
      body      = pr.body or "",
      isDraft   = pr.isDraft,
      _pr       = pr,
    })
  end
  return items
end

--- Open a Snacks picker to browse PRs.
--- @param prs table[]|nil List of PRs from gh/prs.lua, or nil for loading state
--- @param opts? {title?: string, owner?: string, repo?: string, _base_title?: string}
function M.open(prs, opts)
  opts = opts or {}
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("gh-review requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  -- Mutable context so filters still work after async owner/repo resolution
  local ctx = { owner = opts.owner, repo = opts.repo }
  local prs_mod = require("gh-review.gh.prs")
  local base_title = opts._base_title or opts.title or "GitHub PRs"

  local function get_title()
    local label = filter_label()
    if label ~= "" then
      return base_title .. "  [" .. label .. "]"
    end
    return base_title
  end

  local picker_ref = nil
  local current_items  -- forward-declared; assigned below after helper fns
  local _last_search = ""  -- tracks last search sent to gh CLI
  local _fetch_id    = 0   -- incremented on each fetch; used to discard stale responses

  local function make_loading_item(text)
    return { idx = 1, text = text, _loading = true, number = 0,
      title = text, author = "", icon = "…", stats = "", body = "", isDraft = false,
      _pr = { number = 0, title = text, body = "",
               headRefName = "?", baseRefName = "?", changedFiles = 0 } }
  end

  --- Fetch PRs and update items in-place, showing a loading placeholder while waiting.
  --- Also syncs filter.search so the statuscolumn reflects the active search.
  local function reload_prs(list_opts)
    if not (ctx.owner and ctx.repo) then
      vim.notify("gh-review: owner/repo not available for search", vim.log.levels.WARN)
      return
    end
    local search = list_opts and list_opts.search or ""
    _last_search = search
    _fetch_id = _fetch_id + 1
    local my_id = _fetch_id
    current_items = { make_loading_item("Loading PRs…") }
    if picker_ref and not picker_ref.closed then
      picker_ref.input.filter.search = search
      picker_ref.input:update()
      picker_ref.title = base_title .. "  [loading…]"
      picker_ref:refresh()
    end
    prs_mod.list(ctx.owner, ctx.repo, list_opts, function(err, new_prs)
      if my_id ~= _fetch_id then return end
      if err then
        vim.notify("gh-review: " .. err, vim.log.levels.ERROR)
        return
      end
      current_items = build_items(new_prs or {})
      if picker_ref and not picker_ref.closed then
        picker_ref.title = get_title()
        picker_ref:refresh()
      end
    end)
  end

  --- Toggle a single qualifier in the active filters and re-fetch PRs in-place.
  local function toggle_filter(qualifier)
    if _active_filters[qualifier] then
      _active_filters[qualifier] = nil
    else
      _active_filters[qualifier] = true
    end
    local search = build_search()
    reload_prs(search and { search = search } or nil)
  end

  -- Cached contributor logins for the current repo, populated asynchronously.
  local contributor_logins = {}
  if ctx.owner and ctx.repo then
    prs_mod.list_contributors(ctx.owner, ctx.repo, function(err, logins)
      if not err and logins then contributor_logins = logins end
    end)
  end

  local function build_hint_line()
    local first = contributor_logins[1]
    local author_hint = first and ("author:" .. first) or "author:@me"
    return "Tip: " .. author_hint .. "  is:open  is:closed  review-requested:@me"
  end

  -- Assign the mutable items source (forward-declared above)
  current_items = prs and build_items(prs) or {
    { idx = 1, text = "Loading PRs…", _loading = true, number = 0,
      title = "Loading PRs…", author = "", icon = "…", stats = "",
      body = "", isDraft = false,
      _pr = { number = 0, title = "Loading…", body = "",
               headRefName = "?", baseRefName = "?", changedFiles = 0 } },
  }

  picker_ref = Snacks.picker.pick({
    source        = "gh_prs",
    title         = get_title(),
    supports_live = true,
    live          = false,

    -- In live mode (toggled with <C-g>) the input text becomes filter.search,
    -- which is passed to gh CLI as a search query. In normal mode the input
    -- does fuzzy matching on the already-loaded items.
    finder = function(_opts, find_ctx)
      local search = (find_ctx and find_ctx.filter and find_ctx.filter.search) or ""
      if search ~= _last_search and picker_ref and ctx.owner and ctx.repo then
        _last_search = search
        _fetch_id = _fetch_id + 1
        local my_id = _fetch_id
        current_items = { make_loading_item("Loading PRs…") }
        prs_mod.list(ctx.owner, ctx.repo, search ~= "" and { search = search } or nil,
          function(err, new_prs)
            if my_id ~= _fetch_id then return end
            if err then vim.notify("gh-review: " .. err, vim.log.levels.ERROR); return end
            current_items = build_items(new_prs or {})
            if picker_ref and not picker_ref.closed then
              picker_ref.title = get_title()
              picker_ref:refresh()
            end
          end)
      end
      return current_items
    end,

    layout = {
      preset  = "dropdown",
      preview = true,
      width   = 0.7,
      height  = 0.6,
    },

    format = function(item, _picker)
      if item._loading then
        return { { "  Loading PRs…", "Comment" } }
      end
      local num_hl  = "Special"
      local icon_hl = item.isDraft and "Comment"
        or (item.icon == REVIEW_ICONS.APPROVED and "GhStatAdd"
        or  (item.icon == REVIEW_ICONS.CHANGES_REQUESTED and "GhStatDel"
        or   "Normal"))
      return {
        { string.format("#%-4d ", item.number), num_hl },
        { item.icon .. " ",                     icon_hl },
        { item.title .. "  ",                   "Normal" },
        { "@" .. item.author .. "  ",           "Comment" },
        { item.stats,                            "Comment" },
      }
    end,

    preview = function(ctx)
      local item = ctx.item
      if not item then return end
      local pr = item._pr
      local lines = {
        string.format("# PR #%d: %s", pr.number, pr.title),
        "",
        string.format("Author : @%s", item.author),
        string.format("Branch : %s → %s", pr.headRefName or "?", pr.baseRefName or "?"),
        string.format("Status : %s %s", item.icon,
          pr.isDraft and "Draft" or (pr.reviewDecision or "No review")),
        string.format("Changes: %s (%d files)", item.stats, pr.changedFiles or 0),
        "",
      }
      if pr.body and pr.body ~= "" then
        for _, line in ipairs(vim.split(pr.body, "\n", { plain = true })) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, "_No description provided._")
      end
      table.insert(lines, "")
      table.insert(lines, "---")
      table.insert(lines, build_hint_line())
      ctx.preview:set_lines(lines)
      ctx.preview:highlight({ ft = "markdown" })
    end,

    confirm = function(_picker, item)
      if not item or item._loading then return end
      _active_filters = {}
      -- Show a loading message in the picker while the diff view loads;
      -- the picker is closed by the on_open callback once the view is ready.
      current_items = { { idx = 1, text = "Opening PR #" .. item.number .. "…",
        _loading = true, number = 0, title = "Opening PR #" .. item.number .. "…",
        author = "", icon = "…", stats = "", body = "", isDraft = false,
        _pr = { number = 0, title = "Opening…", body = "",
                 headRefName = "?", baseRefName = "?", changedFiles = 0 } } }
      picker_ref.title = "Opening PR #" .. item.number .. "…"
      picker_ref:refresh()
      require("gh-review").open_pr(item.number, {
        on_open = function()
          if picker_ref and not picker_ref.closed then picker_ref:close() end
        end,
      })
    end,

    actions = {
      refresh_prs = function(_picker)
        _picker:close()
        _active_filters = {}
        require("gh-review").open_dash()
      end,
    },
  })

  -- Expose an update function so open_dash can populate items after async fetch
  if picker_ref then
    picker_ref.gh_update = function(new_prs, new_opts)
      new_opts = new_opts or {}
      ctx.owner = new_opts.owner or ctx.owner
      ctx.repo  = new_opts.repo  or ctx.repo
      base_title = new_opts.title or base_title
      _fetch_id = _fetch_id + 1  -- discard any in-flight live searches
      _last_search = ""
      current_items = build_items(new_prs or {})
      picker_ref.title = get_title()
      -- Start fetching contributors now that we have owner/repo
      if ctx.owner and ctx.repo then
        prs_mod.list_contributors(ctx.owner, ctx.repo, function(err, logins)
          if not err and logins then contributor_logins = logins end
        end)
      end
      picker_ref:refresh()
    end
  end

  -- Set raw keymaps on picker buffers (Snacks action resolution is unreliable for these).
  if picker_ref then
    local function set_filter_keys(buf)
      local o = { buffer = buf, silent = true }
      vim.keymap.set({ "n", "i" }, "<C-r>", function()
        if picker_ref then picker_ref:close() end
        _active_filters = {}
        require("gh-review").open_dash()
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-a>", function()
        toggle_filter("author:@me")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-o>", function()
        toggle_filter("is:open")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-x>", function()
        toggle_filter("is:closed")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-n>", function()
        toggle_filter("review-requested:@me")
      end, o)
      vim.keymap.set({ "n", "i" }, "<C-g>", function()
        if not picker_ref.opts.live then
          -- Pre-populate search with active filters so they're editable in live mode
          picker_ref.input.filter.search = build_search() or ""
        end
        require("snacks.picker.actions").toggle_live(picker_ref)
      end, o)
    end

    local list_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.list
    if list_win and list_win:valid() then
      set_filter_keys(list_win.buf)
    end

    local input_win = picker_ref.layout and picker_ref.layout.wins and picker_ref.layout.wins.input
    if input_win and input_win:valid() then
      set_filter_keys(input_win.buf)
      -- Show active filters as virtual text (doesn't interfere with fuzzy matching)
      local label = filter_label()
      if label ~= "" then
        vim.api.nvim_buf_set_extmark(input_win.buf, _filter_ns, 0, 0, {
          virt_text = { { " filter: " .. label, "Comment" } },
          virt_text_pos = "right_align",
        })
      end
    end
  end

  return picker_ref
end

return M
