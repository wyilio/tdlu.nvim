local model = require('tdlu.model')
local anchors = require('tdlu.anchors')
local api = vim.api
local M = { pane = {}, browser_state = nil, generation = 0 }
local function core()
  return require('tdlu')
end
local function valid(window)
  return window and api.nvim_win_is_valid(window)
end
local function buffer(kind, editable)
  local created = api.nvim_create_buf(false, true)
  vim.bo[created].buftype = editable and 'acwrite' or 'nofile'
  vim.bo[created].bufhidden = 'hide'
  vim.bo[created].swapfile = false
  if not editable then
    -- Legacy AutoPairs assumes insert-mode <CR> has a string rhs, but these
    -- panes own Lua navigation mappings. Markdown notes retain normal pairing.
    vim.b[created].autopairs_loaded = 1
  end
  vim.bo[created].filetype = editable and 'markdown' or 'tdlu'
  vim.b[created].tdlu_pane = kind
  return created
end
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  if vim.bo[buf].buftype ~= 'acwrite' then
    vim.bo[buf].modifiable = false
  end
end
local function single(text)
  return (text or ''):gsub('[\r\n]', ' ')
end
local function node_title(node)
  if node.title and node.title ~= '' then
    return single(node.title)
  end
  if node.kind == 'location' then
    local anchor = node.original or node.anchor
    for _, context in ipairs(anchor.context or {}) do
      if context.offset == 0 and vim.trim(context.text) ~= '' then
        return vim.fn.strcharpart(single(vim.trim(context.text)), 0, 60)
      end
    end
    return vim.fn.fnamemodify(node.anchor.path, ':t')
      .. ':'
      .. tostring(node.anchor.spans[1].start_row + 1)
  end
  return 'Trace link'
end
local style_namespace = api.nvim_create_namespace('tdlu-ui-style')
local function style_rows(buf, lines, header)
  api.nvim_set_hl(0, 'TDLUPath', { default = true, link = 'Type' })
  api.nvim_buf_clear_namespace(buf, style_namespace, 0, -1)
  local function highlight(row, first, last, group)
    if first and last >= first then
      api.nvim_buf_set_extmark(buf, style_namespace, row - 1, first - 1, {
        end_col = last,
        hl_group = group,
        priority = group == 'TDLUPath' and 210 or 110,
        hl_mode = 'combine',
      })
    end
  end
  for row, line in ipairs(lines) do
    if header and row <= 2 then
      highlight(row, 1, #line, row == 1 and 'Title' or 'Comment')
      local first, last = line:find('[off-trail]', 1, true)
      highlight(row, first, last, 'WarningMsg')
    else
      local first_separator, separator_end = line:find(' · ', 1, true)
      if first_separator then
        local title_start = (line:find('%. ') or 0) + 2
        highlight(row, title_start, first_separator - 1, 'Function')
        local second_separator, second_end = line:find(' · ', separator_end + 1, true)
        second_separator = second_separator or (#line + 1)
        if second_separator then
          local path = line:sub(separator_end + 1, second_separator - 1)
          local position_start = path:find(':%d+:%d+$')
          highlight(
            row,
            separator_end + 1,
            position_start and separator_end + position_start - 1 or second_separator - 1,
            'TDLUPath'
          )
          if position_start then
            highlight(row, separator_end + position_start, second_separator - 1, 'Number')
          end
          if second_end then
            highlight(row, second_end + 1, #line, 'Comment')
          end
        end
      end
      local ordinal_start, ordinal_end = line:find('%d+%. ')
      highlight(row, ordinal_start, ordinal_end, 'Number')
      for marker, group in pairs({
        ['●'] = 'Special',
        ['↳'] = 'Special',
        ['↪'] = 'Special',
        ['⚠'] = 'DiagnosticError',
        ['~'] = 'DiagnosticWarn',
      }) do
        local first, last = line:find(marker, 1, true)
        highlight(row, first, last, group)
      end
    end
  end
end
function M.apply_theme()
  if not core().config.follow_colorscheme then
    return
  end
  for group, target in pairs({
    TelescopeNormal = 'Normal',
    TelescopePromptNormal = 'TelescopeNormal',
    TelescopeResultsNormal = 'TelescopeNormal',
    TelescopePreviewNormal = 'TelescopeNormal',
    TelescopeBorder = 'Comment',
    TelescopePromptBorder = 'TelescopeBorder',
    TelescopeResultsBorder = 'TelescopeBorder',
    TelescopePreviewBorder = 'TelescopeBorder',
    TelescopeSelectionCaret = 'TelescopeSelection',
  }) do
    api.nvim_set_hl(0, group, { link = target })
  end
  -- Use only the theme's selection background so row text keeps its own colors.
  local visual = api.nvim_get_hl(0, { name = 'Visual', link = false })
  local cursorline = api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  api.nvim_set_hl(0, 'TelescopeSelection', {
    bg = visual.bg or cursorline.bg,
    ctermbg = visual.ctermbg or cursorline.ctermbg,
  })
end
local row_namespace = api.nvim_create_namespace('tdlu-row-selection')
local function highlight_selection(buf, row, caret)
  api.nvim_buf_clear_namespace(buf, row_namespace, 0, -1)
  if not row then
    return
  end
  -- Match Telescope's default selection groups, caret, and full-width extent.
  -- Default links keep the built-in browser independent of Telescope.
  api.nvim_set_hl(0, 'TelescopeSelection', { default = true, link = 'Visual' })
  api.nvim_set_hl(0, 'TelescopeSelectionCaret', { default = true, link = 'TelescopeSelection' })
  local options = {
    end_row = row + 1,
    end_col = 0,
    hl_eol = true,
    hl_group = 'TelescopeSelection',
    hl_mode = 'combine',
    priority = 200,
  }
  if caret then
    options.virt_text = { { '> ', 'TelescopeSelectionCaret' } }
    options.virt_text_pos = 'overlay'
  end
  api.nvim_buf_set_extmark(buf, row_namespace, row, 0, options)
end
function M.highlight_sidebar()
  if not valid(M.pane.trail_win) then
    return
  end
  local row = api.nvim_win_get_cursor(M.pane.trail_win)[1]
  highlight_selection(M.pane.trail_buf, M.pane.row_ids[row] and row - 1 or nil, false)
end
local function label(inv, node)
  if node.kind == 'link' then
    local target = core().workspace().investigations[node.target]
    return '↪ ' .. single(target and target.name or '[missing trace]')
  end
  local span = node.anchor.spans[1]
  return string.format(
    '%s%s · %s:%d:%d',
    node.validity == 'invalid' and '⚠ ' or node.validity == 'provisional' and '~ ' or '',
    node_title(node),
    node.anchor.path,
    span.start_row + 1,
    span.start_col + 1
  )
end
function M.rows(inv)
  local rows, seen = {}, {}
  local function walk(id, ancestry, depth)
    if seen[id] or not inv.nodes[id] then
      return
    end
    seen[id] = true
    local position = model.index(inv.primary, id)
    local node = inv.nodes[id]
    rows[#rows + 1] = {
      id = id,
      inv_id = inv.id,
      text = string.rep('  ', depth)
        .. (position and tostring(position) .. '. ' or '↳ ')
        .. label(inv, node),
      ancestry = ancestry,
      search = single(
        inv.name .. ' ' .. ancestry .. ' ' .. label(inv, node) .. ' ' .. id .. ' ' .. node.notes
      ),
      depth = depth,
    }
    for _, child in ipairs(model.children(inv, id)) do
      walk(
        child.destination,
        ancestry .. ' / ' .. node_title(node),
        depth + (child.kind == 'branch' and 1 or 0)
      )
    end
  end
  for _, id in ipairs(inv.roots) do
    walk(id, inv.name, 0)
  end
  for _, id in ipairs(inv.orphans) do
    walk(id, inv.name .. ' / orphaned', 0)
  end
  local remaining = vim.tbl_keys(inv.nodes)
  table.sort(remaining)
  for _, id in ipairs(remaining) do
    walk(id, inv.name, 0)
  end
  return rows
end
function M.selected()
  if
    M.browser_state
    and valid(M.browser_state.results_win)
    and api.nvim_get_current_win() == M.browser_state.results_win
  then
    local row = M.browser_state.filtered[M.browser_state.selected]
    return row and row.id
  end
  if valid(M.pane.trail_win) and api.nvim_get_current_win() == M.pane.trail_win then
    return M.pane.preview_id or M.pane.row_ids[api.nvim_win_get_cursor(0)[1]]
  end
end
function M.notes_modified()
  return M.pane.notes_buf
      and api.nvim_buf_is_valid(M.pane.notes_buf)
      and vim.bo[M.pane.notes_buf].modified
    or false
end
function M.store_notes()
  local target = M.pane.target
  if not target or not M.notes_modified() then
    return
  end
  local workspace = core().workspace()
  assert(not core().storage.readonly, 'Read-only notes cannot be committed')
  local inv = assert(
    workspace.investigations[target.inv_id],
    'Pinned trace no longer exists; save the notes buffer separately'
  )
  local owner = target.id == 'overview' and inv
    or assert(
      inv.nodes[target.id],
      'Pinned node no longer exists; save the notes buffer separately'
    )
  owner.notes = table.concat(api.nvim_buf_get_lines(M.pane.notes_buf, 0, -1, false), '\n')
  owner.updated_at, inv.updated_at = os.time(), os.time()
  core().runtime.unsaved = true
end
function M.reconcile()
  local target = M.pane.target
  if not target then
    return
  end
  local workspace = core().workspace()
  local inv = workspace.investigations[target.inv_id]
  if inv and (target.id == 'overview' or inv.nodes[target.id]) then
    return
  end
  if target.id ~= 'overview' then
    for inv_id, candidate in pairs(workspace.investigations) do
      if candidate.nodes[target.id] then
        target.inv_id = inv_id
        return
      end
    end
  end
  -- Structural deletion is explicit and the draft has already been committed.
  M.pane.target = nil
  if M.pane.notes_buf and api.nvim_buf_is_valid(M.pane.notes_buf) then
    set_lines(M.pane.notes_buf, { '' })
  end
end
function M.notes_saved()
  if M.pane.notes_buf and api.nvim_buf_is_valid(M.pane.notes_buf) then
    vim.bo[M.pane.notes_buf].modified = false
  end
end
function M.retarget(id)
  local inv = core().current()
  if not inv then
    return
  end
  -- A visible editor owns its pinned draft even if code or sidebar selection changes.
  if valid(M.pane.notes_win) and api.nvim_get_current_win() == M.pane.notes_win then
    return
  end
  if M.notes_modified() then
    local saved = core().save()
    if not saved.ok then
      return
    end
  end
  if not M.pane.notes_buf or not api.nvim_buf_is_valid(M.pane.notes_buf) then
    return
  end
  id = id or inv.selected or 'overview'
  local owner = id == 'overview' and inv or inv.nodes[id]
  if not owner then
    return
  end
  M.pane.target = { inv_id = inv.id, id = id }
  set_lines(M.pane.notes_buf, vim.split(owner.notes, '\n', { plain = true }))
  vim.bo[M.pane.notes_buf].modifiable = not core().storage.readonly
  if valid(M.pane.notes_win) then
    vim.wo[M.pane.notes_win].winbar = id == 'overview' and 'Trace notes · <leader>tn switch'
      or 'Step notes · ' .. node_title(owner):gsub('%%', '%%%%') .. ' · <leader>tn switch'
  end
end
function M.toggle_notes()
  local inv = core().current()
  local target = M.pane.target
  local id = target and target.id ~= 'overview' and 'overview' or inv.selected
  if not id then
    core().notify({ ok = false, error = 'Capture or select a step before switching to step notes' })
    return
  end
  M.note(id)
end
local function close_sidebar()
  vim.cmd('stopinsert')
  M.panel()
end
local function notes_autocmds(buf)
  vim.keymap.set({ 'n', 'i', 'v' }, '<C-c>', close_sidebar, {
    buffer = buf,
    silent = true,
    desc = 'TDLU close sidebar',
  })
  vim.keymap.set('n', '<leader>tn', M.toggle_notes, {
    buffer = buf,
    silent = true,
    desc = 'TDLU toggle step/trace notes',
  })
  local group = api.nvim_create_augroup('TDLUNotes', { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      M.generation = M.generation + 1
      local generation = M.generation
      vim.defer_fn(function()
        if
          generation ~= M.generation
          or not api.nvim_buf_is_valid(buf)
          or not M.notes_modified()
        then
          return
        end
        local ok, reason = pcall(function()
          M.store_notes()
          require('tdlu.storage').draft(core().workspace(), core().storage)
          core().notify(core().save())
        end)
        if not ok then
          core().runtime.unsaved = true
          vim.notify('TDLU notes: ' .. tostring(reason), vim.log.levels.ERROR)
        end
        core().changed()
      end, core().config.notes_debounce_ms)
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      core().notify(core().save())
    end,
  })
  api.nvim_create_autocmd('BufLeave', {
    group = group,
    buffer = buf,
    callback = function()
      if not M.closing and M.notes_modified() then
        core().notify(core().save())
      end
    end,
  })
end
local pane_options = { 'number', 'relativenumber', 'winbar', 'wrap', 'linebreak', 'winfixwidth' }
local function release_code_windows()
  for _, key in ipairs({ 'trail_win', 'notes_win' }) do
    local window = M.pane[key]
    if valid(window) and not vim.b[api.nvim_win_get_buf(window)].tdlu_pane then
      for option, value in pairs((M.pane.window_options or {})[window] or {}) do
        vim.wo[window][option] = value
      end
      M.pane.window_options[window] = nil
      M.pane[key] = nil
    end
  end
end
function M.close_panel()
  release_code_windows()
  M.panel_closing = true
  M.generation = M.generation + 1
  for _, window in ipairs({ M.pane.notes_win or false, M.pane.trail_win or false }) do
    if window and valid(window) then
      pcall(api.nvim_win_close, window, true)
    end
  end
  M.pane.notes_win, M.pane.trail_win = nil, nil
  M.pane.window_options = {}
  M.panel_closing = false
end
function M.panel(force)
  if valid(M.pane.trail_win) or valid(M.pane.notes_win) then
    if force then
      M.render()
      return
    end
    if M.notes_modified() then
      local saved = core().save()
      if not saved.ok then
        core().notify(saved)
        return
      end
    end
    M.close_panel()
    return
  end
  local previous = api.nvim_get_current_win()
  local original_options = {}
  for _, option in ipairs(pane_options) do
    original_options[option] = vim.wo[previous][option]
  end
  M.pane.window_options = M.pane.window_options or {}
  if not M.pane.trail_buf or not api.nvim_buf_is_valid(M.pane.trail_buf) then
    M.pane.trail_buf = buffer('trail')
  end
  if not M.pane.notes_buf or not api.nvim_buf_is_valid(M.pane.notes_buf) then
    M.pane.notes_buf = buffer('notes', true)
    api.nvim_buf_set_name(M.pane.notes_buf, 'tdlu://notes/' .. model.id())
    notes_autocmds(M.pane.notes_buf)
  end
  vim.cmd(
    (core().config.side == 'left' and 'topleft' or 'botright')
      .. ' '
      .. math.min(core().config.width, math.floor(vim.o.columns / 2))
      .. 'vsplit'
  )
  M.pane.trail_win = api.nvim_get_current_win()
  M.pane.window_options[M.pane.trail_win] = vim.deepcopy(original_options)
  api.nvim_win_set_buf(M.pane.trail_win, M.pane.trail_buf)
  vim.wo[M.pane.trail_win].number, vim.wo[M.pane.trail_win].relativenumber = false, false
  vim.wo[M.pane.trail_win].winfixwidth = true
  vim.wo[M.pane.trail_win].wrap = true
  M.pane.narrow = vim.o.columns < core().config.narrow_columns
  if not M.pane.narrow then
    vim.cmd('belowright split')
    M.pane.notes_win = api.nvim_get_current_win()
    M.pane.window_options[M.pane.notes_win] = vim.deepcopy(original_options)
    api.nvim_win_set_buf(M.pane.notes_win, M.pane.notes_buf)
    vim.wo[M.pane.notes_win].wrap = true
    vim.wo[M.pane.notes_win].linebreak = true
    vim.wo[M.pane.notes_win].number = false
  end
  local panels_group = api.nvim_create_augroup('TDLUPanels', { clear = true })
  api.nvim_create_autocmd('BufWinEnter', {
    group = panels_group,
    callback = release_code_windows,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = panels_group,
    callback = function(event)
      if M.panel_closing or M.closing then
        return
      end
      local window = tonumber(event.match)
      if window == M.pane.trail_win or window == M.pane.notes_win then
        vim.schedule(function()
          if M.notes_modified() then
            core().notify(core().save())
          end
          M.close_panel()
        end)
      end
    end,
  })
  local trail_group = api.nvim_create_augroup('TDLUTrail', { clear = true })
  api.nvim_create_autocmd('CursorMoved', {
    group = trail_group,
    buffer = M.pane.trail_buf,
    callback = function()
      if valid(M.pane.trail_win) then
        M.pane.preview_id = M.pane.row_ids[api.nvim_win_get_cursor(M.pane.trail_win)[1]]
        M.highlight_sidebar()
      end
    end,
  })
  local mappings = {
    t = function()
      core().notify(core().title(nil, M.selected()))
    end,
    ['<CR>'] = function()
      core().notify(core().jump(M.selected()))
    end,
    n = function()
      local id = M.selected()
      if id then
        M.note(id)
      end
    end,
    d = function()
      local id = M.selected()
      if id then
        core().notify(core().remove({ id }))
      end
    end,
    x = function()
      local id = M.selected()
      local inv = core().current()
      local position = id and model.index(inv.primary, id)
      core().notify(core().detach(nil, position, position))
    end,
    J = function()
      M.reorder(1)
    end,
    K = function()
      M.reorder(-1)
    end,
    ['<Left>'] = function()
      M.sibling(-1, false)
    end,
    ['<Right>'] = function()
      M.sibling(1, false)
    end,
    ['<Up>'] = function()
      local inv = core().current()
      local source = model.parent(inv, M.selected())
      if source then
        M.select_sidebar(source)
      end
    end,
    q = function()
      M.panel()
    end,
    u = function()
      core().notify(core().undo())
    end,
    ['<C-r>'] = function()
      core().notify(core().redo())
    end,
  }
  local function mouse(open)
    local position = vim.fn.getmousepos()
    if position.winid ~= M.pane.trail_win then
      return
    end
    local id = M.pane.row_ids[position.line]
    if position.line == M.pane.card_row then
      for _, span in ipairs(M.pane.card_spans or {}) do
        if position.column >= span.first and position.column <= span.last then
          id = span.id
          break
        end
      end
    end
    if id then
      api.nvim_win_set_cursor(M.pane.trail_win, { position.line, 0 })
      M.pane.preview_id = id
      M.highlight_sidebar()
      if open then
        core().notify(core().jump(id))
      end
    end
  end
  mappings['<LeftMouse>'] = function()
    mouse(false)
  end
  mappings['<2-LeftMouse>'] = function()
    mouse(true)
  end
  for key, action in pairs(mappings) do
    vim.keymap.set('n', key, action, { buffer = M.pane.trail_buf, silent = true })
  end
  vim.keymap.set({ 'n', 'i', 'v' }, '<C-c>', close_sidebar, {
    buffer = M.pane.trail_buf,
    silent = true,
    desc = 'TDLU close sidebar',
  })
  vim.keymap.set('x', 'x', function()
    M.selected_range('detach')
  end, { buffer = M.pane.trail_buf })
  vim.keymap.set('x', 'd', function()
    M.selected_range('remove')
  end, { buffer = M.pane.trail_buf })
  api.nvim_set_current_win(previous)
  M.retarget(core().current().selected)
  M.render()
end
function M.note(id)
  if M.notes_modified() then
    local saved = core().save()
    if not saved.ok then
      core().notify(saved)
      return
    end
  end
  -- Leave the pinned editor before an explicit target switch.
  if valid(M.pane.notes_win) and api.nvim_get_current_win() == M.pane.notes_win then
    local window = core().runtime.code_window
    if valid(window) then
      api.nvim_set_current_win(window)
    end
  end
  M.panel(true)
  if M.pane.narrow then
    M.pane.notes_win, M.pane.trail_win = M.pane.trail_win or M.pane.notes_win, nil
    api.nvim_win_set_buf(M.pane.notes_win, M.pane.notes_buf)
    vim.wo[M.pane.notes_win].wrap = true
    vim.wo[M.pane.notes_win].linebreak = true
  end
  -- Explicit note action is allowed to repin, after successfully committing.
  local inv = core().current()
  local owner = id == 'overview' and inv or inv.nodes[id]
  assert(owner, 'Unknown notes target')
  M.pane.target = { inv_id = inv.id, id = id }
  set_lines(M.pane.notes_buf, vim.split(owner.notes, '\n', { plain = true }))
  vim.wo[M.pane.notes_win].winbar = id == 'overview' and 'Trace notes · <leader>tn switch'
    or 'Step notes · ' .. node_title(owner):gsub('%%', '%%%%') .. ' · <leader>tn switch'
  vim.bo[M.pane.notes_buf].modifiable = not core().storage.readonly
  api.nvim_set_current_win(M.pane.notes_win)
end
function M.render()
  local inv = core().session and core().current()
  if not inv or not M.pane.trail_buf or not api.nvim_buf_is_valid(M.pane.trail_buf) then
    return
  end
  local rows, lines =
    M.rows(inv),
    { core().status(), 'Enter jump · t name · n notes · J/K move · x detach', '' }
  M.pane.row_ids = {}
  M.pane.card_spans, M.pane.card_ids, M.pane.card_row = nil, nil, nil
  if valid(M.pane.trail_win) then
    vim.wo[M.pane.trail_win].winbar = core().status()
  end
  for _, row in ipairs(rows) do
    lines[#lines + 1] = (inv.selected == row.id and '● ' or '  ') .. row.text
    M.pane.row_ids[#lines] = row.id
  end
  local selected = inv.selected
  if selected then
    local source = model.parent(inv, selected) or selected
    local siblings = model.children(inv, source)
    if #siblings > 1 then
      lines[#lines + 1] = ''
      lines[#lines + 1] = 'Destinations from ' .. node_title(inv.nodes[source])
      local cards, card_ids = {}, {}
      for _, child in ipairs(siblings) do
        cards[#cards + 1] = '['
          .. (child.destination == selected and '● ' or '')
          .. node_title(inv.nodes[child.destination])
          .. ']'
        card_ids[#card_ids + 1] = child.destination
      end
      local joined = table.concat(cards, '  ')
      local width = valid(M.pane.trail_win) and api.nvim_win_get_width(M.pane.trail_win)
        or core().config.width
      if vim.fn.strdisplaywidth(joined) <= width then
        lines[#lines + 1] = joined
        M.pane.row_ids[#lines] = selected
        M.pane.card_ids, M.pane.card_row = card_ids, #lines
        M.pane.card_spans = {}
        local column = 1
        for index, card in ipairs(cards) do
          local width = vim.fn.strdisplaywidth(card)
          M.pane.card_spans[index] =
            { first = column, last = column + width - 1, id = card_ids[index] }
          column = column + width + 2
        end
      else
        for index, card in ipairs(cards) do
          lines[#lines + 1] = card
          M.pane.row_ids[#lines] = card_ids[index]
        end
        M.pane.card_ids, M.pane.card_row = nil, nil
      end
    end
  end
  set_lines(M.pane.trail_buf, lines)
  style_rows(M.pane.trail_buf, lines, true)
  if valid(M.pane.trail_win) then
    local row = api.nvim_win_get_cursor(M.pane.trail_win)[1]
    if not M.pane.row_ids[row] and inv.selected then
      M.select_sidebar(M.pane.preview_id or inv.selected)
    end
    M.highlight_sidebar()
  end
end
function M.select_sidebar(id)
  if not valid(M.pane.trail_win) then
    return
  end
  for row = 1, api.nvim_buf_line_count(M.pane.trail_buf) do
    if M.pane.row_ids[row] == id then
      api.nvim_win_set_cursor(M.pane.trail_win, { row, 0 })
      M.pane.preview_id = id
      M.highlight_sidebar()
      return
    end
  end
end
function M.sibling(offset, jump)
  local inv = core().current()
  local id = M.selected() or inv.selected
  local source = model.parent(inv, id) or id
  local children = model.children(inv, source)
  local position = 0
  for index, child in ipairs(children) do
    if child.destination == id then
      position = index
    end
  end
  local destination = children[position + offset]
  if not destination then
    return
  end
  if jump then
    core().notify(core().jump(destination.destination))
  else
    M.select_sidebar(destination.destination)
  end
end
function M.reorder(offset)
  local inv = core().current()
  local id = M.selected()
  if not id then
    return
  end
  local position = model.index(inv.primary, id)
  if position then
    if position + offset < 1 or position + offset > #inv.primary then
      return
    end
    core().notify(core().move(position, position, offset > 0 and position + 2 or position - 1))
  else
    core().notify(core().reorder_sibling(id, offset))
  end
  M.select_sidebar(id)
end
function M.selected_range(action)
  local first, last = vim.fn.line('v'), vim.fn.line('.')
  if first > last then
    first, last = last, first
  end
  local ids = {}
  for row = first, last do
    if M.pane.row_ids[row] then
      ids[#ids + 1] = M.pane.row_ids[row]
    end
  end
  api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  if #ids == 0 then
    return
  end
  if action == 'remove' then
    core().notify(core().remove(ids))
    return
  end
  local inv = core().current()
  local start, finish = model.index(inv.primary, ids[1]), model.index(inv.primary, ids[#ids])
  if not start or not finish then
    vim.notify('Select a primary segment; its descendants transfer automatically')
    return
  end
  core().notify(core().detach(nil, start, finish))
end
function M.resize()
  if not valid(M.pane.trail_win) and not valid(M.pane.notes_win) then
    return
  end
  local narrow = vim.o.columns < core().config.narrow_columns
  if narrow ~= M.pane.narrow then
    local saved = core().save()
    if not saved.ok then
      return
    end
    M.close_panel()
    M.panel(true)
  end
end
local function floating(buf, config)
  config.style, config.border, config.relative = 'minimal', 'rounded', 'editor'
  local window = api.nvim_open_win(buf, false, config)
  vim.wo[window].wrap = true
  vim.wo[window].winhighlight = 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder'
  return window
end
function M.close_browser()
  local state = M.browser_state
  if not state then
    return
  end
  M.browser_state = nil
  if not M.closing and core().runtime.unsaved and not core().storage.readonly then
    core().notify(core().save())
  end
  if state.group then
    pcall(api.nvim_del_augroup_by_id, state.group)
  end
  for _, key in ipairs({ 'prompt_win', 'results_win', 'preview_win', 'notes_preview_win' }) do
    if valid(state[key]) then
      pcall(api.nvim_win_close, state[key], true)
    end
  end
  for _, key in ipairs({ 'prompt_buf', 'results_buf', 'preview_buf', 'notes_preview_buf' }) do
    if state[key] and api.nvim_buf_is_valid(state[key]) then
      pcall(api.nvim_buf_delete, state[key], { force = true })
    end
  end
end
local function investigation_rows(filter)
  local rows = {}
  for _, inv in pairs(core().workspace().investigations) do
    if
      filter == 'all'
      or (filter == 'archived' and inv.status == 'archived')
      or (filter == 'active' and inv.status == 'active')
    then
      local invalid = 0
      for _, node in pairs(inv.nodes) do
        if node.validity == 'invalid' then
          invalid = invalid + 1
        end
      end
      local text = string.format(
        '%s · %d nodes · %d invalid · %s · %s',
        single(inv.name),
        vim.tbl_count(inv.nodes),
        invalid,
        inv.visited_at and os.date('%Y-%m-%d %H:%M', inv.visited_at) or 'never visited',
        vim.fn.strcharpart(single(inv.notes), 0, 80)
      )
      rows[#rows + 1] = { inv_id = inv.id, text = text, search = text .. ' ' .. inv.id }
    end
  end
  table.sort(rows, function(left, right)
    return left.text < right.text
  end)
  return rows
end
function M.refresh_browser()
  local state = M.browser_state
  if not state or not core().session then
    return
  end
  local inv = state.inv_id and core().workspace().investigations[state.inv_id]
  if state.inv_id and not inv then
    state.inv_id, state.stack, state.is_subset = nil, {}, false
  end
  if state.is_subset and inv then
    state.rows = vim.tbl_filter(function(row)
      return inv.nodes[row.id] ~= nil
    end, state.rows)
  else
    state.rows = inv and M.rows(inv) or investigation_rows(state.filter)
  end
  M.browser_render()
end
function M.browser_preview()
  local state = M.browser_state
  if not state then
    return
  end
  highlight_selection(state.results_buf, #state.filtered > 0 and state.selected - 1 or nil, true)
  local row = state.filtered[state.selected]
  local lines, notes, filetype, preview_title =
    { 'No results' }, { '(no notes)' }, '', 'Code preview'
  if not row and state.inv_id then
    local inv = core().workspace().investigations[state.inv_id]
    if inv then
      notes = vim.split(inv.notes ~= '' and inv.notes or '(no trace notes)', '\n', { plain = true })
      lines = {
        'No matching locations.',
        '',
        next(inv.nodes) == nil and 'Tab, then d deletes this empty trace.'
          or 'Clear the search to see recorded locations.',
        'Backspace returns to traces.',
      }
    end
  end
  local cursor_row, syntax_source = 1, nil
  local spans, offset, source = nil, 0, nil
  if row then
    local inv = core().workspace().investigations[row.inv_id]
    local node = row.id and inv.nodes[row.id]
    local investigation_preview = not node
    notes = vim.split(inv.notes ~= '' and inv.notes or '(no trace notes)', '\n', { plain = true })
    node = node or inv.nodes[inv.selected or inv.primary[1]]
    if not node then
      lines = { 'No code locations recorded.', '', 'Enter to browse this trace.' }
    elseif node.kind == 'link' then
      lines = { 'Linked trace: ' .. node.target }
      if not investigation_preview then
        notes = vim.split(node.notes ~= '' and node.notes or '(no notes)', '\n', { plain = true })
      end
    else
      if not investigation_preview then
        notes = vim.split(node.notes ~= '' and node.notes or '(no notes)', '\n', { plain = true })
      end
      local inspected = model.copy(node)
      local buffer_id, candidate
      if row.candidate then
        candidate = row.candidate
        buffer_id = anchors.buffer(core().workspace().root, candidate)
      else
        buffer_id, candidate = anchors.resolve(core().workspace().root, inspected, true)
      end
      -- Validation may update evidence validity, but preview does not choose a route or selection.
      if
        not row.candidate
        and (node.validity ~= inspected.validity or node.reason ~= inspected.reason)
      then
        node.validity, node.reason = inspected.validity, inspected.reason
        if not core().storage.readonly then
          core().runtime.unsaved = true
        end
      end
      syntax_source = buffer_id
      local anchor = buffer_id and candidate or node.anchor
      local start = anchor.spans[1]
      local narrow = vim.o.columns < core().config.narrow_columns
      lines = {
        string.format(
          '%s:%d:%d · %s',
          anchor.path,
          start.start_row + 1,
          start.start_col + 1,
          inspected.validity
        ),
        buffer_id and 'Verified context · preview only'
          or ('Historical context · ' .. tostring(inspected.reason)),
      }
      local flattened = {}
      for _, line in ipairs(lines) do
        vim.list_extend(flattened, vim.split(line, '\n', { plain = true }))
      end
      if row.candidate then
        flattened[#flattened + 1] = 'Old captured context (historical):'
        for _, context in ipairs(node.original.context) do
          flattened[#flattened + 1] = context.text
        end
        vim.list_extend(flattened, { '', 'Proposed verified candidate:' })
      end
      preview_title = string.format(
        '%s · %s:%d:%d',
        buffer_id and 'Code' or 'Historical code',
        anchor.path,
        start.start_row + 1,
        start.start_col + 1
      )
      filetype = buffer_id and vim.bo[buffer_id].filetype or ''
      if filetype == '' then
        filetype = vim.filetype.match({ filename = anchor.path }) or ''
      end
      lines, offset = flattened, #flattened
      if buffer_id and not row.candidate then
        local margin = 40
        if valid(state.preview_win) then
          margin = math.max(20, api.nvim_win_get_height(state.preview_win))
        end
        local line_count = api.nvim_buf_line_count(buffer_id)
        local first = math.max(0, start.start_row - margin)
        local last = math.min(line_count, start.start_row + margin + 1)
        lines = api.nvim_buf_get_lines(buffer_id, first, last, false)
        spans, source, offset = anchor.spans, first, 0
        cursor_row = start.start_row - first + 1
      elseif buffer_id then
        local first = math.max(0, start.start_row - (narrow and 1 or 3))
        local last =
          math.min(api.nvim_buf_line_count(buffer_id), start.start_row + (narrow and 2 or 7))
        vim.list_extend(lines, api.nvim_buf_get_lines(buffer_id, first, last, false))
        spans, source = anchor.spans, first
      else
        for _, context in ipairs(anchor.context) do
          lines[#lines + 1] = context.text
        end
      end
    end
  end
  local flat = {}
  for _, line in ipairs(lines) do
    vim.list_extend(flat, vim.split(line, '\n', { plain = true }))
  end
  set_lines(state.preview_buf, flat)
  set_lines(state.notes_preview_buf, notes)
  local filetype_changed = vim.bo[state.preview_buf].filetype ~= filetype
  if filetype_changed then
    pcall(vim.treesitter.stop, state.preview_buf)
    vim.bo[state.preview_buf].filetype = filetype
    vim.bo[state.preview_buf].syntax = filetype
  end
  if
    source
    and syntax_source
    and vim.treesitter.highlighter.active[syntax_source]
    and not vim.treesitter.highlighter.active[state.preview_buf]
  then
    -- Preserve the source buffer's highlighter instead of changing its engine.
    pcall(vim.treesitter.start, state.preview_buf)
  end
  api.nvim_win_set_config(state.preview_win, { title = ' ' .. preview_title .. ' ' })
  api.nvim_win_set_cursor(state.preview_win, { math.min(cursor_row, #flat), 0 })
  api.nvim_win_call(state.preview_win, function()
    vim.cmd('normal! zz')
  end)
  api.nvim_buf_clear_namespace(state.preview_buf, core().runtime.highlight_ns, 0, -1)
  if spans then
    for _, span in ipairs(spans) do
      local start_row, end_row = offset + span.start_row - source, offset + span.end_row - source
      if start_row >= offset and start_row < #flat then
        if end_row < #flat then
          api.nvim_buf_set_extmark(
            state.preview_buf,
            core().runtime.highlight_ns,
            start_row,
            span.start_col,
            { end_row = end_row, end_col = span.end_col, hl_group = 'Visual', strict = false }
          )
        else
          api.nvim_buf_set_extmark(
            state.preview_buf,
            core().runtime.highlight_ns,
            start_row,
            span.start_col,
            { line_hl_group = 'Visual', strict = false }
          )
        end
      end
    end
  end
end
function M.browser_footer()
  local state = M.browser_state
  if not state or not valid(state.results_win) then
    return
  end
  local footer
  if state.mode == 'actions' then
    if state.inv_id and #state.rows == 0 then
      footer = 'NORMAL · d delete trace · BS back · / search'
    elseif
      state.inv_id
      or (state.filtered and state.filtered[state.selected] and state.filtered[state.selected].id)
    then
      footer = 'NORMAL · t name · d delete · r repair · i invalid · e export · / search'
      if api.nvim_win_get_width(state.results_win) < 60 then
        footer = 'NORMAL · t name · d del · r fix · i inv · e exp · / search'
      end
    else
      footer = 'NORMAL · Enter browse · d delete · e export · / search'
    end
  else
    footer = 'SEARCH · ↑/↓ select · Tab actions · Enter open · Ctrl-c close'
  end
  api.nvim_win_set_config(state.results_win, { footer = ' ' .. footer .. ' ' })
end
function M.browser_search()
  local state = M.browser_state
  if not state then
    return
  end
  state.mode = 'search'
  api.nvim_set_current_win(state.prompt_win)
  api.nvim_win_set_cursor(state.prompt_win, { 1, #state.query })
  M.browser_footer()
  vim.cmd('startinsert!')
end
function M.browser_actions()
  local state = M.browser_state
  if not state then
    return
  end
  vim.cmd('stopinsert')
  state.mode = 'actions'
  api.nvim_set_current_win(state.results_win)
  M.browser_footer()
end
function M.browser_render()
  local state = M.browser_state
  if not state then
    return
  end
  local query = api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ''
  state.query = query
  local previous = state.filtered and state.filtered[state.selected]
  state.filtered = query == '' and state.rows
    or vim.fn.matchfuzzy(state.rows, query, { key = 'search' })
  state.selected = math.min(math.max(1, state.selected), math.max(1, #state.filtered))
  if previous then
    for index, row in ipairs(state.filtered) do
      if row.id == previous.id and row.inv_id == previous.inv_id then
        state.selected = index
        break
      end
    end
  end
  local lines = {}
  for _, row in ipairs(state.filtered) do
    lines[#lines + 1] = '  ' .. row.text
  end
  if #lines == 0 then
    if state.inv_id and #state.rows == 0 then
      lines = {
        'No locations recorded.',
        'Tab → d: delete trace',
        'Tab → Backspace: traces',
      }
    else
      lines = { '(no results)' }
    end
  end
  set_lines(state.results_buf, lines)
  style_rows(state.results_buf, lines, false)
  api.nvim_win_set_cursor(state.results_win, { state.selected, 0 })
  api.nvim_win_set_config(state.results_win, {
    title = state.inv_id and (' Locations · ' .. single(
      core().workspace().investigations[state.inv_id].name
    )) or ' Traces ',
  })
  M.browser_footer()
  M.browser_preview()
end
function M.browser_select(offset)
  local state = M.browser_state
  if not state then
    return
  end
  state.selected = math.max(1, math.min(#state.filtered, state.selected + offset))
  api.nvim_win_set_cursor(state.results_win, { state.selected, 0 })
  M.browser_preview()
end
function M.browser_enter()
  local state = M.browser_state
  if not state then
    return
  end
  local row = state.filtered[state.selected]
  if not row then
    return
  end
  if row.candidate then
    local repaired = core().repair_investigation(row.inv_id, row.id, row.candidate)
    if repaired.ok then
      M.close_browser()
    else
      core().notify(repaired)
    end
  elseif not row.id then
    state.mode = 'actions'
    state.stack[#state.stack + 1] =
      { inv_id = state.inv_id, query = state.query, selected = state.selected, rows = state.rows }
    state.inv_id, state.rows, state.selected =
      row.inv_id, M.rows(core().workspace().investigations[row.inv_id]), 1
    api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { '' })
    M.browser_render()
    api.nvim_set_current_win(state.results_win)
  else
    local visited = core().visit(row.inv_id, row.id)
    if visited.ok then
      M.close_browser()
    else
      core().notify(visited)
      M.browser_preview()
    end
  end
end
function M.browser_back()
  local state = M.browser_state
  if not state then
    return
  end
  local parent = table.remove(state.stack)
  if not parent then
    return
  end
  state.inv_id, state.rows, state.selected = parent.inv_id, parent.rows, parent.selected
  api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { parent.query })
  state.filtered = nil
  M.browser_render()
end
local function browser_action(action)
  local state = M.browser_state
  local row = state and state.filtered[state.selected]
  if not row and state and state.inv_id and #state.rows == 0 and action == 'remove' then
    local inv = core().workspace().investigations[state.inv_id]
    if inv and next(inv.nodes) == nil then
      row = { inv_id = state.inv_id }
    end
  end
  if not row then
    return
  end
  if action == 'export' then
    core().notify(core().export(row.inv_id))
    return
  end
  if not row.id then
    if action == 'remove' then
      local inv = core().workspace().investigations[row.inv_id]
      vim.ui.select({ 'Cancel', 'Delete trace' }, {
        prompt = 'Delete "'
          .. inv.name
          .. '" and its '
          .. vim.tbl_count(inv.nodes)
          .. ' steps? Undo is available this session.',
      }, function(choice)
        if choice == 'Delete trace' then
          core().notify(core().delete_investigation(row.inv_id))
        end
      end)
    end
    return
  end
  if action == 'title' then
    core().notify(core().title(nil, row.id, row.inv_id))
  elseif action == 'repair' then
    M.repair(core().workspace().investigations[row.inv_id], row.id)
  elseif action == 'invalidate' then
    core().notify(core().invalidate_investigation(row.inv_id, row.id))
  elseif action == 'remove' then
    local removed = core().remove({ row.id }, row.inv_id)
    core().notify(removed)
    if not removed.ok then
      return
    end
    local inv = core().workspace().investigations[row.inv_id]
    if state.is_subset then
      state.rows = vim.tbl_filter(function(item)
        return inv.nodes[item.id] ~= nil
      end, state.rows)
    else
      state.rows = M.rows(inv)
    end
    for _, frame in ipairs(state.stack) do
      if frame.inv_id then
        local parent = core().workspace().investigations[frame.inv_id]
        frame.rows = vim.tbl_filter(function(item)
          return parent.nodes[item.id] ~= nil
        end, frame.rows)
      else
        frame.rows = investigation_rows(state.filter)
      end
    end
    M.browser_render()
  end
end
function M.validate_browser(state)
  local pending = {}
  for _, row in ipairs(state.rows) do
    local inv = core().workspace().investigations[row.inv_id]
    if row.id then
      pending[#pending + 1] = { inv_id = inv.id, id = row.id }
    else
      for id, node in pairs(inv.nodes) do
        if node.kind == 'location' then
          pending[#pending + 1] = { inv_id = inv.id, id = id }
        end
      end
    end
  end
  local position = 1
  local function batch()
    if M.browser_state ~= state or not core().session then
      return
    end
    local changed = false
    for _ = 1, 4 do
      local item = pending[position]
      position = position + 1
      if not item then
        break
      end
      local inv = core().workspace().investigations[item.inv_id]
      local node = inv and inv.nodes[item.id]
      if node and node.kind == 'location' then
        local inspected = model.copy(node)
        anchors.resolve(core().workspace().root, inspected, true)
        if node.validity ~= inspected.validity or node.reason ~= inspected.reason then
          node.validity, node.reason = inspected.validity, inspected.reason
          changed = true
          if not core().storage.readonly then
            core().runtime.unsaved = true
          end
        end
      end
    end
    if changed then
      if not state.inv_id then
        state.rows = investigation_rows(state.filter)
      elseif not state.is_subset then
        state.rows = M.rows(core().workspace().investigations[state.inv_id])
      end
      M.browser_render()
      M.render()
    end
    if position <= #pending then
      vim.defer_fn(batch, 25)
    end
  end
  vim.defer_fn(batch, 25)
end
function M.browser(filter, query, inv_id)
  assert(
    filter == 'active' or filter == 'archived' or filter == 'all',
    'Use list active, archived, or all'
  )
  M.close_browser()
  local columns, height = vim.o.columns, vim.o.lines
  local width, total_height = math.max(20, columns - 8), math.max(8, height - 8)
  local wide = columns >= core().config.narrow_columns
  local results_width = wide and math.floor(width * 0.48) or width
  local results_height = wide and total_height - 3
    or math.max(3, math.floor((total_height - 4) / 2))
  local state = {
    filter = filter,
    mode = 'search',
    stack = {},
    selected = 1,
    inv_id = inv_id,
    prompt_buf = buffer('search'),
    results_buf = buffer('results'),
    preview_buf = buffer('preview'),
    notes_preview_buf = buffer('notes-preview'),
  }
  state.rows = inv_id and M.rows(core().workspace().investigations[inv_id])
    or investigation_rows(filter)
  if inv_id then
    local rows = investigation_rows(filter)
    local selected = 1
    for index, row in ipairs(rows) do
      if row.inv_id == inv_id then
        selected = index
      end
    end
    state.stack = { { rows = rows, selected = selected, query = '' } }
  end
  M.browser_state = state
  state.prompt_win = floating(state.prompt_buf, {
    row = 2,
    col = 3,
    width = width,
    height = 1,
    title = ' Search · ↑/↓ or Ctrl-n/p select · Enter open · Esc/Ctrl-c close ',
  })
  state.results_win = floating(state.results_buf, {
    row = 5,
    col = 3,
    width = results_width,
    height = results_height,
    title = ' Traces ',
    footer = ' Enter open · BS back · r repair · i invalidate · e export ',
  })
  local preview_row = wide and 5 or (7 + results_height)
  local preview_col = wide and (5 + results_width) or 3
  local preview_width = wide and (width - results_width - 2) or width
  local preview_height = wide and results_height or math.max(4, total_height - results_height - 5)
  local code_height = math.max(1, math.floor((preview_height - 2) * 0.6))
  local notes_height = math.max(1, preview_height - code_height - 2)
  state.preview_win = floating(state.preview_buf, {
    row = preview_row,
    col = preview_col,
    width = preview_width,
    height = code_height,
    title = ' Code preview ',
  })
  state.notes_preview_win = floating(state.notes_preview_buf, {
    row = preview_row + code_height + 2,
    col = preview_col,
    width = preview_width,
    height = notes_height,
    title = ' Notes preview ',
  })
  vim.bo[state.notes_preview_buf].filetype = 'markdown'
  vim.bo[state.notes_preview_buf].syntax = 'markdown'
  vim.wo[state.notes_preview_win].linebreak = true
  vim.bo[state.prompt_buf].modifiable = true
  api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { query or '' })
  state.group = api.nvim_create_augroup('TDLUBrowser', { clear = true })
  api.nvim_create_autocmd('WinClosed', {
    group = state.group,
    callback = function(event)
      local window = tonumber(event.match)
      if
        M.browser_state == state
        and (
          window == state.results_win
          or window == state.prompt_win
          or window == state.preview_win
          or window == state.notes_preview_win
        )
      then
        M.close_browser()
      end
    end,
  })
  api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI' },
    { group = state.group, buffer = state.prompt_buf, callback = M.browser_render }
  )
  api.nvim_create_autocmd('CursorMoved', {
    group = state.group,
    buffer = state.results_buf,
    callback = function()
      if M.browser_state == state then
        state.selected = api.nvim_win_get_cursor(state.results_win)[1]
        M.browser_preview()
      end
    end,
  })
  local function mouse(open)
    local position = vim.fn.getmousepos()
    if position.winid == state.results_win then
      state.selected = math.max(1, math.min(#state.filtered, position.line))
      api.nvim_win_set_cursor(state.results_win, { state.selected, 0 })
      M.browser_preview()
      if open then
        M.browser_enter()
      end
    end
  end
  for _, buf in ipairs({
    state.prompt_buf,
    state.results_buf,
    state.preview_buf,
    state.notes_preview_buf,
  }) do
    for _, mode in ipairs({ 'n', 'i' }) do
      for key, offset in pairs({ ['<C-n>'] = 1, ['<Down>'] = 1, ['<C-p>'] = -1, ['<Up>'] = -1 }) do
        vim.keymap.set(mode, key, function()
          M.browser_select(offset)
        end, { buffer = buf })
      end
      vim.keymap.set(mode, '<CR>', function()
        vim.cmd('stopinsert')
        M.browser_enter()
      end, { buffer = buf })
      vim.keymap.set(mode, '<Esc>', function()
        vim.cmd('stopinsert')
        M.close_browser()
      end, { buffer = buf })
      vim.keymap.set(mode, '<Tab>', M.browser_actions, { buffer = buf })
    end
    vim.keymap.set({ 'n', 'i', 'v' }, '<C-c>', function()
      vim.cmd('stopinsert')
      M.close_browser()
    end, { buffer = buf, desc = 'TDLU close browser' })
    vim.keymap.set('n', '/', M.browser_search, { buffer = buf, desc = 'TDLU return to search' })
    vim.keymap.set('n', '<BS>', M.browser_back, { buffer = buf })
  end
  for key, action in pairs({
    d = 'remove',
    t = 'title',
    r = 'repair',
    i = 'invalidate',
    e = 'export',
  }) do
    -- Only result buffers get action letters. Prompt letters remain search text.
    vim.keymap.set('n', key, function()
      browser_action(action)
    end, { buffer = state.results_buf })
  end
  vim.keymap.set('n', '<LeftMouse>', function()
    mouse(false)
  end, { buffer = state.results_buf })
  vim.keymap.set('n', '<2-LeftMouse>', function()
    mouse(true)
  end, { buffer = state.results_buf })
  M.browser_render()
  M.validate_browser(state)
  api.nvim_set_current_win(state.prompt_win)
  vim.cmd('startinsert!')
end
function M.browser_locations(inv_id)
  M.browser('all', nil, inv_id)
end
function M.choose_node(prompt, callback)
  local rows = M.rows(core().current())
  vim.ui.select(rows, {
    prompt = prompt,
    format_item = function(row)
      return row.text
    end,
  }, function(row)
    if row then
      callback(row.id)
    end
  end)
end
function M.choose_child(id, callback)
  local inv = core().current()
  local rows = model.children(inv, id)
  vim.ui.select(rows, {
    prompt = 'Destination from ' .. id,
    format_item = function(row)
      return label(inv, inv.nodes[row.destination])
    end,
  }, function(row)
    if row then
      callback(row.destination)
    end
  end)
end
function M.branches(id)
  local inv = core().current()
  assert(inv.nodes[id], 'Select a source first')
  M.browser('all', nil, inv.id)
  local state = M.browser_state
  state.stack[#state.stack + 1] = { inv_id = inv.id, rows = state.rows, selected = 1, query = '' }
  state.rows = {}
  state.is_subset = true
  for _, child in ipairs(model.children(inv, id)) do
    local text = label(inv, inv.nodes[child.destination])
    state.rows[#state.rows + 1] = {
      id = child.destination,
      inv_id = inv.id,
      text = text,
      search = text,
      ancestry = inv.name .. ' / ' .. (inv.nodes[id].title ~= '' and inv.nodes[id].title or id),
    }
  end
  state.filtered = nil
  state.selected = 1
  M.browser_render()
end
function M.confirm(prompt, callback)
  vim.ui.select({ 'Cancel', 'Confirm' }, { prompt = prompt }, function(choice)
    if choice == 'Confirm' then
      callback()
    end
  end)
end
function M.confirm_detach(inv, transfer, callback)
  local lines = { 'Transfer these nodes and their side branches:', '' }
  for _, row in ipairs(M.rows(inv)) do
    if transfer[row.id] then
      lines[#lines + 1] = row.text .. ' [' .. row.id .. ']'
    end
  end
  M.message('Detachment preview', lines)
  M.confirm(
    'Transfer ' .. vim.tbl_count(transfer) .. ' nodes and replace primary segment with one link?',
    callback
  )
end
function M.repair(inv, id)
  local node = assert(inv.nodes[id], 'Unknown entry')
  assert(node.kind == 'location', 'Links have no code anchor')
  M.message(
    'Historical capture · ' .. id,
    vim.list_extend(
      {
        'Reason: ' .. (node.reason or 'repair requested'),
        'Developer notes:',
        node.notes,
        '',
        'Captured context:',
      },
      vim.tbl_map(function(item)
        return item.text
      end, node.original.context)
    )
  )
  local ok, source = pcall(anchors.buffer, core().workspace().root, node.anchor)
  if not ok then
    vim.notify('File missing. Open the replacement code and run :TDLU reattach for this node.')
    return
  end
  local candidates = anchors.candidates(api.nvim_buf_get_lines(source, 0, -1, false), node.anchor)
  if #candidates == 0 then
    vim.notify('No verified candidates. Open the replacement code and run :TDLU reattach.')
    return
  end
  M.browser('all', nil, inv.id)
  local state = M.browser_state
  state.rows = {}
  state.is_subset = true
  for index, candidate in ipairs(candidates) do
    local span = candidate.spans[1]
    local text = string.format(
      'Candidate %d · %s:%d:%d',
      index,
      candidate.path,
      span.start_row + 1,
      span.start_col + 1
    )
    state.rows[#state.rows + 1] = {
      id = id,
      inv_id = inv.id,
      candidate = candidate,
      text = text,
      search = text,
      ancestry = 'repair preview',
    }
  end
  state.filtered = nil
  state.selected = 1
  M.browser_render()
end
function M.message(title, lines)
  local buf = buffer('message')
  local flat = {}
  for _, line in ipairs(lines) do
    vim.list_extend(flat, vim.split(line, '\n', { plain = true }))
  end
  set_lines(buf, flat)
  local window = floating(buf, {
    row = 3,
    col = 4,
    width = math.max(20, math.min(90, vim.o.columns - 10)),
    height = math.max(3, math.min(#flat + 1, vim.o.lines - 10)),
    title = ' ' .. title .. ' ',
  })
  vim.bo[buf].bufhidden = 'wipe'
  vim.keymap.set('n', 'q', function()
    if valid(window) then
      api.nvim_win_close(window, true)
    end
  end, { buffer = buf })
  for _, key in ipairs({ '<Esc>', '<C-c>' }) do
    vim.keymap.set({ 'n', 'i', 'v' }, key, function()
      vim.cmd('stopinsert')
      if valid(window) then
        api.nvim_win_close(window, true)
      end
    end, { buffer = buf })
  end
  api.nvim_set_current_win(window)
end
function M.export_actions(path)
  vim.ui.select(
    { 'Done', 'Copy path', 'Copy handoff' },
    { prompt = 'Export completed: ' .. path },
    function(choice)
      if choice == 'Copy path' then
        vim.fn.setreg('+', path)
      elseif choice == 'Copy handoff' then
        vim.fn.setreg('+', require('tdlu.storage').read(path .. '/investigation.md'))
      end
    end
  )
end
function M.pane_view()
  if not M.pane.narrow then
    M.note(core().current().selected or 'overview')
    return
  end
  if valid(M.pane.notes_win) then
    if M.notes_modified() then
      local saved = core().save()
      if not saved.ok then
        core().notify(saved)
        return
      end
    end
    M.pane.trail_win, M.pane.notes_win = M.pane.notes_win, nil
    api.nvim_win_set_buf(M.pane.trail_win, M.pane.trail_buf)
    M.render()
  else
    M.note(core().current().selected or 'overview')
  end
end
function M.close()
  M.closing = true
  M.close_browser()
  M.close_panel()
  for _, buf in ipairs({ M.pane.trail_buf or false, M.pane.notes_buf or false }) do
    if buf and api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  pcall(api.nvim_del_augroup_by_name, 'TDLUNotes')
  pcall(api.nvim_del_augroup_by_name, 'TDLUTrail')
  pcall(api.nvim_del_augroup_by_name, 'TDLUPanels')
  M.pane = {}
  M.closing = false
end
return M
