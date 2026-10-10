local model = require('tdlu.model')
model.id_source = function()
  local entropy = assert(vim.uv.random(16))
  return (entropy:gsub('.', function(byte)
    return string.format('%02x', byte:byte())
  end))
end
local storage = require('tdlu.storage')
local anchors = require('tdlu.anchors')
local navigation = require('tdlu.navigation')
local M = {}
local defaults = {
  width = 48,
  side = 'right',
  narrow_columns = 110,
  notes_debounce_ms = 500,
  follow_colorscheme = true,
}
M.config = model.copy(defaults)
M.runtime = { frames = {}, highlight_ns = vim.api.nvim_create_namespace('tdlu-selection') }
local function ui()
  return require('tdlu.ui')
end
local function ensure()
  if not M.session then
    local root = storage.root(vim.api.nvim_buf_get_name(0))
    local workspace, state = storage.load(root, M.config.data_dir)
    M.session, M.storage = model.session(workspace), state
    if state.corrupt then
      vim.notify(
        'TDLU: corrupt JSON preserved. :TDLU recover restores the prior valid snapshot.',
        vim.log.levels.ERROR
      )
    elseif state.readonly then
      vim.notify('TDLU: newer schema, opened read-only', vim.log.levels.WARN)
    end
    local drafts = storage.drafts(state)
    if #drafts > 0 then
      vim.notify('TDLU: recoverable drafts found. Use :TDLU recover-draft.', vim.log.levels.WARN)
    end
  end
  return M.session.workspace
end
function M.workspace()
  return ensure()
end
function M.current()
  local workspace = ensure()
  return workspace.investigations[M.runtime.active]
end
local function active()
  return assert(M.current(), 'Create or open a trace first')
end
local function writable()
  ensure()
  assert(
    not M.storage.readonly,
    'Workspace is read-only; recover corrupt state or use a supported schema'
  )
end
local function result(action)
  local ok, value = pcall(action)
  if not ok then
    return { ok = false, error = tostring(value) }
  end
  return { ok = true, value = value }
end
function M.changed()
  ui().render()
  ui().refresh_browser()
  vim.api.nvim_exec_autocmds('User', { pattern = 'TDLUChanged', modeline = false })
end
---@return TDLUResult
function M.save()
  return result(function()
    writable()
    ui().store_notes()
    anchors.sync(ensure())
    local ok, err = pcall(storage.save, ensure(), M.storage)
    if not ok then
      M.runtime.unsaved = true
      local drafted, draft_error = pcall(storage.draft, ensure(), M.storage)
      M.changed()
      error(
        tostring(err)
          .. (drafted and '' or ('; draft write also failed: ' .. tostring(draft_error)))
      )
    end
    M.runtime.unsaved = false
    ui().notes_saved()
    M.changed()
  end)
end
local function persist()
  if M.storage and M.storage.readonly then
    M.changed()
    return { ok = true, readonly = true }
  end
  M.runtime.unsaved = true
  local saved = M.save()
  if not saved.ok then
    vim.notify('TDLU: ' .. saved.error, vim.log.levels.ERROR)
  end
  M.changed()
  return saved
end
local function mutate(operation)
  return result(function()
    writable()
    ui().store_notes()
    if ui().notes_modified() then
      local saved = M.save()
      assert(saved.ok, saved.error)
    end
    anchors.sync(ensure())
    local changed = model.transaction(M.session, operation)
    assert(changed.ok, changed.error)
    anchors.prune(ensure())
    ui().reconcile()
    local saved = persist()
    return { result = changed.value, saved = saved.ok, save_error = saved.error }
  end)
end
local function find(name)
  local matches = {}
  for _, inv in pairs(ensure().investigations) do
    if inv.name == name or inv.id == name then
      matches[#matches + 1] = inv
    end
  end
  assert(#matches > 0, 'No trace named ' .. tostring(name))
  if #matches > 1 then
    ui().browser('all', name)
    error('Duplicate names: choose the trace in the browser')
  end
  return matches[1]
end
---@param name? string
---@return TDLUResult
function M.new(name)
  if not name or name == '' then
    vim.ui.input({ prompt = 'Trace name: ' }, function(value)
      if value and value ~= '' then
        M.notify(M.new(value))
      end
    end)
    return { ok = true }
  end
  local created
  local changed = mutate(function(workspace)
    local inv = model.investigation(name)
    workspace.investigations[inv.id] = inv
    created = inv.id
    return inv.id
  end)
  if changed.ok then
    M.runtime.active, M.runtime.last_jump, M.runtime.pinned_source = created, nil, nil
    ui().panel(true)
    ui().retarget('overview')
    M.changed()
  end
  return changed
end
---@param name? string Stable ID or investigation name
---@return TDLUResult
function M.open(name)
  return result(function()
    local inv = name and name ~= '' and find(name) or active()
    ui().store_notes()
    if M.runtime.unsaved then
      local saved = M.save()
      assert(saved.ok, saved.error)
    end
    local route, selected = model.copy(inv.route), inv.selected
    local candidate = selected or inv.primary[1] or inv.roots[1]
    local success = false
    if candidate and inv.nodes[candidate].kind == 'location' then
      success = pcall(navigation.jump, ensure(), inv, candidate, M.runtime)
    end
    if not success then
      local prefix = {}
      for _, id in ipairs(route) do
        local node = inv.nodes[id]
        if node.kind ~= 'location' or not anchors.resolve(ensure().root, node) then
          break
        end
        prefix[#prefix + 1] = id
      end
      if #prefix > 0 then
        navigation.jump(ensure(), inv, prefix[#prefix], M.runtime)
        success = true
      end
    end
    if #route > 0 then
      inv.route = route
    end
    if not success then
      inv.selected = selected
      M.runtime.last_jump = nil
    end
    M.runtime.active = inv.id
    M.runtime.pinned_source = inv.selected and { investigation = inv.id, id = inv.selected } or nil
    ui().panel(true)
    ui().retarget(nil)
    persist()
  end)
end
---@param opts? TDLUCaptureOptions|string
---@return TDLUResult
function M.add(opts)
  opts = type(opts) == 'string' and { title = opts } or opts or {}
  return result(function()
    writable()
    local inv = active()
    local captured, buffer = anchors.capture(ensure().root, opts)
    local source
    if opts.branch then
      local pin = M.runtime.pinned_source
      assert(
        pin and pin.investigation == inv.id and inv.nodes[pin.id],
        'Pin a source with :TDLU pin before following code'
      )
      source = pin.id
    end
    local code_window = vim.api.nvim_get_current_win()
    local function commit()
      return result(function()
        assert(M.current() and M.current().id == inv.id, 'Return to the captured trace first')
        local changed = mutate(function(workspace)
          model.add(
            workspace.investigations[inv.id],
            captured,
            opts.insert and inv.selected or nil,
            source,
            opts.label
          )
        end)
        assert(changed.ok, changed.error)
        local node = ensure().investigations[inv.id].nodes[captured.id]
        anchors.track(node, buffer)
        M.runtime.code_window = code_window
        local point = node.anchor.spans[1]
        M.runtime.last_jump =
          { id = node.id, buffer = buffer, row = point.start_row + 1, column = point.start_col }
        if not opts.branch then
          M.runtime.pinned_source = { investigation = inv.id, id = node.id }
        end
        ui().retarget(node.id)
        M.changed()
        return node.id
      end)
    end
    if opts.prompt_title and (not opts.title or opts.title == '') then
      vim.ui.input({ prompt = 'Node name (blank keeps code label): ' }, function(value)
        if value ~= nil then
          captured.title = vim.trim(value)
          M.notify(commit())
        end
      end)
      return nil
    end
    local committed = commit()
    assert(committed.ok, committed.error)
    return committed.value
  end)
end
function M.insert(opts)
  opts = opts or {}
  opts.insert = true
  return M.add(opts)
end
function M.branch(label, opts)
  opts = opts or {}
  opts.branch, opts.label, opts.title = true, label or '', label or ''
  return M.add(opts)
end
function M.pin()
  return result(function()
    local inv = active()
    assert(inv.selected, 'Select a source first')
    M.runtime.pinned_source = { investigation = inv.id, id = inv.selected }
    return inv.selected
  end)
end
---@param value? string|integer Node ID or one-based route position
---@return TDLUResult
function M.jump(value)
  return result(function()
    local inv = active()
    local id = type(value) == 'number' and inv.route[value] or value or inv.selected
    local node = assert(inv.nodes[id], 'Choose an existing entry')
    ui().store_notes()
    if node.kind == 'link' then
      assert(node.target ~= inv.id and #M.runtime.frames < 32, 'Trace link recursion blocked')
      for _, frame in ipairs(M.runtime.frames) do
        assert(frame.investigation ~= node.target, 'Trace link cycle blocked')
      end
      local target = assert(ensure().investigations[node.target], 'Linked trace missing')
      local opened = M.open(target.id)
      assert(opened.ok, opened.error)
      M.runtime.frames[#M.runtime.frames + 1] = {
        investigation = inv.id,
        entry = id,
        neighbors = model.copy(inv.primary),
        position = model.index(inv.primary, id),
        before = inv.primary[(model.index(inv.primary, id) or 1) - 1],
        after = inv.primary[(model.index(inv.primary, id) or 0) + 1],
      }
    else
      local ok, err = pcall(navigation.jump, ensure(), inv, id, M.runtime)
      if not ok then
        persist()
        error(err)
      end
      ui().retarget(id)
      persist()
    end
    return id
  end)
end
---@return TDLUResult
function M.previous()
  return result(function()
    local inv = active()
    local position = assert(model.index(inv.route, inv.selected), 'No active route position')
    assert(position > 1, 'Already at the first entry')
    local jumped = M.jump(inv.route[position - 1])
    assert(jumped.ok, jumped.error)
  end)
end
---@return TDLUResult
function M.next()
  return result(function()
    local inv = active()
    local position = assert(model.index(inv.route, inv.selected), 'No active route position')
    local id = inv.route[position + 1]
    if not id then
      local children = model.children(inv, inv.selected)
      if #children > 1 then
        ui().branches(inv.selected)
        return
      end
      id = children[1] and children[1].destination
    end
    assert(id, 'Already at the last entry')
    local jumped = M.jump(id)
    assert(jumped.ok, jumped.error)
  end)
end
function M.back()
  return result(function()
    local frame = M.runtime.frames[#M.runtime.frames]
    assert(frame, 'No trace return frame')
    local inv = assert(ensure().investigations[frame.investigation], 'Source trace was removed')
    local opened = M.open(inv.id)
    assert(opened.ok, opened.error)
    local destination = inv.nodes[frame.entry] and frame.entry
    if not destination and frame.position then
      for distance = 1, #frame.neighbors do
        local before, after =
          frame.neighbors[frame.position - distance], frame.neighbors[frame.position + distance]
        destination = (before and inv.nodes[before] and before)
          or (after and inv.nodes[after] and after)
        if destination then
          break
        end
      end
    end
    inv.selected = destination or inv.primary[1] or inv.roots[1]
    if inv.selected then
      if inv.nodes[inv.selected].kind == 'location' then
        M.notify(M.jump(inv.selected))
      else
        model.select(inv, inv.selected)
      end
    end
    table.remove(M.runtime.frames)
    ui().retarget(inv.selected)
    persist()
  end)
end
---@param first integer
---@param last integer
---@param insertion integer
---@return TDLUResult
function M.move(first, last, insertion)
  local inv = M.current()
  if not inv then
    return { ok = false, error = 'Open a trace first' }
  end
  return mutate(function(workspace)
    model.move(workspace.investigations[inv.id], first, last, insertion)
  end)
end
function M.remove(ids, investigation_id)
  local inv
  if investigation_id then
    inv = ensure().investigations[investigation_id]
  else
    inv = M.current()
  end
  if not inv then
    return { ok = false, error = 'Open a trace first' }
  end
  ids = ids or { ui().selected() or inv.selected }
  return mutate(function(workspace)
    model.remove(workspace.investigations[inv.id], ids)
  end)
end
---@param investigation_id string
---@return TDLUResult
function M.delete_investigation(investigation_id)
  local deleted = mutate(function(workspace)
    assert(workspace.investigations[investigation_id], 'Trace no longer exists')
    workspace.investigations[investigation_id] = nil
  end)
  if deleted.ok and not M.current() then
    ui().close_panel()
  end
  return deleted
end
---@param name? string
---@param first? integer
---@param last? integer
---@param confirmed? boolean Skip interactive preview when caller has already obtained confirmation
---@return TDLUResult
function M.detach(name, first, last, confirmed)
  return result(function()
    local inv = active()
    first = first or model.index(inv.primary, ui().selected() or inv.selected)
    last = last or first
    assert(first, 'Detach a contiguous primary segment')
    local transfer = model.detach_plan(inv, first, last)
    if not name or name == '' then
      vim.ui.input({ prompt = 'Detached trace name: ' }, function(value)
        if value and value ~= '' then
          M.notify(M.detach(value, first, last))
        end
      end)
      return
    end
    if not confirmed then
      ui().confirm_detach(inv, transfer, function()
        M.notify(M.detach(name, first, last, true))
      end)
      return
    end
    local changed = mutate(function(workspace)
      local target = model.detach(workspace, workspace.investigations[inv.id], first, last, name)
      return target.id
    end)
    assert(changed.ok, changed.error)
    ui().retarget(active().selected)
    return changed.value
  end)
end
function M.invalidate(reason, id)
  local inv = M.current()
  if not inv then
    return { ok = false, error = 'Open a trace first' }
  end
  id = id or ui().selected() or inv.selected
  return mutate(function(workspace)
    local node = assert(workspace.investigations[inv.id].nodes[id], 'Unknown entry')
    assert(node.kind == 'location', 'Links cannot be invalidated as code')
    node.validity, node.manual_invalid, node.reason =
      'invalid', true, reason or 'manual invalidation'
  end)
end
---@param opts? TDLUCaptureOptions
---@param id? string
---@return TDLUResult
function M.reattach(opts, id)
  return result(function()
    local inv = active()
    id = id
      or (M.runtime.repair_target and M.runtime.repair_target.investigation == inv.id and M.runtime.repair_target.id)
      or ui().selected()
      or inv.selected
    local captured, buffer = anchors.capture(ensure().root, opts)
    local changed = mutate(function(workspace)
      local node = assert(workspace.investigations[inv.id].nodes[id], 'Unknown entry')
      assert(node.kind == 'location', 'Only location entries can be reattached')
      anchors.reattach(node, captured, buffer)
    end)
    assert(changed.ok, changed.error)
    anchors.track(active().nodes[id], buffer)
  end)
end
function M.repair(id)
  return result(function()
    local inv = active()
    id = id or ui().selected() or inv.selected
    M.runtime.repair_target = { investigation = inv.id, id = id }
    ui().repair(inv, id)
  end)
end
function M.accept_repair(id, candidate)
  local inv = M.current()
  return mutate(function(workspace)
    local node = workspace.investigations[inv.id].nodes[id]
    local buffer = anchors.buffer(workspace.root, candidate)
    assert(
      anchors.matches(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), candidate),
      'Candidate changed; repair not applied'
    )
    node.repairs[#node.repairs + 1] = {
      at = os.time(),
      kind = 'accepted candidate',
      from = model.copy(node.anchor),
      to = model.copy(candidate),
    }
    node.anchor, node.manual_invalid, node.reason, node.validity =
      candidate, nil, nil, vim.bo[buffer].modified and 'provisional' or 'valid'
  end)
end
function M.bypass(id, successor, confirmed)
  return result(function()
    local inv = active()
    id = id or ui().selected() or inv.selected
    if not successor then
      ui().choose_child(id, function(child)
        M.notify(M.bypass(id, child))
      end)
      return
    end
    if not confirmed then
      local preview = model.copy(inv)
      model.bypass(preview, id, successor)
      local candidate = model.copy(ensure())
      candidate.investigations[inv.id] = preview
      model.validate(candidate)
      local lines = {
        'Primary before: ' .. table.concat(inv.primary, ' → '),
        'Primary after: ' .. table.concat(preview.primary, ' → '),
        '',
        'Branch connections after:',
      }
      for _, edge in ipairs(preview.edges) do
        lines[#lines + 1] = edge.source .. ' → ' .. edge.destination
      end
      lines[#lines + 1] = 'Retain invalid node as orphan: ' .. id
      ui().message('Bypass connection preview', lines)
      ui().confirm(
        'Bypass '
          .. id
          .. ' → '
          .. successor
          .. '; retain invalid node and other branches as orphan?',
        function()
          M.notify(M.bypass(id, successor, true))
        end
      )
      return
    end
    local changed = mutate(function(workspace)
      model.bypass(workspace.investigations[inv.id], id, successor)
    end)
    assert(changed.ok, changed.error)
  end)
end
function M.reparent(id, source, confirmed)
  return result(function()
    local inv = active()
    id = id or ui().selected() or inv.selected
    if not source then
      ui().choose_node('New branch source', function(chosen)
        M.notify(M.reparent(id, chosen))
      end)
      return
    end
    if not confirmed then
      ui().confirm(
        'Move incoming connection for '
          .. id
          .. ' from '
          .. (model.parent(inv, id) or 'orphan root')
          .. ' to '
          .. source
          .. '?',
        function()
          M.notify(M.reparent(id, source, true))
        end
      )
      return
    end
    local changed = mutate(function(workspace)
      model.reparent(workspace.investigations[inv.id], id, source)
    end)
    assert(changed.ok, changed.error)
  end)
end
function M.visit(inv_id, id)
  return result(function()
    local inv = assert(ensure().investigations[inv_id], 'Unknown trace')
    local node = assert(inv.nodes[id], 'Unknown node')
    if node.kind == 'location' then
      local buffer, reason = anchors.resolve(ensure().root, node)
      assert(buffer, reason)
    end
    local previous = M.runtime.active
    M.runtime.active = inv_id
    local visited = M.jump(id)
    if not visited.ok then
      M.runtime.active = previous
      error(visited.error)
    end
    ui().panel(true)
    M.changed()
  end)
end
function M.invalidate_investigation(inv_id, id, reason)
  return mutate(function(workspace)
    local node = assert(workspace.investigations[inv_id].nodes[id], 'Unknown entry')
    assert(node.kind == 'location', 'Links cannot be invalidated as code')
    node.validity, node.manual_invalid, node.reason =
      'invalid', true, reason or 'manual invalidation'
  end)
end
function M.repair_investigation(inv_id, id, candidate)
  local previous = M.runtime.active
  M.runtime.active = inv_id
  local repaired = M.accept_repair(id, candidate)
  M.runtime.active = previous
  return repaired
end
function M.reorder_sibling(id, offset)
  return mutate(function(workspace)
    local inv = workspace.investigations[assert(M.runtime.active, 'Open a trace')]
    local source, kind, edge = model.parent(inv, id)
    assert(kind == 'branch', 'Select a side branch')
    local children = {}
    for _, child in ipairs(model.children(inv, source)) do
      if child.kind == 'branch' then
        children[#children + 1] = child.edge
      end
    end
    local position
    for index, candidate in ipairs(children) do
      if candidate.id == edge.id then
        position = index
      end
    end
    local adjacent = children[position + offset]
    assert(adjacent, 'Already at the sibling boundary')
    edge.order, adjacent.order = adjacent.order, edge.order
  end)
end
---@param name? string Blank clears the explicit name
---@param id? string
---@param investigation_id? string
---@return TDLUResult
function M.title(name, id, investigation_id)
  local inv = investigation_id and ensure().investigations[investigation_id] or M.current()
  local node = inv and inv.nodes[id or inv.selected]
  if not node or node.kind ~= 'location' then
    return { ok = false, error = 'Select a code location first' }
  end
  if name == nil then
    vim.ui.input(
      { prompt = 'Node name (blank keeps code label): ', default = node.title or '' },
      function(value)
        if value ~= nil then
          M.notify(M.title(value, node.id, inv.id))
        end
      end
    )
    return { ok = true }
  end
  return mutate(function(workspace)
    local target = assert(workspace.investigations[inv.id].nodes[node.id], 'Location was removed')
    target.title, target.updated_at = vim.trim(name), os.time()
  end)
end
function M.rename(name)
  if not name or name == '' then
    vim.ui.input({ prompt = 'New name: ' }, function(value)
      if value and value ~= '' then
        M.notify(M.rename(value))
      end
    end)
    return { ok = true }
  end
  local inv = M.current()
  if not inv then
    return { ok = false, error = 'Open a trace first' }
  end
  return mutate(function(workspace)
    workspace.investigations[inv.id].name = name
  end)
end
function M.archive()
  local inv = M.current()
  if not inv then
    return { ok = false, error = 'Open a trace first' }
  end
  return mutate(function(workspace)
    local target = workspace.investigations[inv.id]
    target.status = target.status == 'archived' and 'active' or 'archived'
  end)
end
local function history(direction)
  return result(function()
    writable()
    ui().store_notes()
    if ui().notes_modified() then
      local saved = M.save()
      assert(saved.ok, saved.error)
    end
    local restored = model.history(M.session, direction)
    assert(restored.ok, restored.error)
    anchors.reset()
    ui().reconcile()
    if not M.current() then
      ui().close_panel()
    end
    ui().retarget(M.current() and M.current().selected)
    persist()
  end)
end
function M.undo()
  return history('undo')
end
function M.redo()
  return history('redo')
end
function M.list(filter)
  return result(function()
    ensure()
    ui().browser(filter or 'active')
  end)
end
function M.locations(name)
  return result(function()
    local inv = name and name ~= '' and find(name) or active()
    ui().browser_locations(inv.id)
  end)
end
function M.branches()
  return result(function()
    local inv = active()
    ui().branches(inv.selected)
  end)
end
function M.panel()
  return result(function()
    active()
    ui().panel()
  end)
end
function M.note()
  return result(function()
    local inv = active()
    assert(inv.selected, 'No selected entry')
    ui().note(inv.selected)
  end)
end
function M.overview()
  return result(function()
    active()
    ui().note('overview')
  end)
end
---@param name? string
---@param opts? TDLUExportOptions
---@return TDLUResult
function M.export(name, opts)
  return result(function()
    opts = opts or {}
    ui().store_notes()
    local inv = name and name ~= '' and find(name) or active()
    local path = require('tdlu.export').write(
      ensure(),
      inv.id,
      opts.directory or (M.storage.directory .. '/exports'),
      opts
    )
    vim.notify('TDLU export: ' .. path)
    ui().export_actions(path)
    return path
  end)
end
function M.export_copy(name, opts)
  return result(function()
    ui().store_notes()
    local inv = name and name ~= '' and find(name) or active()
    local exporter = require('tdlu.export')
    local content =
      exporter.markdown(exporter.snapshot(ensure(), inv.id, opts or { metadata_only = true }))
    vim.fn.setreg('+', content)
    return content
  end)
end
function M.reload()
  return result(function()
    ui().store_notes()
    assert(
      (not M.runtime.unsaved and not ui().notes_modified())
        or M.runtime.copy_saved == vim.fn.sha256(vim.json.encode(ensure())),
      'Unsaved changes: use save-copy first, or recover-draft after restarting'
    )
    local root = ensure().root
    anchors.reset()
    ui().close_panel()
    M.session, M.storage = nil, nil
    M.runtime.active, M.runtime.last_jump, M.runtime.unsaved, M.runtime.copy_saved =
      nil, nil, false, nil
    local workspace, state = storage.load(root, M.config.data_dir)
    M.session, M.storage = model.session(workspace), state
    M.changed()
  end)
end
function M.save_copy()
  return result(function()
    ui().store_notes()
    local path = storage.save_copy(ensure(), M.storage)
    M.runtime.copy_saved = vim.fn.sha256(vim.json.encode(ensure()))
    vim.notify('Recovery copy: ' .. path)
    return path
  end)
end
function M.recover()
  return result(function()
    ensure()
    storage.recover(M.storage)
    M.runtime.unsaved = false
    local reloaded = M.reload()
    assert(reloaded.ok, reloaded.error)
  end)
end
function M.recover_draft(path)
  return result(function()
    writable()
    if not path then
      local paths = storage.drafts(M.storage)
      vim.ui.select(paths, {
        prompt = 'Recover draft (does not overwrite newer state; export or save-copy if conflicted)',
      }, function(chosen)
        if chosen then
          M.notify(M.recover_draft(chosen))
        end
      end)
      return
    end
    assert(
      not M.runtime.unsaved and not ui().notes_modified(),
      'Save existing edits as a recovery copy before recovering a draft'
    )
    storage.external(path, ensure().root)
    local recovered = vim.json.decode(assert(storage.read(path)))
    model.validate(recovered)
    assert(
      recovered.schema_version == model.schema,
      'Unsupported draft schema; preserve it as a recovery copy'
    )
    assert(
      recovered.id == ensure().id and recovered.root == ensure().root,
      'Draft belongs to another workspace'
    )
    M.session = model.session(recovered)
    M.runtime.unsaved = true
    M.runtime.active = nil
    anchors.reset()
    ui().close_panel()
    M.changed()
  end)
end
function M.relink(root)
  return result(function()
    writable()
    ui().store_notes()
    root = storage.canonical(assert(root, 'Supply the new repository root'))
    local old_root = ensure().root
    local _, target = storage.load(root, M.config.data_dir)
    assert(not storage.read(target.path), 'A workspace already exists at the destination root')
    local saved = M.save()
    assert(saved.ok, saved.error)
    -- Preserve the original document as a recovery copy before writing the new identity mapping.
    local candidate = model.copy(ensure())
    candidate.root, candidate.revision = root, 0
    storage.save(candidate, target)
    M.session, M.storage = model.session(candidate), target
    anchors.reset()
    M.runtime.last_jump = nil
    M.changed()
    return { old_root = old_root, root = root, id = candidate.id }
  end)
end
---@return string Statusline text with escaped percent characters
function M.status()
  local inv = M.session and M.session.workspace.investigations[M.runtime.active]
  if not inv then
    return ''
  end
  local position, depth = model.index(inv.route, inv.selected) or 0, 0
  local cursor = inv.selected
  while cursor do
    local parent, kind = model.parent(inv, cursor)
    if kind == 'branch' then
      depth = depth + 1
    end
    cursor = parent
  end
  local total = vim.tbl_count(inv.nodes)
  local flags = (M.storage.readonly and ' [read-only]' or '')
    .. (navigation.off_trail(M.runtime, inv) and ' [off-trail]' or '')
    .. ((M.runtime.unsaved or ui().notes_modified()) and ' [unsaved]' or '')
  local name = inv.name:gsub('%%', '%%%%'):gsub('[\r\n]', ' ')
  return #inv.edges == 0 and string.format('%s · %d / %d%s', name, position, #inv.primary, flags)
    or string.format(
      '%s · step %d / %d · branch depth %d · %d nodes%s',
      name,
      position,
      #inv.route,
      depth,
      total,
      flags
    )
end
function M.notify(value)
  if value and not value.ok then
    vim.notify('TDLU: ' .. value.error, vim.log.levels.ERROR)
  end
  return value
end
---@param config? TDLUConfig
---@return table
function M.setup(config)
  M.is_setup = true
  M.config = vim.tbl_deep_extend('force', model.copy(defaults), config or {})
  assert(vim.fn.has('nvim-0.11') == 1, 'tdlu.nvim requires Neovim 0.11+')
  require('tdlu.commands').register(M.config)
  local group = vim.api.nvim_create_augroup('TDLU', { clear = true })
  ui().apply_theme()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      ui().apply_theme()
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(event)
      if M.session and not vim.b[event.buf].tdlu_pane and not M.storage.readonly then
        anchors.sync(ensure(), event.buf)
        persist()
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      if M.session and not M.storage.readonly then
        M.notify(M.save())
      end
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function()
      if M.session then
        ui().render()
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      ui().resize()
    end,
  })
  return M
end
function M.disable()
  local saved = M.session and not M.storage.readonly and M.save() or { ok = true }
  if not saved.ok then
    return saved
  end
  ui().close()
  anchors.reset()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      vim.api.nvim_buf_clear_namespace(buffer, M.runtime.highlight_ns, 0, -1)
    end
  end
  vim.api.nvim_del_augroup_by_name('TDLU')
  require('tdlu.commands').unregister()
  M.session, M.storage = nil, nil
  M.runtime.active, M.runtime.last_jump, M.runtime.pinned_source = nil, nil, nil
  M.runtime.frames = {}
  return { ok = true }
end
return M
