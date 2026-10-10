local model = require('tdlu.model')
local storage = require('tdlu.storage')
local M = { namespace = vim.api.nvim_create_namespace('tdlu-anchors'), handles = {} }
local api = vim.api
local file_state = {}
local function file_signature(stat)
  if not stat then
    return nil
  end
  return string.format('%d:%d:%d', stat.mtime.sec, stat.mtime.nsec, stat.size)
end
local function next_byte(line, column)
  if column >= #line then
    return #line
  end
  local byte = line:byte(column + 1)
  local length = byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4
  return math.min(#line, column + length)
end
local function text(lines, span)
  if not lines[span.start_row + 1] or not lines[span.end_row + 1] then
    return nil
  end
  if span.start_col > #lines[span.start_row + 1] or span.end_col > #lines[span.end_row + 1] then
    return nil
  end
  if span.start_row == span.end_row then
    return lines[span.start_row + 1]:sub(span.start_col + 1, span.end_col)
  end
  local result = { lines[span.start_row + 1]:sub(span.start_col + 1) }
  for row = span.start_row + 1, span.end_row - 1 do
    result[#result + 1] = lines[row + 1]
  end
  result[#result + 1] = lines[span.end_row + 1]:sub(1, span.end_col)
  return table.concat(result, '\n')
end
M.text = text
local function evidence(lines, anchor)
  local start = anchor.spans[1].start_row
  anchor.context = {}
  for row = math.max(0, start - 2), math.min(#lines - 1, start + 2) do
    anchor.context[#anchor.context + 1] = { offset = row - start, text = lines[row + 1] }
  end
end
function M.capture(root, opts)
  opts = opts or {}
  local buffer = api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buffer)
  assert(vim.bo[buffer].buftype == '', 'Capture from a normal named source buffer')
  assert(name ~= '', 'Write this unnamed buffer to a file before capturing')
  name = storage.canonical(name)
  assert(
    storage.inside(name, root) and name ~= root,
    'External files are unsupported; capture a file inside the workspace'
  )
  local lines = api.nvim_buf_get_lines(buffer, 0, -1, false)
  local point = api.nvim_win_get_cursor(0)
  local start, finish = { point[1] - 1, point[2] }, { point[1] - 1, point[2] }
  local kind, virtual_start, virtual_end = 'point'
  if opts.visual then
    local mode = vim.fn.mode()
    local live = mode == 'v' or mode == 'V' or mode == '\22'
    kind = live and mode or vim.fn.visualmode()
    local first = live and vim.fn.getpos('v') or vim.fn.getpos("'<")
    local last = live and vim.fn.getpos('.') or vim.fn.getpos("'>")
    assert(first[2] > 0 and last[2] > 0, 'Select a visual range before capturing')
    start, finish =
      { first[2] - 1, math.max(0, first[3] - 1) }, { last[2] - 1, math.max(0, last[3] - 1) }
    virtual_start = vim.fn.virtcol(live and 'v' or "'<")
    virtual_end = vim.fn.virtcol(live and '.' or "'>")
    if start[1] > finish[1] or (start[1] == finish[1] and start[2] > finish[2]) then
      start, finish = finish, start
    end
  end
  local spans = {}
  if kind == '\22' then
    local left, right = math.min(virtual_start, virtual_end), math.max(virtual_start, virtual_end)
    for row = start[1], finish[1] do
      local line = lines[row + 1]
      local first = math.max(0, vim.fn.virtcol2col(0, row + 1, left) - 1)
      local last = math.max(0, vim.fn.virtcol2col(0, row + 1, right) - 1)
      if left > vim.fn.strdisplaywidth(line) then
        first = #line
      end
      if right > vim.fn.strdisplaywidth(line) then
        last = #line
      end
      spans[#spans + 1] =
        { start_row = row, start_col = first, end_row = row, end_col = next_byte(line, last) }
    end
    kind = 'block'
  else
    if kind == 'V' then
      start[2], finish[2], kind = 0, #lines[finish[1] + 1], 'line'
    elseif kind == 'v' then
      finish[2] = math.min(finish[2], #lines[finish[1] + 1])
      if vim.o.selection ~= 'exclusive' then
        finish[2] = next_byte(lines[finish[1] + 1], finish[2])
      end
      kind = 'character'
    else
      finish[2] = next_byte(lines[finish[1] + 1], finish[2])
    end
    start[2] = math.min(start[2], #lines[start[1] + 1])
    spans[1] =
      { start_row = start[1], start_col = start[2], end_row = finish[1], end_col = finish[2] }
  end
  for _, span in ipairs(spans) do
    span.text = assert(text(lines, span))
  end
  local anchor = {
    path = name:sub(#root + 2),
    kind = kind,
    spans = spans,
    captured_at = os.time(),
    unsaved = vim.bo[buffer].modified,
  }
  evidence(lines, anchor)
  anchor.fingerprint = vim.fn.sha256(table.concat(lines, '\n'))
  anchor.git_revision = storage.git(root, { 'rev-parse', 'HEAD' })
  return {
    id = model.id(),
    kind = 'location',
    title = opts.title or '',
    anchor = anchor,
    original = model.copy(anchor),
    notes = '',
    validity = anchor.unsaved and 'provisional' or 'valid',
    repairs = {},
    created_at = os.time(),
    updated_at = os.time(),
  },
    buffer
end
function M.track(node, buffer)
  local previous = M.handles[node.id]
  if previous and api.nvim_buf_is_valid(previous.buffer) then
    for _, mark in ipairs(previous.marks) do
      pcall(api.nvim_buf_del_extmark, previous.buffer, M.namespace, mark)
    end
  end
  local handles = { buffer = buffer, marks = {} }
  for _, span in ipairs(node.anchor.spans) do
    handles.marks[#handles.marks + 1] =
      api.nvim_buf_set_extmark(buffer, M.namespace, span.start_row, span.start_col, {
        end_row = span.end_row,
        end_col = span.end_col,
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
        strict = false,
      })
  end
  M.handles[node.id] = handles
end
function M.position(node)
  local handles = M.handles[node.id]
  if
    not handles
    or not api.nvim_buf_is_valid(handles.buffer)
    or not api.nvim_buf_is_loaded(handles.buffer)
  then
    return
  end
  local candidate = model.copy(node.anchor)
  for index, mark in ipairs(handles.marks) do
    local location =
      api.nvim_buf_get_extmark_by_id(handles.buffer, M.namespace, mark, { details = true })
    if #location == 0 or location[3].invalid then
      return nil, 'deleted range'
    end
    local span = candidate.spans[index]
    span.start_row, span.start_col = location[1], location[2]
    span.end_row, span.end_col = location[3].end_row, location[3].end_col
  end
  candidate.unsaved = vim.bo[handles.buffer].modified
  return candidate, nil, handles.buffer
end
function M.matches(lines, anchor)
  for _, span in ipairs(anchor.spans) do
    if text(lines, span) ~= span.text then
      return false
    end
  end
  local first_row = anchor.spans[1].start_row
  for _, context in ipairs(anchor.context) do
    if lines[first_row + context.offset + 1] ~= context.text then
      return false
    end
  end
  return #anchor.context > 0
end
function M.shift(anchor, offset)
  local candidate = model.copy(anchor)
  for _, span in ipairs(candidate.spans) do
    span.start_row, span.end_row = span.start_row + offset, span.end_row + offset
  end
  return candidate
end
function M.candidates(lines, anchor)
  local result, seen = {}, {}
  local function inspect(row)
    if row < 0 or row >= #lines or seen[row] then
      return
    end
    seen[row] = true
    local candidate = M.shift(anchor, row - anchor.spans[1].start_row)
    if M.matches(lines, candidate) then
      result[#result + 1] = candidate
    end
  end
  local start = anchor.spans[1].start_row
  for row = math.max(0, start - 80), math.min(#lines - 1, start + 80) do
    inspect(row)
  end
  -- Scan the rest too: a nearby match must not hide a duplicate elsewhere.
  for row = 0, #lines - 1 do
    inspect(row)
  end
  return result
end
function M.buffer(root, anchor)
  local path = storage.canonical(root .. '/' .. anchor.path)
  assert(storage.inside(path, root), 'Anchor path escapes the workspace through a symlink')
  local buffer = vim.fn.bufnr(path)
  local stat = vim.uv.fs_stat(path)
  if buffer >= 0 and api.nvim_buf_is_loaded(buffer) then
    assert((stat and stat.type == 'file') or vim.bo[buffer].modified, 'missing file')
    if stat and not vim.bo[buffer].modified then
      -- Only re-read and compare the file when its on-disk signature changed.
      local current = file_signature(stat)
      if file_state[path] ~= current then
        api.nvim_buf_call(buffer, function()
          vim.cmd('checktime ' .. buffer)
        end)
        local disk = vim.fn.readfile(path)
        assert(
          vim.deep_equal(disk, api.nvim_buf_get_lines(buffer, 0, -1, false)),
          'Source changed externally; reload the buffer before resolving this node'
        )
        file_state[path] = current
      end
    end
    return buffer
  end
  assert(stat and stat.type == 'file', 'missing file')
  buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  assert(api.nvim_buf_is_loaded(buffer), 'Cannot load source file')
  file_state[path] = file_signature(vim.uv.fs_stat(path))
  return buffer
end
function M.resolve(root, node, preview)
  assert(node.kind == 'location', 'Link entries have no code anchor')
  if node.validity == 'invalid' and node.manual_invalid then
    return nil, node.reason or 'manual invalidation'
  end
  local ok, buffer = pcall(M.buffer, root, node.anchor)
  if not ok then
    node.validity, node.reason = 'invalid', tostring(buffer)
    return nil, node.reason
  end
  local lines = api.nvim_buf_get_lines(buffer, 0, -1, false)
  local tracked, track_error = M.position(node)
  if track_error then
    node.validity, node.reason = 'invalid', track_error
    return nil, track_error
  end
  local candidate = tracked or node.anchor
  if not M.matches(lines, candidate) then
    local matches = M.candidates(lines, node.anchor)
    if #matches ~= 1 then
      node.validity, node.reason =
        'invalid', #matches > 1 and 'ambiguous relocation' or 'content mismatch or deleted range'
      return nil, node.reason, matches
    end
    candidate = matches[1]
    node.repairs[#node.repairs + 1] = {
      at = os.time(),
      kind = 'conservative relocation',
      from = model.copy(node.anchor),
      to = model.copy(candidate),
    }
  end
  candidate.unsaved = vim.bo[buffer].modified
  node.anchor, node.reason, node.validity =
    candidate, nil, candidate.unsaved and 'provisional' or 'valid'
  if not preview then
    M.track(node, buffer)
  end
  return buffer, candidate
end
function M.sync(workspace, buffer)
  for _, inv in pairs(workspace.investigations) do
    for id, node in pairs(inv.nodes) do
      local handles = M.handles[id]
      if
        node.kind == 'location'
        and handles
        and (not buffer or handles.buffer == buffer)
        and not node.manual_invalid
      then
        M.resolve(workspace.root, node)
      end
    end
  end
end
function M.reattach(node, captured, buffer)
  assert(
    M.matches(api.nvim_buf_get_lines(buffer, 0, -1, false), captured.anchor),
    'Repair verification failed'
  )
  node.repairs[#node.repairs + 1] = {
    at = os.time(),
    kind = 'manual reattachment',
    from = model.copy(node.anchor),
    to = model.copy(captured.anchor),
  }
  node.anchor, node.validity, node.reason, node.manual_invalid =
    captured.anchor, captured.validity, nil, nil
  M.track(node, buffer)
end
function M.prune(workspace)
  local owned = {}
  for _, inv in pairs(workspace.investigations) do
    for id in pairs(inv.nodes) do
      owned[id] = true
    end
  end
  for id, handles in pairs(M.handles) do
    if not owned[id] then
      if api.nvim_buf_is_valid(handles.buffer) then
        for _, mark in ipairs(handles.marks) do
          pcall(api.nvim_buf_del_extmark, handles.buffer, M.namespace, mark)
        end
      end
      M.handles[id] = nil
    end
  end
end
function M.reset()
  for _, handles in pairs(M.handles) do
    if api.nvim_buf_is_valid(handles.buffer) then
      for _, mark in ipairs(handles.marks) do
        pcall(api.nvim_buf_del_extmark, handles.buffer, M.namespace, mark)
      end
    end
  end
  M.handles = {}
  file_state = {}
end
return M
