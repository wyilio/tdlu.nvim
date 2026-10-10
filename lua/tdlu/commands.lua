local M = {
  names = {
    'new',
    'list',
    'open',
    'locations',
    'add',
    'insert',
    'previous',
    'next',
    'jump',
    'panel',
    'pane-view',
    'move',
    'remove',
    'detach',
    'back',
    'reattach',
    'rename',
    'title',
    'archive',
    'save',
    'branch',
    'branches',
    'pin',
    'invalidate',
    'repair',
    'bypass',
    'reparent',
    'undo',
    'redo',
    'export',
    'export-copy',
    'recover',
    'recover-draft',
    'reload',
    'save-copy',
    'relink',
    'sibling-next',
    'sibling-previous',
  },
}
local function core()
  return require('tdlu')
end
local function selection(opts)
  return { visual = opts.range > 0 }
end
function M.dispatch(opts)
  local action, argument = opts.args:match('^(%S+)%s*(.*)$')
  action, argument = action or 'list', argument or ''
  if
    action == 'new'
    or action == 'open'
    or action == 'rename'
    or action == 'title'
    or action == 'list'
    or action == 'locations'
    or action == 'invalidate'
  then
    return core()[action](argument ~= '' and argument or nil)
  elseif action == 'add' or action == 'insert' or action == 'reattach' then
    local capture = selection(opts)
    capture.title = argument
    capture.prompt_title = action ~= 'reattach'
    return core()[action](capture)
  elseif action == 'branch' then
    local capture = selection(opts)
    capture.prompt_title = true
    return core().branch(argument, capture)
  elseif action == 'jump' then
    return core().jump(tonumber(argument) or (argument ~= '' and argument or nil))
  elseif action == 'move' then
    local first, last, insertion = argument:match('^(%d+):(%d+)%s+(%d+)$')
    if not first then
      first, insertion = argument:match('^(%d+)%s+(%d+)$')
      last = first
    end
    if not first then
      return {
        ok = false,
        error = 'Use :TDLU move FIRST[:LAST] INSERTION (one-based primary positions)',
      }
    end
    return core().move(tonumber(first), tonumber(last), tonumber(insertion))
  elseif action == 'detach' then
    local first, last, name = argument:match('^(%d+):(%d+)%s+(.+)$')
    return core().detach(name or argument, first and tonumber(first), last and tonumber(last))
  elseif action == 'export' or action == 'export-copy' then
    local flags = {}
    argument = argument
      :gsub('%-%-metadata%-only', function()
        flags.metadata_only = true
        return ''
      end)
      :gsub('%-%-include%-unsaved', function()
        flags.include_unsaved = true
        return ''
      end)
      :gsub('%-%-current%-only', function()
        flags.current_only = true
        return ''
      end)
    argument = vim.trim(argument)
    return core()[action == 'export' and 'export' or 'export_copy'](
      argument ~= '' and argument or nil,
      flags
    )
  elseif action == 'relink' then
    return core().relink(argument ~= '' and argument or nil)
  elseif action == 'pane-view' then
    require('tdlu.ui').pane_view()
    return { ok = true }
  elseif action == 'sibling-next' or action == 'sibling-previous' then
    require('tdlu.ui').sibling(action == 'sibling-next' and 1 or -1, true)
    return { ok = true }
  elseif action == 'save-copy' then
    return core().save_copy()
  elseif action == 'recover-draft' then
    return core().recover_draft(argument ~= '' and argument or nil)
  end
  local noargs = {
    previous = true,
    next = true,
    panel = true,
    remove = true,
    back = true,
    archive = true,
    save = true,
    branches = true,
    pin = true,
    repair = true,
    bypass = true,
    reparent = true,
    undo = true,
    redo = true,
    recover = true,
    reload = true,
  }
  if noargs[action] then
    return core()[action]()
  end
  return { ok = false, error = 'Unknown command' }
end
function M.unregister()
  pcall(vim.api.nvim_del_user_command, 'TDLU')
end
function M.register(config)
  M.unregister()
  vim.api.nvim_create_user_command('TDLU', function(opts)
    local ok, value = pcall(M.dispatch, opts)
    core().notify(ok and value or { ok = false, error = tostring(value) })
  end, {
    nargs = '*',
    range = true,
    complete = function(lead, command)
      local items = M.names
      if command:match('TDLU%s+%S+%s') then
        items = { 'active', 'archived', 'all' }
        if core().session then
          for _, inv in pairs(core().workspace().investigations) do
            items[#items + 1] = inv.name
          end
        end
      end
      local matches = {}
      for _, item in ipairs(items) do
        if item:sub(1, #lead) == lead then
          matches[#matches + 1] = item
        end
      end
      return matches
    end,
    desc = 'Named, annotated code traces',
  })
end
return M
