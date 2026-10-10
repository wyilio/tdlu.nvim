local model = require('tdlu.model')
local anchors = require('tdlu.anchors')
local M = {}
function M.code_window(runtime)
  local api = vim.api
  local function suitable(window)
    return api.nvim_win_is_valid(window)
      and api.nvim_win_get_tabpage(window) == api.nvim_get_current_tabpage()
      and api.nvim_win_get_config(window).relative == ''
      and vim.bo[api.nvim_win_get_buf(window)].buftype == ''
      and not vim.b[api.nvim_win_get_buf(window)].tdlu_pane
  end
  if runtime.code_window and suitable(runtime.code_window) then
    return runtime.code_window
  end
  for _, window in ipairs(api.nvim_tabpage_list_wins(0)) do
    if suitable(window) then
      runtime.code_window = window
      return window
    end
  end
  vim.cmd('botright vnew')
  runtime.code_window = api.nvim_get_current_win()
  return runtime.code_window
end
function M.jump(workspace, inv, id, runtime)
  local node = assert(inv.nodes[id], 'Unknown entry')
  assert(node.kind == 'location', 'Use the public jump action to follow trace links')
  local buffer, anchor = anchors.resolve(workspace.root, node)
  assert(buffer, anchor)
  local window = M.code_window(runtime)
  vim.api.nvim_win_call(window, function()
    vim.cmd('hide buffer ' .. buffer)
  end)
  local start = anchor.spans[1]
  vim.api.nvim_win_set_cursor(window, { start.start_row + 1, start.start_col })
  vim.api.nvim_set_current_win(window)
  vim.api.nvim_buf_clear_namespace(buffer, runtime.highlight_ns, 0, -1)
  if anchor.kind ~= 'point' then
    for _, span in ipairs(anchor.spans) do
      vim.api.nvim_buf_set_extmark(
        buffer,
        runtime.highlight_ns,
        span.start_row,
        span.start_col,
        { end_row = span.end_row, end_col = span.end_col, hl_group = 'Visual', priority = 150 }
      )
    end
  end
  model.select(inv, id)
  runtime.last_jump =
    { buffer = buffer, row = start.start_row + 1, column = start.start_col, id = id }
  runtime.pinned_source = { investigation = inv.id, id = id }
end
function M.off_trail(runtime, inv)
  local last = runtime.last_jump
  if not last or last.id ~= inv.selected then
    return true
  end
  local window = runtime.code_window
  if
    not window
    or not vim.api.nvim_win_is_valid(window)
    or vim.api.nvim_win_get_buf(window) ~= last.buffer
  then
    return true
  end
  local point = vim.api.nvim_win_get_cursor(window)
  return point[1] ~= last.row or point[2] ~= last.column
end
return M
