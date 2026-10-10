---@class TDLUResult
---@field ok boolean
---@field value? any
---@field error? string

---@class TDLUCaptureOptions
---@field prompt_title? boolean
---@field title? string
---@field visual? boolean
---@field insert? boolean
---@field branch? boolean
---@field label? string

---@class TDLUExportOptions
---@field directory? string External destination directory
---@field metadata_only? boolean
---@field include_unsaved? boolean
---@field current_only? boolean
---@field excerpt_bytes? integer

---@class TDLUConfig
---@field data_dir? string External storage directory
---@field width? integer
---@field side? 'left'|'right'
---@field narrow_columns? integer
---@field notes_debounce_ms? integer
---@field follow_colorscheme? boolean Link Telescope colors to the current editor palette

---@class TDLUSpan
---@field start_row integer Zero-based
---@field start_col integer UTF-8 byte offset
---@field end_row integer Zero-based, end-exclusive
---@field end_col integer UTF-8 byte offset, end-exclusive
---@field text string Captured evidence

---@class TDLUAnchor
---@field path string Workspace-relative canonical path
---@field kind 'point'|'character'|'line'|'block'
---@field spans TDLUSpan[]
---@field context table[]
---@field fingerprint string
---@field captured_at integer
---@field git_revision? string
---@field unsaved boolean

-- Pure Lua: no editor or filesystem state belongs in this module.
local M = { schema = 1 }
local serial = 0
function M.copy(value)
  if type(value) ~= 'table' then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[M.copy(key)] = M.copy(item)
  end
  return result
end
function M.id()
  if M.id_source then
    return M.id_source()
  end
  serial = serial + 1
  return string.format('%x-%x-%x', os.time(), math.random(0, 0x7fffffff), serial)
end
function M.index(items, id)
  for index, item in ipairs(items) do
    if item == id then
      return index
    end
  end
end
function M.workspace(root)
  return {
    schema_version = M.schema,
    id = M.id(),
    root = root,
    revision = 0,
    investigations = {},
    created_at = os.time(),
  }
end
function M.investigation(name)
  return {
    id = M.id(),
    name = name,
    notes = '',
    status = 'active',
    nodes = {},
    primary = {},
    roots = {},
    orphans = {},
    edges = {},
    route = {},
    last_child = {},
    created_at = os.time(),
    updated_at = os.time(),
  }
end
function M.children(inv, source)
  local result = {}
  local position = M.index(inv.primary, source)
  if position and inv.primary[position + 1] then
    result[#result + 1] = { destination = inv.primary[position + 1], kind = 'primary' }
  end
  local branches = {}
  for _, edge in ipairs(inv.edges) do
    if edge.source == source then
      branches[#branches + 1] = edge
    end
  end
  table.sort(branches, function(left, right)
    return left.order < right.order
  end)
  for _, edge in ipairs(branches) do
    result[#result + 1] = { destination = edge.destination, kind = 'branch', edge = edge }
  end
  return result
end
function M.parent(inv, id)
  local position = M.index(inv.primary, id)
  if position and position > 1 then
    return inv.primary[position - 1], 'primary'
  end
  for _, edge in ipairs(inv.edges) do
    if edge.destination == id then
      return edge.source, 'branch', edge
    end
  end
end
function M.refresh_roots(inv)
  inv.roots = {}
  for id in pairs(inv.nodes) do
    if not M.parent(inv, id) and not M.index(inv.orphans, id) then
      inv.roots[#inv.roots + 1] = id
    end
  end
  table.sort(inv.roots)
  if inv.primary[1] then
    local index = M.index(inv.roots, inv.primary[1])
    if index then
      table.remove(inv.roots, index)
      table.insert(inv.roots, 1, inv.primary[1])
    end
  end
end
function M.validate(workspace)
  assert(type(workspace.id) == 'string' and type(workspace.root) == 'string', 'Invalid workspace')
  assert(
    type(workspace.revision) == 'number' and type(workspace.investigations) == 'table',
    'Invalid workspace revision or traces'
  )
  local ownership = {}
  for inv_id, inv in pairs(workspace.investigations) do
    assert(inv.id == inv_id and type(inv.name) == 'string', 'Invalid trace')
    assert(inv.status == 'active' or inv.status == 'archived', 'Invalid status')
    local incoming, seen_primary = {}, {}
    for index, id in ipairs(inv.primary) do
      assert(inv.nodes[id] and not seen_primary[id], 'Invalid primary trail')
      seen_primary[id] = true
      if index > 1 then
        incoming[id] = inv.primary[index - 1]
      end
    end
    local edge_ids = {}
    for _, edge in ipairs(inv.edges) do
      assert(
        type(edge.id) == 'string' and not edge_ids[edge.id] and type(edge.order) == 'number',
        'Invalid edge'
      )
      edge_ids[edge.id] = true
      assert(inv.nodes[edge.source] and inv.nodes[edge.destination], 'Dangling branch')
      assert(not incoming[edge.destination], 'Shared-node merges are not supported')
      incoming[edge.destination] = edge.source
    end
    for id, node in pairs(inv.nodes) do
      assert(id == node.id and not ownership[id], 'A node must belong to exactly one trace')
      assert(node.kind == 'location' or node.kind == 'link', 'Unknown node kind')
      assert(type(node.notes) == 'string', 'Invalid notes')
      if node.kind == 'location' then
        assert(
          node.validity == 'valid' or node.validity == 'invalid' or node.validity == 'provisional',
          'Invalid validity'
        )
        local anchor = node.anchor
        assert(
          type(anchor) == 'table'
            and type(anchor.path) == 'string'
            and type(anchor.spans) == 'table',
          'Invalid anchor'
        )
        assert(
          anchor.path ~= ''
            and not anchor.path:match('^/')
            and not anchor.path:match('^%.%./')
            and not anchor.path:match('/%.%./')
            and not anchor.path:match('/%.%.$'),
          'Unsafe anchor path'
        )
        assert(#anchor.spans > 0 and type(anchor.context) == 'table', 'Missing anchor evidence')
        for _, span in ipairs(anchor.spans) do
          assert(
            type(span.start_row) == 'number'
              and span.start_row >= 0
              and type(span.start_col) == 'number'
              and span.start_col >= 0,
            'Invalid start coordinate'
          )
          assert(
            type(span.end_row) == 'number'
              and span.end_row >= span.start_row
              and type(span.end_col) == 'number'
              and span.end_col >= 0
              and type(span.text) == 'string',
            'Invalid end coordinate'
          )
          assert(span.end_row > span.start_row or span.end_col >= span.start_col, 'Reversed span')
        end
      else
        assert(type(node.target) == 'string', 'Invalid trace link')
      end
      ownership[id] = inv_id
      local path, cursor = {}, id
      while cursor do
        assert(not path[cursor], 'Cycles are not supported')
        path[cursor], cursor = true, incoming[cursor]
      end
    end
    for _, id in ipairs(inv.orphans) do
      assert(inv.nodes[id] and not incoming[id], 'Invalid orphan')
    end
    for _, id in ipairs(inv.roots) do
      assert(inv.nodes[id] and not incoming[id], 'Invalid root')
    end
    for index, id in ipairs(inv.route) do
      assert(inv.nodes[id], 'Route references missing node')
      if index > 1 then
        assert(incoming[id] == inv.route[index - 1], 'Disconnected route')
      end
    end
    assert(not inv.selected or inv.nodes[inv.selected], 'Selection references missing node')
    for source, child in pairs(inv.last_child) do
      assert(incoming[child] == source, 'Invalid remembered child')
    end
  end
  return true
end
function M.route(inv, id)
  assert(inv.nodes[id], 'Unknown node')
  local prefix, cursor, ancestry = {}, id, {}
  while cursor do
    assert(not ancestry[cursor], 'Cycles are not supported')
    ancestry[cursor] = true
    table.insert(prefix, 1, cursor)
    cursor = M.parent(inv, cursor)
  end
  local seen = {}
  for _, item in ipairs(prefix) do
    seen[item] = true
  end
  cursor = id
  while cursor do
    local children = M.children(inv, cursor)
    local chosen = inv.last_child[cursor]
    if chosen then
      local found = false
      for _, child in ipairs(children) do
        if child.destination == chosen then
          found = true
        end
      end
      if not found then
        chosen = nil
      end
    end
    if not chosen and #children == 1 then
      chosen = children[1].destination
    end
    if not chosen and children[1] and children[1].kind == 'primary' then
      chosen = children[1].destination
    end
    if not chosen or seen[chosen] then
      break
    end
    prefix[#prefix + 1], seen[chosen], cursor = chosen, true, chosen
  end
  return prefix
end
function M.select(inv, id)
  local child, parent = id, M.parent(inv, id)
  while parent do
    inv.last_child[parent] = child
    child, parent = parent, M.parent(inv, parent)
  end
  inv.route, inv.selected, inv.visited_at = M.route(inv, id), id, os.time()
end
function M.clean_route(inv)
  for source, child in pairs(inv.last_child) do
    if not inv.nodes[source] or M.parent(inv, child) ~= source then
      inv.last_child[source] = nil
    end
  end
  if inv.selected and not inv.nodes[inv.selected] then
    inv.selected = inv.primary[1] or next(inv.nodes)
  end
  inv.route = inv.selected and M.route(inv, inv.selected) or {}
  M.refresh_roots(inv)
end
function M.add(inv, node, after, source, label)
  assert(not inv.nodes[node.id], 'Duplicate node')
  inv.nodes[node.id] = node
  if source then
    assert(inv.nodes[source], 'Branch source disappeared')
    local order = 1
    for _, edge in ipairs(inv.edges) do
      if edge.source == source then
        order = math.max(order, edge.order + 1)
      end
    end
    inv.edges[#inv.edges + 1] =
      { id = M.id(), source = source, destination = node.id, label = label or '', order = order }
  else
    local position = after
        and assert(M.index(inv.primary, after), 'Insert requires a primary entry')
      or #inv.primary
    table.insert(inv.primary, position + 1, node.id)
  end
  M.select(inv, node.id)
  M.clean_route(inv)
end
function M.move(inv, first, last, insertion)
  assert(first >= 1 and last >= first and last <= #inv.primary, 'Select a contiguous primary range')
  assert(insertion >= 1 and insertion <= #inv.primary + 1, 'Invalid insertion point')
  assert(insertion < first or insertion > last + 1, 'Insertion point is inside selected range')
  local moved = {}
  for _ = first, last do
    moved[#moved + 1] = table.remove(inv.primary, first)
  end
  if insertion > last then
    insertion = insertion - #moved
  end
  for index, id in ipairs(moved) do
    table.insert(inv.primary, insertion + index - 1, id)
  end
  M.clean_route(inv)
end
function M.remove(inv, ids)
  local removed = {}
  for _, id in ipairs(ids) do
    assert(inv.nodes[id], 'Unknown node')
    removed[id] = true
  end
  local selection = M.index(inv.primary, inv.selected)
  for index = #inv.primary, 1, -1 do
    if removed[inv.primary[index]] then
      table.remove(inv.primary, index)
    end
  end
  for index = #inv.edges, 1, -1 do
    local edge = inv.edges[index]
    if removed[edge.source] or removed[edge.destination] then
      table.remove(inv.edges, index)
    end
  end
  for index = #inv.orphans, 1, -1 do
    if removed[inv.orphans[index]] then
      table.remove(inv.orphans, index)
    end
  end
  for id in pairs(removed) do
    inv.nodes[id] = nil
  end
  if removed[inv.selected] then
    inv.selected = inv.primary[math.min(selection or 1, #inv.primary)] or next(inv.nodes)
  end
  M.clean_route(inv)
end
function M.detach_plan(inv, first, last)
  assert(
    first >= 1 and last >= first and last <= #inv.primary,
    'Detach requires a contiguous primary range'
  )
  local transfer = {}
  local function descendants(id)
    if transfer[id] then
      return
    end
    transfer[id] = true
    for _, child in ipairs(M.children(inv, id)) do
      if child.kind == 'branch' then
        descendants(child.destination)
      end
    end
  end
  for index = first, last do
    descendants(inv.primary[index])
  end
  return transfer
end
function M.detach(workspace, inv, first, last, name)
  local transfer = M.detach_plan(inv, first, last)
  local target = M.investigation(name)
  target.origin = {
    investigation_id = inv.id,
    predecessor_id = inv.primary[first - 1],
    successor_id = inv.primary[last + 1],
    detached_at = os.time(),
  }
  local link = {
    id = M.id(),
    kind = 'link',
    target = target.id,
    title = name,
    notes = '',
    created_at = os.time(),
    updated_at = os.time(),
  }
  local moved_first = inv.primary[first]
  for _ = first, last do
    target.primary[#target.primary + 1] = table.remove(inv.primary, first)
  end
  for id in pairs(transfer) do
    target.nodes[id], inv.nodes[id] = inv.nodes[id], nil
  end
  for index = #inv.edges, 1, -1 do
    local edge = inv.edges[index]
    if transfer[edge.source] then
      table.insert(target.edges, 1, table.remove(inv.edges, index))
    end
  end
  for _, edge in ipairs(inv.edges) do
    if edge.destination == moved_first then
      edge.destination = link.id
    end
  end
  for source, child in pairs(inv.last_child) do
    if transfer[source] then
      target.last_child[source], inv.last_child[source] = child, nil
    elseif transfer[child] then
      inv.last_child[source] = link.id
    end
  end
  inv.nodes[link.id] = link
  table.insert(inv.primary, first, link.id)
  if transfer[inv.selected] then
    target.selected, inv.selected = inv.selected, link.id
  end
  workspace.investigations[target.id] = target
  M.clean_route(inv)
  M.clean_route(target)
  return target, link
end
function M.bypass(inv, id, successor)
  assert(inv.nodes[id] and inv.nodes[id].validity == 'invalid', 'Bypass requires an invalid node')
  assert(M.parent(inv, successor) == id, 'Successor must be a direct child')
  local predecessor, _, incoming = M.parent(inv, id)
  local position = M.index(inv.primary, id)
  local _, _, outgoing = M.parent(inv, successor)
  if position then
    local primary_successor = inv.primary[position + 1]
    if successor ~= primary_successor then
      if not primary_successor then
        for index, edge in ipairs(inv.edges) do
          if edge == outgoing then
            table.remove(inv.edges, index)
            break
          end
        end
        table.insert(inv.primary, position + 1, successor)
      elseif predecessor then
        outgoing.source = predecessor
        local order = 1
        for _, edge in ipairs(inv.edges) do
          if edge ~= outgoing and edge.source == predecessor then
            order = math.max(order, edge.order + 1)
          end
        end
        outgoing.order = order
      else
        -- Bypassing the primary root to a side destination produces two roots:
        -- the chosen destination and the retained primary continuation.
        for index, edge in ipairs(inv.edges) do
          if edge == outgoing then
            table.remove(inv.edges, index)
            break
          end
        end
      end
    end
    table.remove(inv.primary, position)
  else
    for index = #inv.edges, 1, -1 do
      if inv.edges[index] == outgoing or inv.edges[index] == incoming then
        table.remove(inv.edges, index)
      end
    end
    if predecessor then
      inv.edges[#inv.edges + 1] = {
        id = M.id(),
        source = predecessor,
        destination = successor,
        label = incoming.label,
        order = incoming.order,
      }
    end
  end
  inv.orphans[#inv.orphans + 1] = id
  if predecessor then
    inv.last_child[predecessor] = successor
  end
  if inv.selected == id then
    inv.selected = successor
  end
  M.clean_route(inv)
end
function M.reparent(inv, id, source)
  assert(inv.nodes[id] and inv.nodes[source] and id ~= source, 'Choose a different existing source')
  assert(not M.index(inv.primary, id), 'Only side branches or orphans can be reparented')
  for index = #inv.edges, 1, -1 do
    if inv.edges[index].destination == id then
      table.remove(inv.edges, index)
    end
  end
  for index = #inv.orphans, 1, -1 do
    if inv.orphans[index] == id then
      table.remove(inv.orphans, index)
    end
  end
  local order = 1
  for _, edge in ipairs(inv.edges) do
    if edge.source == source then
      order = math.max(order, edge.order + 1)
    end
  end
  inv.edges[#inv.edges + 1] =
    { id = M.id(), source = source, destination = id, label = '', order = order }
  -- Transaction validation rejects cycles before the candidate is committed.
  M.clean_route(inv)
end
function M.session(workspace)
  return { workspace = workspace, undo = {}, redo = {} }
end
function M.transaction(session, operation)
  local candidate = M.copy(session.workspace)
  local ok, result = pcall(function()
    local value = operation(candidate)
    M.validate(candidate)
    return value
  end)
  if not ok then
    return { ok = false, error = tostring(result) }
  end
  session.undo[#session.undo + 1] = M.copy(session.workspace)
  session.redo = {}
  session.workspace = candidate
  return { ok = true, value = result }
end
function M.history(session, direction)
  local from, to = session[direction], session[direction == 'undo' and 'redo' or 'undo']
  if #from == 0 then
    return { ok = false, error = 'Nothing to ' .. direction }
  end
  local previous = table.remove(from)
  previous.revision, previous.root = session.workspace.revision, session.workspace.root
  to[#to + 1] = M.copy(session.workspace)
  session.workspace = previous
  return { ok = true }
end
return M
