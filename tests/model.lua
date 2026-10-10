package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local model = require('tdlu.model')
local count = 0
local function test(name, action)
  local ok, reason = pcall(action)
  if not ok then
    error(name .. ': ' .. tostring(reason))
  end
  count = count + 1
  print('PASS ' .. name)
end
local function fixture()
  local workspace = model.workspace('/project')
  local inv = model.investigation('Trail')
  workspace.investigations[inv.id] = inv
  return workspace, inv
end
local function node(title)
  return {
    id = model.id(),
    kind = 'location',
    title = title,
    notes = title .. ' notes',
    validity = 'valid',
    repairs = {},
    anchor = {
      path = 'a.lua',
      context = { { offset = 0, text = title } },
      spans = { { start_row = 0, start_col = 0, end_row = 0, end_col = 1, text = title } },
    },
  }
end
local function add(inv, title, source)
  local captured = node(title)
  model.add(inv, captured, nil, source, title)
  return captured.id
end
local function equal(left, right)
  assert(left == right, tostring(left) .. ' != ' .. tostring(right))
end
test('navigation and append preserve forward entries and independent notes', function()
  local workspace, inv = fixture()
  local first, second, third = add(inv, 'A'), add(inv, 'B'), add(inv, 'C')
  model.select(inv, first)
  model.select(inv, second)
  equal(table.concat(inv.primary), first .. second .. third)
  local fourth = add(inv, 'D')
  equal(inv.primary[3], third)
  equal(inv.primary[4], fourth)
  equal(inv.nodes[second].notes, 'B notes')
  model.validate(workspace)
end)
test('branch choice replaces route suffix and preserves graph and remembered choices', function()
  local workspace, inv = fixture()
  local source = add(inv, 'dispatch')
  local continuation = add(inv, 'tail')
  local validation, enqueue, cleanup =
    add(inv, 'validation', source), add(inv, 'enqueue', source), add(inv, 'cleanup', source)
  local nested = add(inv, 'deep', enqueue)
  model.select(inv, validation)
  equal(inv.route[2], validation)
  model.select(inv, nested)
  equal(inv.route[2], enqueue)
  equal(inv.route[3], nested)
  model.select(inv, source)
  equal(inv.route[2], enqueue)
  equal(#model.children(inv, source), 4)
  equal(inv.primary[2], continuation)
  equal(inv.nodes[cleanup].notes, 'cleanup notes')
  model.validate(workspace)
end)
test('structural transactions reject cycles and shared nodes without partial mutations', function()
  local workspace, inv = fixture()
  local source = add(inv, 'source')
  local branch = add(inv, 'branch', source)
  local child = add(inv, 'child', branch)
  local session = model.session(workspace)
  local changed = model.transaction(session, function(candidate)
    model.reparent(candidate.investigations[inv.id], branch, child)
  end)
  assert(not changed.ok)
  equal(model.parent(session.workspace.investigations[inv.id], branch), source)
  changed = model.transaction(session, function(candidate)
    local target = candidate.investigations[inv.id]
    target.edges[#target.edges + 1] =
      { id = model.id(), source = source, destination = child, order = 8 }
  end)
  assert(not changed.ok)
  equal(#session.undo, 0)
end)
test('reorder keeps stable selection and notes; undo retains persisted revision', function()
  local workspace, inv = fixture()
  local first, second, third = add(inv, 'A'), add(inv, 'B'), add(inv, 'C')
  model.select(inv, second)
  local session = model.session(workspace)
  assert(model.transaction(session, function(candidate)
    model.move(candidate.investigations[inv.id], 2, 2, 4)
  end).ok)
  local moved = session.workspace.investigations[inv.id]
  equal(moved.primary[3], second)
  equal(moved.selected, second)
  equal(moved.nodes[second].notes, 'B notes')
  session.workspace.revision = 12
  assert(model.history(session, 'undo').ok)
  equal(session.workspace.revision, 12)
  equal(session.workspace.investigations[inv.id].primary[2], second)
  equal(session.workspace.investigations[inv.id].primary[1], first)
  equal(session.workspace.investigations[inv.id].primary[3], third)
end)
test(
  'detach transfers primary segment and complete side subtrees; undo and redo preserve IDs',
  function()
    local workspace, inv = fixture()
    local first, second, third, fourth, fifth =
      add(inv, 'A'), add(inv, 'B'), add(inv, 'C'), add(inv, 'D'), add(inv, 'E')
    local branch = add(inv, 'branch', third)
    local nested = add(inv, 'nested', branch)
    model.select(inv, third)
    local session = model.session(workspace)
    local target_id, link_id
    assert(model.transaction(session, function(candidate)
      local target, link =
        model.detach(candidate, candidate.investigations[inv.id], 2, 4, 'Child cleanup')
      target_id, link_id = target.id, link.id
    end).ok)
    local source, target =
      session.workspace.investigations[inv.id], session.workspace.investigations[target_id]
    equal(table.concat(source.primary), first .. link_id .. fifth)
    equal(table.concat(target.primary), second .. third .. fourth)
    assert(target.nodes[branch] and target.nodes[nested] and not source.nodes[branch])
    equal(target.origin.predecessor_id, first)
    equal(target.origin.successor_id, fifth)
    equal(source.selected, link_id)
    equal(target.selected, third)
    model.validate(session.workspace)
    assert(model.history(session, 'undo').ok)
    equal(
      table.concat(session.workspace.investigations[inv.id].primary),
      first .. second .. third .. fourth .. fifth
    )
    assert(not session.workspace.investigations[target_id])
    equal(session.workspace.investigations[inv.id].selected, third)
    assert(model.history(session, 'redo').ok)
    model.validate(session.workspace)
  end
)
test('bypass retains invalid node with side branches; explicit reparent is undoable', function()
  local workspace, inv = fixture()
  local first, invalid, last = add(inv, 'A'), add(inv, 'B'), add(inv, 'C')
  local branch = add(inv, 'side', invalid)
  inv.nodes[invalid].validity = 'invalid'
  model.bypass(inv, invalid, last)
  equal(table.concat(inv.primary), first .. last)
  equal(inv.orphans[1], invalid)
  equal(model.parent(inv, branch), invalid)
  model.reparent(inv, branch, first)
  equal(model.parent(inv, branch), first)
  model.validate(workspace)
end)
test('remove source leaves descendants browseable and cleans remembered route IDs', function()
  local workspace, inv = fixture()
  local source = add(inv, 'source')
  local child = add(inv, 'branch', source)
  model.remove(inv, { source })
  assert(inv.nodes[child])
  equal(model.parent(inv, child), nil)
  equal(inv.roots[1], child)
  model.validate(workspace)
end)
test('bypass can select a side destination while preserving the primary forward choice', function()
  local workspace, inv = fixture()
  local first, broken, tail = add(inv, 'A'), add(inv, 'broken'), add(inv, 'tail')
  local side, retained = add(inv, 'chosen', broken), add(inv, 'retained', broken)
  inv.nodes[broken].validity = 'invalid'
  model.select(inv, first)
  model.bypass(inv, broken, side)
  equal(table.concat(inv.primary), first .. tail)
  equal(model.parent(inv, side), first)
  equal(model.parent(inv, retained), broken)
  equal(inv.route[2], side)
  equal(inv.orphans[1], broken)
  model.validate(workspace)
end)
print(count .. ' model tests passed')
