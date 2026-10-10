vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local core = require('tdlu')
local model = require('tdlu.model')
local anchors = require('tdlu.anchors')
local storage = require('tdlu.storage')
local exporter = require('tdlu.export')
local ui = require('tdlu.ui')
local base = vim.fn.tempname() .. '-tdlu-tests'
vim.fn.mkdir(base, 'p')
local count, failures, roots = 0, {}, {}
local function equal(left, right)
  assert(vim.deep_equal(left, right), vim.inspect(left) .. ' != ' .. vim.inspect(right))
end
local function success(value)
  assert(value.ok, value.error)
  return value.value
end
local function reset()
  ui.close()
  anchors.reset()
  core.session, core.storage = nil, nil
  core.runtime.active, core.runtime.unsaved, core.runtime.frames = nil, false, {}
  core.runtime.code_window, core.runtime.pinned_source, core.runtime.last_jump, core.runtime.repair_target =
    nil, nil, nil, nil
  vim.cmd('silent! only!')
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.ui.select = function(_, _, callback)
    callback(nil)
  end
  vim.ui.input = function(_, callback)
    callback(nil)
  end
end
local function fixture(lines)
  reset()
  local directory = base .. '/case-' .. tostring(count + 1)
  local root = storage.canonical(directory .. '/source')
  vim.fn.mkdir(root, 'p')
  vim.fn.mkdir(directory .. '/data', 'p')
  local initialized = vim.system({ 'git', 'init', '-q', root }):wait()
  assert(initialized.code == 0)
  roots[#roots + 1] = root
  vim.fn.writefile(
    lines or { '-- before', 'local café = 42', '-- after', 'return café' },
    root .. '/sample.lua'
  )
  vim.cmd.edit(vim.fn.fnameescape(root .. '/sample.lua'))
  core.setup({ data_dir = directory .. '/data', notes_debounce_ms = 5 })
  local workspace = core.workspace()
  equal(workspace.root, storage.canonical(root))
  return root, directory, api.nvim_get_current_buf()
end
local function test(name, action)
  local ok, err = xpcall(action, debug.traceback)
  count = count + 1
  if ok then
    print('PASS ' .. name)
  else
    failures[#failures + 1] = name .. ': ' .. err
    print('FAIL ' .. failures[#failures])
  end
end
local function create(name)
  success(core.new(name or 'Cancellation propagation'))
  return core.current()
end
local function capture(row, column, title)
  api.nvim_set_current_win(core.runtime.code_window or api.nvim_get_current_win())
  api.nvim_win_set_cursor(0, { row, column })
  return success(core.add({ title = title or '' }))
end
local function file(root, name, lines)
  vim.fn.writefile(lines, root .. '/' .. name)
end

test('exact UTF-8 byte capture; navigation and modified source buffers remain intact', function()
  local root, _, source = fixture()
  local inv = create()
  local first = capture(2, 8, 'mid-UTF8')
  equal(inv.id, core.current().id)
  equal(core.current().nodes[first].anchor.spans[1].start_col, 8)
  file(root, 'second.lua', { 'return 12' })
  vim.cmd.edit(root .. '/second.lua')
  local second_buf = api.nvim_get_current_buf()
  local second = capture(1, 3, 'second')
  api.nvim_buf_set_lines(second_buf, 0, -1, false, { 'return 13' })
  success(core.jump(first))
  equal(api.nvim_get_current_buf(), source)
  equal(api.nvim_win_get_cursor(0), { 2, 8 })
  assert(vim.bo[second_buf].modified)
  equal(api.nvim_buf_get_lines(second_buf, 0, -1, false), { 'return 13' })
  local selected = core.current().selected
  assert(not core.jump(second).ok)
  equal(core.current().selected, selected)
  equal(#core.current().primary, 2)
end)

test('character, line and block selections preserve end-exclusive byte spans', function()
  local root, _, buf = fixture({ 'aéxyz', 'b12345', 'c56789' })
  local function visual(kind, first, last)
    api.nvim_buf_set_mark(buf, '<', first[1], first[2], {})
    api.nvim_buf_set_mark(buf, '>', last[1], last[2], {})
    -- Set last visual kind through a real editor selection, then use live capture.
    api.nvim_win_set_cursor(0, first)
    vim.cmd('normal! ' .. kind)
    api.nvim_win_set_cursor(0, last)
    local node = anchors.capture(storage.canonical(root), { visual = true })
    vim.cmd('normal! \27')
    return node
  end
  local character = visual('v', { 1, 1 }, { 1, 4 })
  equal(character.anchor.kind, 'character')
  equal(character.anchor.spans[1].text, 'éxy')
  equal(character.anchor.spans[1].end_col, 5)
  local line = visual('V', { 1, 2 }, { 2, 3 })
  equal(line.anchor.kind, 'line')
  equal(line.anchor.spans[1].text, 'aéxyz\nb12345')
  local block = visual('\22', { 2, 1 }, { 3, 3 })
  equal(block.anchor.kind, 'block')
  equal(#block.anchor.spans, 2)
  equal(block.anchor.spans[1].text, '123')
  equal(block.anchor.spans[2].text, '567')
end)

test(
  'extmarks follow inserted lines; original capture is immutable and deleted spans invalidate',
  function()
    local _, _, buf =
      fixture({ '-- first', '-- before', 'local needle = 3', '-- after', 'return needle' })
    create()
    local id = capture(3, 6)
    api.nvim_buf_set_lines(buf, 0, 0, false, { '-- inserted' })
    success(core.save())
    local node = core.current().nodes[id]
    equal(node.anchor.spans[1].start_row, 3)
    equal(node.original.spans[1].start_row, 2)
    api.nvim_buf_set_lines(buf, 3, 4, false, {})
    success(core.save())
    equal(core.current().nodes[id].validity, 'invalid')
    local before = core.current().selected
    assert(not core.jump(id).ok)
    equal(core.current().selected, before)
  end
)

test(
  'restart relocates unique evidence; duplicated or missing code remains unresolved with notes',
  function()
    local root, _, buf = fixture({ 'top', 'before', 'needle()', 'after', 'bottom' })
    create()
    local id = capture(3, 2)
    core.current().nodes[id].notes = 'Preserve this note'
    success(core.save())
    anchors.reset()
    local shifted = { 'extra', 'top', 'before', 'needle()', 'after', 'bottom' }
    api.nvim_buf_set_lines(buf, 0, -1, false, shifted)
    vim.cmd.write()
    local node = core.current().nodes[id]
    local resolved = anchors.resolve(root, node)
    assert(resolved)
    equal(node.anchor.spans[1].start_row, 3)
    anchors.reset()
    local repeated = { 'prefix' }
    vim.list_extend(repeated, shifted)
    vim.list_extend(repeated, shifted)
    api.nvim_buf_set_lines(buf, 0, -1, false, repeated)
    vim.cmd.write()
    assert(not anchors.resolve(root, node))
    equal(node.validity, 'invalid')
    equal(node.reason, 'ambiguous relocation')
    equal(node.notes, 'Preserve this note')
    local other = model.copy(node)
    other.id = model.id()
    other.anchor.path = 'missing.lua'
    assert(not anchors.resolve(root, other))
    assert(other.reason:find('missing file'))
  end
)

test(
  'notes drafts stay pinned while sidebar selection browses; write and debounce persist multiline content',
  function()
    fixture()
    vim.o.columns = 160
    create()
    local first = capture(2, 0)
    local second = capture(4, 0)
    success(core.note())
    equal(ui.pane.target.id, second)
    api.nvim_buf_set_lines(
      ui.pane.notes_buf,
      0,
      -1,
      false,
      { '# Why', '', 'Multiline notes for second' }
    )
    api.nvim_exec_autocmds('TextChanged', { buffer = ui.pane.notes_buf })
    assert(vim.wait(10000, function()
      return not ui.notes_modified()
    end, 10))
    equal(core.current().nodes[second].notes, '# Why\n\nMultiline notes for second')
    api.nvim_set_current_win(ui.pane.trail_win)
    ui.select_sidebar(first)
    equal(ui.pane.target.id, second)
    success(core.jump(first))
    equal(ui.pane.target.id, first)
    local saved = vim.json.decode(assert(storage.read(core.storage.path)))
    equal(
      saved.investigations[core.current().id].nodes[second].notes,
      '# Why\n\nMultiline notes for second'
    )
  end
)

test(
  'branch pin survives editor wandering and repeated sibling capture; saved route survives reload',
  function()
    local root = fixture({ 'dispatch()', 'validate()', 'enqueue()', 'cleanup()', 'done()' })
    create()
    local source = capture(1, 2)
    local tail = capture(5, 2)
    success(core.jump(source))
    success(core.pin())
    local ids = {}
    for row = 2, 4 do
      api.nvim_win_set_cursor(0, { row, 0 })
      ids[#ids + 1] = success(core.branch('branch ' .. row))
    end
    for _, id in ipairs(ids) do
      equal(model.parent(core.current(), id), source)
    end
    success(core.jump(ids[1]))
    success(core.jump(ids[2]))
    success(core.previous())
    equal(core.current().selected, source)
    equal(core.current().route[2], ids[2])
    equal(core.current().primary[2], tail)
    success(core.next())
    equal(core.current().selected, ids[2])
    success(core.save())
    local restored = storage.load(root, core.config.data_dir)
    equal(restored.investigations[core.current().id].route, core.current().route)
    equal(restored.investigations[core.current().id].last_child[source], ids[2])
  end
)

test(
  'browser drilling/back preserves query and selection; preview never moves source cursor or route',
  function()
    fixture()
    vim.o.columns = 160
    vim.o.lines = 40
    create('Browser target')
    local first = capture(2, 3)
    capture(4, 2)
    local point, route, selected =
      api.nvim_win_get_cursor(core.runtime.code_window),
      model.copy(core.current().route),
      core.current().selected
    success(core.list())
    vim.cmd.stopinsert()
    local state = ui.browser_state
    api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { 'target' })
    ui.browser_render()
    equal(#state.filtered, 1)
    ui.browser_enter()
    equal(state.inv_id, core.current().id)
    equal(#state.filtered, 2)
    local selection_namespace = api.nvim_get_namespaces()['tdlu-row-selection']
    local function highlighted_row()
      local marks =
        api.nvim_buf_get_extmarks(state.results_buf, selection_namespace, 0, -1, { details = true })
      equal(#marks, 1)
      equal(marks[1][4].hl_group, 'TelescopeSelection')
      assert(marks[1][4].hl_eol)
      return marks[1][2] + 1
    end
    equal(highlighted_row(), 1)
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Down>', true, false, true), 'xt', false)
    equal(state.selected, 2)
    equal(highlighted_row(), 2)
    api.nvim_set_current_win(state.prompt_win)
    api.nvim_feedkeys(
      api.nvim_replace_termcodes([=[i<Up><C-\><C-n>]=], true, false, true),
      'xt',
      false
    )
    equal(state.selected, 1)
    equal(highlighted_row(), 1)
    api.nvim_feedkeys(
      api.nvim_replace_termcodes([=[i<Down><C-\><C-n>]=], true, false, true),
      'xt',
      false
    )
    equal(state.selected, 2)
    equal(api.nvim_buf_get_lines(state.prompt_buf, 0, -1, false), { '' })
    ui.browser_preview()
    equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
    equal(core.current().route, route)
    equal(core.current().selected, selected)
    ui.browser_back()
    equal(state.query, 'target')
    equal(state.selected, 1)
    ui.browser_enter()
    state.selected = 1
    ui.browser_enter()
    equal(core.current().selected, first)
    assert(not ui.browser_state)
    vim.o.columns = 70
    ui.resize()
    assert(ui.pane.narrow)
    success(core.note())
    assert(not ui.pane.trail_win and ui.pane.notes_win)
    ui.pane_view()
    assert(ui.pane.trail_win and not ui.pane.notes_win)
    success(core.list())
    vim.cmd.stopinsert()
    assert(ui.browser_state.preview_win)
    ui.close_browser()
  end
)

test(
  'closed code window is safely replaced; notes and trail buffers are never overwritten',
  function()
    fixture()
    vim.o.columns = 160
    create()
    local id = capture(2, 3)
    local source_window = core.runtime.code_window
    api.nvim_win_close(source_window, true)
    success(core.jump(id))
    assert(api.nvim_win_is_valid(core.runtime.code_window))
    assert(
      core.runtime.code_window ~= ui.pane.trail_win
        and core.runtime.code_window ~= ui.pane.notes_win
    )
    equal(vim.b[api.nvim_win_get_buf(ui.pane.trail_win)].tdlu_pane, 'trail')
    equal(vim.b[api.nvim_win_get_buf(ui.pane.notes_win)].tdlu_pane, 'notes')
  end
)

test(
  'revision conflicts preserve newer data and recoverable draft; failed write keeps notes modified',
  function()
    local root = fixture()
    create()
    capture(2, 0)
    success(core.save())
    local stale, stale_state = storage.load(root, core.config.data_dir)
    core.current().notes = 'newer'
    success(core.save())
    stale.investigations[core.current().id].notes = 'stale changes'
    local ok, err = pcall(storage.save, stale, stale_state)
    assert(not ok and tostring(err):find('conflict'))
    storage.draft(stale, stale_state)
    local current = storage.load(root, core.config.data_dir)
    equal(current.investigations[core.current().id].notes, 'newer')
    equal(#storage.drafts(stale_state), 1)
    success(core.note())
    api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'unsaved draft' })
    core.storage.path = root .. '/forbidden.json'
    local failed = core.save()
    assert(not failed.ok)
    assert(ui.notes_modified() and core.runtime.unsaved)
    assert(not vim.uv.fs_stat(root .. '/forbidden.json'))
  end
)

test(
  'corrupt JSON remains untouched until explicit recovery; newer schemas are read-only',
  function()
    local root = fixture()
    create()
    capture(2, 0)
    success(core.save())
    local path = core.storage.path
    storage.atomic(path, '{broken', root)
    local _, state = storage.load(root, core.config.data_dir)
    assert(state.readonly and state.recovery)
    equal(storage.read(path), '{broken')
    storage.recover(state)
    local recovered = storage.load(root, core.config.data_dir)
    model.validate(recovered)
    local preserved = vim.fn.glob(path .. '.corrupt-*', false, true)
    equal(#preserved, 1)
    equal(storage.read(preserved[1]), '{broken')
    recovered.schema_version = 99
    storage.atomic(path, vim.json.encode(recovered), root)
    local future, readonly = storage.load(root, core.config.data_dir)
    assert(readonly.readonly)
    assert(not pcall(storage.save, future, readonly))
    equal(vim.json.decode(storage.read(path)).schema_version, 99)
  end
)

test('live writer locks are respected; dead process locks recover after crash', function()
  local root = fixture()
  create()
  success(core.save())
  local path = core.storage.path .. '.lock'
  storage.atomic(
    path,
    vim.json.encode({ pid = vim.uv.os_getpid(), host = vim.uv.os_gethostname(), writer = 'other' }),
    root
  )
  assert(not core.save().ok)
  vim.uv.fs_unlink(path)
  storage.atomic(
    path,
    vim.json.encode({ pid = 2147483647, host = vim.uv.os_gethostname(), writer = 'dead' }),
    root
  )
  success(core.save())
  assert(not vim.uv.fs_stat(path))
end)

test(
  'repository isolation rejects in-tree, symlink, Git metadata and linked worktree destinations',
  function()
    local root, directory = fixture()
    assert(not pcall(storage.external, root .. '/.ignored/artifacts', root))
    assert(vim.uv.fs_symlink(root, directory .. '/alias'))
    assert(not pcall(storage.external, directory .. '/alias/new/artifacts', root))
    assert(not pcall(storage.external, root .. '/.git/artifacts', root))
    local tree = vim
      .system(
        { 'git', '-C', root, 'hash-object', '-t', 'tree', '-w', '--stdin' },
        { stdin = '', text = true }
      )
      :wait()
    assert(tree.code == 0)
    local commit = vim
      .system({
        'git',
        '-C',
        root,
        '-c',
        'commit.gpgsign=false',
        'commit-tree',
        vim.trim(tree.stdout),
        '-m',
        'Disposable fixture',
      }, {
        text = true,
        env = {
          GIT_AUTHOR_NAME = 'Fixture',
          GIT_AUTHOR_EMAIL = 'fixture@example.invalid',
          GIT_COMMITTER_NAME = 'Fixture',
          GIT_COMMITTER_EMAIL = 'fixture@example.invalid',
        },
      })
      :wait()
    assert(commit.code == 0, commit.stderr)
    local linked = directory .. '/linked'
    assert(
      vim
        .system({ 'git', '-C', root, 'worktree', 'add', '--detach', linked, vim.trim(commit.stdout) })
        :wait().code == 0
    )
    storage.known[root] = nil
    assert(not pcall(storage.external, linked .. '/plugin-data', root))
    local metadata = vim.trim(assert(storage.git(linked, { 'rev-parse', '--absolute-git-dir' })))
    assert(not pcall(storage.external, metadata .. '/plugin-data', root))
    local separate_source, separate_metadata =
      directory .. '/other-source', directory .. '/separate-metadata'
    assert(
      vim
        .system({ 'git', 'init', '-q', '--separate-git-dir=' .. separate_metadata, separate_source })
        :wait().code == 0
    )
    assert(not pcall(storage.external, separate_metadata .. '/artifacts', root))
    local safe = storage.external(directory .. '/external', root)
    equal(safe, storage.canonical(directory .. '/external'))
    create()
    local id = capture(2, 0)
    local node = core.current().nodes[id]
    file(root, 'outside-link.lua', { 'x' })
    vim.uv.fs_unlink(root .. '/outside-link.lua')
    file(directory, 'outside.lua', { 'x' })
    assert(vim.uv.fs_symlink(directory .. '/outside.lua', root .. '/outside-link.lua'))
    local external = model.copy(node)
    external.id = model.id()
    external.anchor.path = 'outside-link.lua'
    assert(not anchors.resolve(root, external))
  end
)

test(
  'detachment transfers branches atomically; link back, undo and redo restore ownership',
  function()
    fixture({ 'A()', 'B()', 'C()', 'D()', 'E()' })
    vim.o.columns = 160
    local source_id = create().id
    local ids = {}
    for row = 1, 5 do
      ids[row] = capture(row, 1, string.char(64 + row))
    end
    success(core.jump(ids[3]))
    success(core.pin())
    api.nvim_win_set_cursor(0, { 2, 0 })
    local branch = success(core.branch('side'))
    success(core.jump(ids[3]))
    success(core.detach('Child cleanup', 2, 4, true))
    local source = core.current()
    equal(#source.primary, 3)
    local link = source.nodes[source.primary[2]]
    local target = core.workspace().investigations[link.target]
    equal(target.primary, { ids[2], ids[3], ids[4] })
    assert(target.nodes[branch] and not source.nodes[branch])
    success(core.jump(link.id))
    equal(core.current().id, target.id)
    success(core.back())
    equal(core.current().id, source_id)
    equal(core.current().selected, link.id)
    success(core.undo())
    equal(core.current().primary, ids)
    assert(not core.workspace().investigations[target.id])
    success(core.redo())
    equal(core.current().primary[2], link.id)
    model.validate(core.workspace())
  end
)

test(
  'manual invalidation preserves descendants; verified reattachment and path repair retain IDs and notes',
  function()
    fixture({ 'A()', 'B()', 'C()', 'D()' })
    create()
    local first, broken, last = capture(1, 0), capture(2, 0), capture(3, 0)
    success(core.jump(broken))
    success(core.pin())
    api.nvim_win_set_cursor(0, { 4, 0 })
    local side = success(core.branch('side'))
    success(core.invalidate('wrong code', broken))
    local node = core.current().nodes[broken]
    assert(not core.jump(broken).ok)
    equal(model.parent(core.current(), side), broken)
    success(core.jump(side))
    api.nvim_win_set_cursor(0, { 2, 1 })
    success(core.reattach({}, broken))
    equal(core.current().nodes[broken].validity, 'valid')
    equal(model.parent(core.current(), side), broken)
    success(core.invalidate('broken', broken))
    success(core.bypass(broken, last, true))
    equal(core.current().primary, { first, last })
    equal(core.current().orphans, { broken })
    equal(model.parent(core.current(), side), broken)
    success(core.undo())
    equal(core.current().primary, { first, broken, last })
    assert(node.notes == '')
  end
)

test(
  'portable exports preserve graph/links/invalid/orphans without absolute roots or model mutation',
  function()
    local root, directory = fixture({ 'A()', 'B()', 'C()', 'D()', 'E()' })
    create()
    local ids = {}
    for row = 1, 5 do
      ids[row] = capture(row, 0)
    end
    success(core.jump(ids[2]))
    success(core.pin())
    api.nvim_win_set_cursor(0, { 3, 0 })
    local branch = success(core.branch('side'))
    success(core.invalidate('historical only', branch))
    success(core.detach('Detached', 2, 3, true))
    local snapshot = model.copy(core.workspace())
    local path = exporter.write(core.workspace(), core.current().id, directory .. '/exports', {})
    equal(core.workspace(), snapshot)
    local json = assert(storage.read(path .. '/investigation.json'))
    assert(not json:find(root, 1, true) and not json:find('/Users/', 1, true))
    local bundle = vim.json.decode(json)
    equal(#bundle.investigations, 2)
    local found
    for _, inv in ipairs(bundle.investigations) do
      if inv.nodes[branch] then
        found = inv.nodes[branch]
      end
    end
    equal(found.reason, 'historical only')
    equal(found.validity, 'invalid')
    assert(found.original and found.anchor)
    local markdown = storage.read(path .. '/investigation.md')
    assert(markdown:find('Historical capture only', 1, true))
    assert(storage.read(path .. '/manifest.json'))
    local metadata =
      exporter.snapshot(core.workspace(), core.current().id, { metadata_only = true })
    for _, inv in ipairs(metadata.investigations) do
      for _, node in pairs(inv.nodes) do
        if node.kind == 'location' then
          assert(not node.anchor.spans[1].text and not node.original.context[1].text)
        end
      end
    end
    assert(not pcall(exporter.write, core.workspace(), core.current().id, root .. '/exports', {}))
    local current_only =
      exporter.snapshot(core.workspace(), core.current().id, { current_only = true })
    equal(#current_only.investigations, 1)
    assert(next(current_only.references))
  end
)

test(
  'unsaved excerpts are opt-in; bound large source excerpts; failed export has no completion manifest',
  function()
    local root, directory, buf = fixture({ string.rep('x', 8000) })
    create()
    api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep('x', 9000) })
    local id = capture(1, 1)
    local bundle = exporter.snapshot(core.workspace(), core.current().id, {})
    assert(bundle.manifest.has_provisional_locations)
    assert(not bundle.investigations[1].nodes[id].anchor.spans[1].text)
    local included =
      exporter.snapshot(core.workspace(), core.current().id, { include_unsaved = true })
    assert(included.investigations[1].nodes[id].anchor.spans[1].text)
    assert(#included.investigations[1].nodes[id].anchor.context[1].text < 600)
    file(directory, 'not-a-directory', { 'occupied' })
    assert(
      not pcall(
        exporter.write,
        core.workspace(),
        core.current().id,
        directory .. '/not-a-directory',
        {}
      )
    )
    assert(not vim.uv.fs_stat(root .. '/exports'))
  end
)

test('separate Neovim process resumes saved selection/route and multiline notes', function()
  local root = fixture()
  create('Restart')
  local first = capture(2, 8)
  capture(4, 0)
  success(core.jump(first))
  core.current().nodes[first].notes = 'Line one\nLine two'
  success(core.save())
  local inv_id = core.current().id
  local child = vim
    .system({
      vim.v.progpath,
      '--headless',
      '-u',
      'NONE',
      '-i',
      'NONE',
      '-l',
      'tests/restart.lua',
      root,
      core.config.data_dir,
      inv_id,
      first,
    }, { text = true })
    :wait()
  assert(child.code == 0, child.stdout .. child.stderr)
end)

test(
  'pending notes commit before removal/detachment; transaction undo preserves committed notes',
  function()
    fixture({ 'A()', 'B()', 'C()' })
    vim.o.columns = 160
    create()
    local first, second, third = capture(1, 0), capture(2, 0), capture(3, 0)
    success(core.note())
    api.nvim_buf_set_lines(
      ui.pane.notes_buf,
      0,
      -1,
      false,
      { 'Draft before detach', 'Second line' }
    )
    success(core.detach('With notes', 3, 3, true))
    local link = core.current().nodes[core.current().primary[3]]
    equal(
      core.workspace().investigations[link.target].nodes[third].notes,
      'Draft before detach\nSecond line'
    )
    assert(not core.runtime.unsaved)
    success(core.undo())
    equal(core.current().nodes[third].notes, 'Draft before detach\nSecond line')
    success(core.note())
    api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'Draft before remove' })
    success(core.remove({ third }))
    assert(not core.runtime.unsaved)
    success(core.undo())
    equal(core.current().nodes[third].notes, 'Draft before remove')
    equal(core.current().primary, { first, second, third })
  end
)

test(
  'repair browser previews historical and proposed evidence; acceptance preserves code cursor',
  function()
    fixture({ 'before', 'needle()', 'after' })
    create()
    local id = capture(2, 2)
    success(core.invalidate('manual', id))
    local point = api.nvim_win_get_cursor(core.runtime.code_window)
    success(core.repair(id))
    vim.cmd.stopinsert()
    local state = assert(ui.browser_state)
    assert(state.filtered[1].candidate)
    local preview = table.concat(api.nvim_buf_get_lines(state.preview_buf, 0, -1, false), '\n')
    assert(
      preview:find('Old captured context', 1, true)
        and preview:find('Proposed verified candidate', 1, true)
    )
    equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
    ui.browser_enter()
    equal(core.current().nodes[id].validity, 'valid')
    equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
  end
)

test('recovery copies allow conflict reload and reject edits made after saving a copy', function()
  fixture()
  create()
  capture(2, 0)
  success(core.note())
  api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'copied draft' })
  core.runtime.unsaved = true
  success(core.save_copy())
  api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'newer draft' })
  assert(not core.reload().ok)
  success(core.save_copy())
  success(core.reload())
  assert(not core.runtime.unsaved)
end)

test(
  'external deletion invalidates even loaded buffers; branch chooser supports drill-back without jumping',
  function()
    local root, _, buf = fixture({ 'source()', 'first()', 'second()' })
    create()
    local source = capture(1, 0)
    success(core.pin())
    api.nvim_win_set_cursor(0, { 2, 0 })
    local first = success(core.branch('first'))
    api.nvim_win_set_cursor(0, { 3, 0 })
    local second = success(core.branch('second'))
    success(core.jump(source))
    local point = api.nvim_win_get_cursor(core.runtime.code_window)
    success(core.branches())
    vim.cmd.stopinsert()
    local state = ui.browser_state
    equal(#state.filtered, 2)
    ui.browser_select(1)
    equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
    ui.browser_back()
    equal(#state.filtered, 3)
    ui.close_browser()
    vim.uv.fs_unlink(root .. '/sample.lua')
    assert(not core.jump(first).ok)
    equal(core.current().selected, source)
    equal(core.current().nodes[first].validity, 'invalid')
    assert(core.current().nodes[second])
    assert(api.nvim_buf_is_loaded(buf))
  end
)

test(
  'filesystem write failure preserves on-disk revision and modified notes until retry',
  function()
    fixture()
    create()
    capture(2, 0)
    success(core.note())
    local old = storage.read(core.storage.path)
    api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'Must survive EACCES' })
    local parent = vim.fs.dirname(core.storage.path)
    assert(vim.uv.fs_chmod(parent, 320))
    local failed = core.save()
    assert(vim.uv.fs_chmod(parent, 448))
    assert(not failed.ok and failed.error:find('EACCES', 1, true), failed.error)
    equal(storage.read(core.storage.path), old)
    assert(ui.notes_modified() and core.runtime.unsaved)
    success(core.save())
    assert(not ui.notes_modified())
    equal(core.current().nodes[core.current().selected].notes, 'Must survive EACCES')
  end
)

test('two real Neovim instances reject stale writes and use distinct recovery drafts', function()
  local root = fixture()
  create()
  capture(2, 0)
  success(core.save())
  local ready, output = false, ''
  local process = vim.system({
    vim.v.progpath,
    '--headless',
    '-u',
    'NONE',
    '-i',
    'NONE',
    '-l',
    'tests/stale_writer.lua',
    root,
    core.config.data_dir,
  }, {
    stdin = true,
    text = true,
    stdout = function(_, data)
      if data then
        output = output .. data
        if output:find('READY', 1, true) then
          ready = true
        end
      end
    end,
  })
  assert(
    vim.wait(5000, function()
      return ready
    end, 10),
    'Second instance failed to load'
  )
  core.current().notes = 'newer instance'
  success(core.save())
  process:write('save\n')
  process:write(nil)
  local done = process:wait(5000)
  assert(done.code == 0, done.stderr or output)
  local saved = storage.load(root, core.config.data_dir)
  equal(saved.investigations[core.current().id].notes, 'newer instance')
  equal(#storage.drafts(core.storage), 1)
end)

test(
  'startup preserves explicit configuration and native pane closure cleans/recreates safely',
  function()
    fixture()
    core.setup({ data_dir = core.config.data_dir })
    vim.o.columns = 160
    vim.g.loaded_tdlu = nil
    dofile('plugin/tdlu.lua')
    create()
    capture(2, 0)
    success(core.list())
    vim.cmd.stopinsert()
    local state = ui.browser_state
    api.nvim_win_close(state.results_win, true)
    assert(not ui.browser_state)
    local notes = ui.pane.notes_win
    api.nvim_win_close(notes, true)
    assert(vim.wait(500, function()
      return not ui.pane.trail_win
    end, 10))
    success(core.note())
    assert(api.nvim_win_is_valid(ui.pane.notes_win))
    success(core.disable())
    assert(vim.fn.exists(':TDLU') == 0)
  end
)

test('reusing a sidebar window for code restores line numbers and clears its header', function()
  for _, columns in ipairs({ 150, 70 }) do
    local root = fixture()
    file(root, 'other.lua', { 'return 7' })
    vim.o.columns = columns
    vim.wo.number = true
    vim.wo.relativenumber = true
    vim.wo.winbar = 'User header'
    vim.wo.wrap = false
    vim.wo.winfixwidth = false
    create()
    local window = ui.pane.trail_win
    api.nvim_set_current_win(window)
    vim.cmd.edit(root .. '/other.lua')
    local source = api.nvim_get_current_buf()
    equal(vim.wo.number, true)
    equal(vim.wo.relativenumber, true)
    equal(vim.wo.winbar, 'User header')
    equal(vim.wo.wrap, false)
    equal(vim.wo.winfixwidth, false)
    ui.render()
    ui.close_panel()
    assert(api.nvim_win_is_valid(window))
    equal(api.nvim_win_get_buf(window), source)
    equal(vim.wo[window].winbar, 'User header')
  end
  vim.o.columns = 80
end)

test('notes pane switches targets without note or overview commands', function()
  fixture()
  create()
  local id = capture(2, 0)
  ui.note(id)
  api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'Step evidence' })
  ui.toggle_notes()
  equal(core.current().nodes[id].notes, 'Step evidence')
  equal(ui.pane.target.id, 'overview')
  api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'Trace purpose' })
  ui.toggle_notes()
  equal(core.current().notes, 'Trace purpose')
  equal(ui.pane.target.id, id)
  equal(api.nvim_buf_get_lines(ui.pane.notes_buf, 0, -1, false), { 'Step evidence' })
  local commands = require('tdlu.commands')
  for _, action in ipairs({ 'note', 'overview' }) do
    assert(not commands.dispatch({ args = action, range = 0 }).ok)
    assert(not vim.tbl_contains(commands.names, action))
  end
end)

test('Ctrl-c closes browser/sidebar and preserves notes on save failure', function()
  local _, _, source = fixture()
  create()
  local id = capture(2, 0)
  local function press(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  end
  for _, pane in ipairs({ 'prompt_win', 'results_win', 'preview_win', 'notes_preview_win' }) do
    success(core.list())
    vim.cmd.stopinsert()
    api.nvim_set_current_win(ui.browser_state[pane])
    local windows = {
      ui.browser_state.prompt_win,
      ui.browser_state.results_win,
      ui.browser_state.preview_win,
      ui.browser_state.notes_preview_win,
    }
    press(pane == 'prompt_win' and 'i<C-c>' or '<C-c>')
    assert(not ui.browser_state)
    for _, window in ipairs(windows) do
      assert(not api.nvim_win_is_valid(window))
    end
  end
  ui.note(id)
  api.nvim_buf_set_lines(ui.pane.notes_buf, 0, -1, false, { 'Keep this draft' })
  local path = core.storage.path
  core.storage.path = core.workspace().root .. '/forbidden.json'
  press('i<C-c>')
  assert(ui.pane.notes_win and api.nvim_win_is_valid(ui.pane.notes_win))
  assert(vim.bo[ui.pane.notes_buf].modified)
  core.storage.path = path
  press('<C-c>')
  assert(not ui.pane.notes_win and not ui.pane.trail_win)
  equal(core.current().nodes[id].notes, 'Keep this draft')
  ui.panel(true)
  api.nvim_set_current_win(ui.pane.trail_win)
  press('<C-c>')
  assert(not ui.pane.notes_win and not ui.pane.trail_win)
  assert(api.nvim_buf_is_valid(source))
end)

test('picker selection and backgrounds follow colorscheme changes', function()
  fixture()
  create()
  capture(2, 0)
  success(core.list())
  vim.cmd.stopinsert()
  local original = vim.g.colors_name or 'default'
  for _, scheme in ipairs({ 'default', 'habamax' }) do
    vim.cmd.colorscheme(scheme)
    local selected = api.nvim_get_hl(0, { name = 'TelescopeSelection', link = false })
    equal(selected.bg, api.nvim_get_hl(0, { name = 'Visual', link = false }).bg)
    equal(selected.fg, nil)
    assert(not selected.reverse)
    equal(
      api.nvim_get_hl(0, { name = 'TelescopeNormal', link = false }),
      api.nvim_get_hl(0, { name = 'Normal', link = false })
    )
    assert(
      vim.wo[ui.browser_state.results_win].winhighlight:find('Normal:TelescopeNormal', 1, true)
    )
    local namespace = api.nvim_get_namespaces()['tdlu-row-selection']
    local marks =
      api.nvim_buf_get_extmarks(ui.browser_state.results_buf, namespace, 0, -1, { details = true })
    equal(#marks, 1)
    assert(marks[1][4].hl_eol)
  end
  core.config.follow_colorscheme = false
  api.nvim_set_hl(0, 'TelescopeSelection', { bg = 0x123456 })
  api.nvim_exec_autocmds('ColorScheme', {})
  equal(api.nvim_get_hl(0, { name = 'TelescopeSelection', link = false }).bg, 0x123456)
  core.config.follow_colorscheme = true
  vim.cmd.colorscheme(original)
end)

test(
  'split previews keep source syntax and Markdown notes separate without row snippets',
  function()
    for _, columns in ipairs({ 150, 70 }) do
      local _, _, source = fixture({ 'local function sample()', '  return 42', 'end' })
      vim.o.columns, vim.o.lines = columns, 40
      vim.cmd('syntax enable')
      create()
      local id = capture(2, 2)
      core.current().nodes[id].notes = '# Independent notes\n\nExplanation stays here.'
      local point = api.nvim_win_get_cursor(core.runtime.code_window)
      local route = model.copy(core.current().route)
      success(core.locations())
      vim.cmd.stopinsert()
      local state = assert(ui.browser_state)
      assert(not state.filtered[1].text:find('Independent notes', 1, true))
      assert(state.filtered[1].search:find('Independent notes', 1, true))
      equal(
        api.nvim_buf_get_lines(state.preview_buf, 0, -1, false),
        api.nvim_buf_get_lines(source, 0, -1, false)
      )
      equal(
        api.nvim_buf_get_lines(state.notes_preview_buf, 0, -1, false),
        { '# Independent notes', '', 'Explanation stays here.' }
      )
      equal(vim.bo[state.preview_buf].filetype, 'lua')
      assert(
        vim.bo[state.preview_buf].syntax == 'lua'
          or vim.treesitter.highlighter.active[state.preview_buf]
      )
      equal(vim.bo[state.notes_preview_buf].filetype, 'markdown')
      local syntax = api.nvim_win_call(state.preview_win, function()
        return vim.fn.synIDattr(vim.fn.synID(1, 1, 1), 'name')
      end)
      local captures = vim.treesitter.highlighter.active[state.preview_buf]
          and vim.treesitter.get_captures_at_pos(state.preview_buf, 0, 0)
        or {}
      assert(syntax ~= '' or #captures > 0, 'Source code has no syntax highlighting')
      local code_config, notes_config =
        api.nvim_win_get_config(state.preview_win), api.nvim_win_get_config(state.notes_preview_win)
      equal(code_config.col, notes_config.col)
      assert(notes_config.row > code_config.row + code_config.height)
      if columns == 150 then
        local results = api.nvim_win_get_config(state.results_win)
        assert(code_config.col > results.col + results.width)
      end
      assert(vim.wo[state.notes_preview_win].linebreak)
      equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
      equal(core.current().route, route)
      ui.close_browser()
      assert(not api.nvim_buf_is_valid(state.preview_buf))
      assert(not api.nvim_buf_is_valid(state.notes_preview_buf))
    end
  end
)

test('search letters remain text; Tab enables contextual deletion; slash resumes search', function()
  fixture()
  local target_id = create('Browsable trace').id
  local first = capture(2, 0, 'dri alpha')
  local second = capture(4, 0, 'dri beta')
  local active_id = create('Active trace').id
  local active_node = capture(2, 3, 'Active source')
  local point = api.nvim_win_get_cursor(core.runtime.code_window)
  success(core.locations(target_id))
  vim.cmd.stopinsert()
  local state = ui.browser_state
  local function footer()
    local chunks = api.nvim_win_get_config(state.results_win).footer
    if type(chunks) == 'string' then
      return chunks
    end
    local text = {}
    for _, chunk in ipairs(chunks) do
      text[#text + 1] = chunk[1]
    end
    return table.concat(text)
  end
  local function press(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  end
  press([=[id<C-\><C-n>]=])
  ui.browser_render()
  equal(state.query, 'd')
  assert(core.workspace().investigations[target_id].nodes[first])
  equal(#core.workspace().investigations[target_id].primary, 2)
  assert(footer():find('SEARCH', 1, true))
  press('<Tab><Down>')
  equal(state.mode, 'actions')
  equal(api.nvim_get_current_win(), state.results_win)
  equal(state.filtered[state.selected].id, second)
  assert(footer():find('d delete', 1, true))
  press('d')
  assert(not core.workspace().investigations[target_id].nodes[second])
  equal(#state.filtered, 1)
  equal(core.runtime.active, active_id)
  equal(core.current().selected, active_node)
  equal(api.nvim_win_get_cursor(core.runtime.code_window), point)
  press([=[/ri<C-\><C-n>]=])
  ui.browser_render()
  equal(state.query, 'dri')
  equal(state.mode, 'search')
  equal(api.nvim_get_current_win(), state.prompt_win)
  assert(core.workspace().investigations[target_id].nodes[first].validity ~= 'invalid')
  assert(footer():find('SEARCH', 1, true))
  success(core.undo())
  assert(core.workspace().investigations[target_id].nodes[second])
  equal(core.runtime.active, active_id)
  press('<C-c>')
  assert(not ui.browser_state)
end)

test('empty trace deletion supports cancellation and undo from the browser', function()
  local _, _, source = fixture()
  local id = create('Empty trace').id
  core.current().notes = 'Keep this purpose on undo'
  success(core.save())
  success(core.locations())
  vim.cmd.stopinsert()
  local state = ui.browser_state
  equal(#state.filtered, 0)
  assert(
    table
      .concat(api.nvim_buf_get_lines(state.preview_buf, 0, -1, false), '\n')
      :find('Backspace', 1, true)
  )
  equal(
    api.nvim_buf_get_lines(state.notes_preview_buf, 0, -1, false),
    { 'Keep this purpose on undo' }
  )
  local function press(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  end
  press('<Tab>')
  equal(api.nvim_get_current_win(), state.results_win)
  vim.ui.select = function(_, _, callback)
    callback('Cancel')
  end
  press('d')
  assert(core.workspace().investigations[id])
  equal(state.inv_id, id)
  vim.ui.select = function(_, _, callback)
    callback('Delete trace')
  end
  press('d')
  assert(not core.workspace().investigations[id])
  equal(#state.filtered, 0)
  assert(api.nvim_buf_is_valid(source))
  success(core.undo())
  equal(core.workspace().investigations[id].notes, 'Keep this purpose on undo')
  equal(#state.filtered, 1)
  equal(state.filtered[1].inv_id, id)
end)

test('capture names are optional, cancellable, pinned to capture, and editable by ID', function()
  fixture()
  local code_window = api.nvim_get_current_win()
  create('Naming')
  api.nvim_set_current_win(code_window)
  api.nvim_win_set_cursor(0, { 2, 6 })
  local pending
  vim.ui.input = function(_, callback)
    pending = callback
  end
  vim.cmd('TDLU add')
  equal(#core.current().primary, 0)
  api.nvim_win_set_cursor(0, { 4, 0 })
  pending('Registration')
  local inv = core.current()
  local id = inv.primary[1]
  equal(inv.nodes[id].title, 'Registration')
  equal(inv.nodes[id].anchor.spans[1].start_row, 1)
  equal(inv.nodes[id].anchor.spans[1].start_col, 6)
  vim.cmd('TDLU add')
  pending('')
  equal(#core.current().primary, 2)
  equal(core.current().nodes[core.current().primary[2]].title, '')
  vim.cmd('TDLU add')
  pending(nil)
  equal(#core.current().primary, 2)
  success(core.title('Renamed', id))
  equal(core.current().nodes[id].title, 'Renamed')
  success(core.undo())
  equal(core.current().nodes[id].title, 'Registration')
  success(core.title('', id))
  equal(core.current().nodes[id].title, '')
  success(core.save())
  local investigation_id = core.current().id
  success(core.reload())
  equal(core.workspace().investigations[investigation_id].nodes[id].title, '')
end)

if vim.env.TDLU_AUTOPAIRS_PATH then
  test(
    'legacy AutoPairs leaves browser mappings intact and still initializes Markdown notes',
    function()
      fixture()
      vim.cmd.source(vim.env.TDLU_AUTOPAIRS_PATH)
      -- Exercise the public command, including BufEnter in the initially unfocused
      -- floats. Previously this threw E716 while AutoPairs inspected Lua <CR>.
      vim.v.errmsg = ''
      vim.cmd('TDLU')
      vim.cmd.stopinsert()
      local state = assert(ui.browser_state)
      equal(vim.v.errmsg, '')
      for _, window in ipairs({
        state.prompt_win,
        state.results_win,
        state.preview_win,
        state.notes_preview_win,
      }) do
        api.nvim_set_current_win(window)
        local mapping = api.nvim_buf_get_keymap(api.nvim_win_get_buf(window), 'i')
        local enter
        for _, item in ipairs(mapping) do
          if item.lhs == '<CR>' then
            enter = item
          end
        end
        assert(enter and type(enter.callback) == 'function')
      end
      equal(vim.v.errmsg, '')
      ui.close_browser()
      create()
      capture(2, 0)
      success(core.note())
      assert(vim.b[ui.pane.notes_buf].autopairs_loaded == 1)
      local pairs = vim.fn.maparg('(', 'i', false, true)
      assert(pairs.rhs and pairs.rhs:find('AutoPairsInsert', 1, true))
    end
  )
end

reset()
for _, root in ipairs(roots) do
  local status = vim.system({ 'git', '-C', root, 'status', '--porcelain' }, { text = true }):wait()
  assert(not status.stdout:find('tdlu', 1, true), 'Plugin artifacts leaked into source workspace')
  assert(not vim.uv.fs_stat(root .. '/.gitignore'), 'Plugin modified ignore files')
end
vim.fn.delete(base, 'rf')
if #failures > 0 then
  print(table.concat(failures, '\n'))
  vim.cmd('cquit 1')
end
print(count .. ' integration tests passed')
vim.cmd('qa!')
