local M = {}
local group = vim.api.nvim_create_augroup("GhReviewEvents", { clear = true })

function M.emit(event, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "GhReview:" .. event,
    data = data,
  })
end

function M.on(event, callback)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GhReview:" .. event,
    callback = function(ev) callback(ev.data) end,
  })
end

-- Events:
-- pr_loaded        {pr, files}         init.lua      -> ui/init.lua
-- file_selected    {idx, file}         ui/picker.lua -> ui/diff.lua, ui/comments.lua
-- comment_added    {comment}           ui/input.lua  -> ui/comments.lua
-- review_submitted {event, body}       gh/reviews    -> init.lua
-- threads_loaded   {threads}           gh/reviews    -> ui/comments.lua
-- layout_created   layout table        ui/layout.lua -> ui/picker.lua, ui/diff.lua
-- review_closed    {}                  ui/layout.lua -> all UI modules

return M
