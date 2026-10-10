local model = require('tdlu.model')
local uv = vim.uv
local M = { known = {} }
local function git(root, args)
  if vim.fn.executable('git') ~= 1 then
    return nil
  end
  local command = { 'git', '-C', root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or nil
end
M.git = git
function M.canonical(path)
  path = vim.fn.expand(path)
  if path:sub(1, 1) ~= '/' then
    path = uv.cwd() .. '/' .. path
  end
  local current = '/'
  for component in path:gmatch('[^/]+') do
    if component == '..' then
      current = vim.fs.dirname(current)
    elseif component ~= '.' then
      current = (current == '/' and '' or current) .. '/' .. component
      current = uv.fs_realpath(current) or current
    end
  end
  return current
end
local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end
M.inside = inside
function M.root(file)
  local directory = file and file ~= '' and vim.fs.dirname(M.canonical(file)) or uv.cwd()
  return M.canonical(git(directory, { 'rev-parse', '--show-toplevel' }) or directory)
end
function M.boundaries(root)
  if M.known[root] then
    return M.known[root]
  end
  local result = { M.canonical(root) }
  local worktrees = git(root, { 'worktree', 'list', '--porcelain' }) or ''
  for path in worktrees:gmatch('worktree ([^\n]+)') do
    result[#result + 1] = M.canonical(path)
  end
  local common = git(root, { 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  if common then
    result[#result + 1] = M.canonical(common)
  end
  local metadata = git(root, { 'rev-parse', '--absolute-git-dir' })
  if metadata then
    result[#result + 1] = M.canonical(metadata)
  end
  M.known[root] = result
  return result
end
function M.external(path, root)
  local resolved = M.canonical(path)
  for _, boundary in ipairs(M.boundaries(root)) do
    assert(
      not inside(resolved, boundary),
      'Choose a directory outside the workspace and all Git worktrees: ' .. resolved
    )
  end
  -- Also disallow placing plugin state in a different repository.
  local ancestor = resolved
  while not uv.fs_stat(ancestor) do
    ancestor = vim.fs.dirname(ancestor)
  end
  if uv.fs_stat(ancestor).type ~= 'directory' then
    ancestor = vim.fs.dirname(ancestor)
  end
  local probe = ancestor
  while probe do
    assert(
      not uv.fs_stat(probe .. '/.git'),
      'Plugin files cannot be stored inside a Git repository'
    )
    assert(
      not (uv.fs_stat(probe .. '/HEAD') and uv.fs_stat(probe .. '/objects')),
      'Plugin files cannot be stored in Git metadata'
    )
    local parent = vim.fs.dirname(probe)
    if parent == probe then
      break
    end
    probe = parent
  end
  for component in resolved:gmatch('[^/]+') do
    assert(component ~= '.git', 'Plugin files cannot be stored in Git metadata')
  end
  return resolved
end
local function read(path)
  local descriptor, reason = uv.fs_open(path, 'r', 384)
  if not descriptor then
    if not uv.fs_stat(path) and tostring(reason):find('ENOENT', 1, true) then
      return nil
    end
    error('Cannot read saved trace: ' .. tostring(reason))
  end
  local stat = assert(uv.fs_fstat(descriptor))
  local value, err = uv.fs_read(descriptor, stat.size, 0)
  uv.fs_close(descriptor)
  assert(value, err)
  return value
end
M.read = read
function M.atomic(path, content, root)
  path = M.external(path, root)
  vim.fn.mkdir(vim.fs.dirname(path), 'p', 448)
  M.external(path, root)
  local temporary = path .. '.tmp-' .. model.id()
  M.external(temporary, root)
  local descriptor, err = uv.fs_open(temporary, 'wx', 384)
  assert(descriptor, err)
  local ok, reason = pcall(function()
    local offset = 0
    while offset < #content do
      local written = assert(uv.fs_write(descriptor, content:sub(offset + 1), offset))
      assert(written > 0, 'Short filesystem write')
      offset = offset + written
    end
    assert(uv.fs_fsync(descriptor))
  end)
  uv.fs_close(descriptor)
  if not ok then
    uv.fs_unlink(temporary)
    error(reason)
  end
  M.external(path, root)
  M.external(temporary, root)
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    uv.fs_unlink(temporary)
    error(rename_err)
  end
  -- Best effort directory fsync; some platforms do not support it.
  local directory = uv.fs_open(vim.fs.dirname(path), 'r', 384)
  if directory then
    uv.fs_fsync(directory)
    uv.fs_close(directory)
  end
end
local function decode(content)
  local value = vim.json.decode(content)
  assert(type(value) == 'table' and type(value.schema_version) == 'number', 'Invalid schema')
  if value.schema_version <= model.schema then
    model.validate(value)
  end
  return value
end
function M.load(root, directory)
  local data = M.external(directory or (vim.fn.stdpath('data') .. '/tdlu'), root)
  local path = data .. '/workspaces/' .. vim.fn.sha256(M.canonical(root)) .. '.json'
  M.external(path, root)
  local state = { directory = data, path = path, root = root, writer = model.id() }
  local content = read(path)
  if not content then
    return model.workspace(root), state
  end
  local ok, workspace = pcall(decode, content)
  if not ok then
    state.readonly, state.corrupt = true, tostring(workspace)
    local backup = read(path .. '.bak')
    local valid, recovered = pcall(decode, backup or '')
    state.recovery = valid and recovered or nil
    return model.workspace(root), state
  end
  state.readonly = workspace.schema_version > model.schema
  assert(M.canonical(workspace.root) == M.canonical(root), 'Workspace root changed; use relink')
  return workspace, state
end
function M.lock(state)
  local path = M.external(state.path .. '.lock', state.root)
  vim.fn.mkdir(vim.fs.dirname(path), 'p', 448)
  local descriptor, err = uv.fs_open(path, 'wx', 384)
  if not descriptor then
    local content = read(path)
    local ok, lock = pcall(vim.json.decode, content or '')
    if
      ok
      and type(lock) == 'table'
      and lock.host == uv.os_gethostname()
      and type(lock.pid) == 'number'
    then
      local alive, kill_err = uv.kill(lock.pid, 0)
      if not alive and tostring(kill_err):find('ESRCH', 1, true) and read(path) == content then
        assert(uv.fs_unlink(path))
        descriptor, err = uv.fs_open(path, 'wx', 384)
      end
    end
  end
  assert(
    descriptor,
    'Workspace is locked by another instance; retry save after it finishes ('
      .. tostring(err)
      .. ')'
  )
  local content = vim.json.encode({
    pid = uv.os_getpid(),
    host = uv.os_gethostname(),
    writer = state.writer,
    created_at = os.time(),
  })
  local written, write_error = uv.fs_write(descriptor, content, 0)
  uv.fs_close(descriptor)
  if not written or written ~= #content then
    uv.fs_unlink(path)
    error('Cannot create workspace write lock: ' .. tostring(write_error or 'short write'))
  end
  return function()
    local current = read(path)
    local ok, value = pcall(vim.json.decode, current or '')
    if ok and value.writer == state.writer then
      uv.fs_unlink(path)
    end
  end
end
function M.save(workspace, state)
  assert(
    not state.readonly,
    state.corrupt and 'Corrupt state retained. Use :TDLU recover to restore the prior snapshot.'
      or 'Newer schema is read-only'
  )
  model.validate(workspace)
  local unlock = M.lock(state)
  local ok, err = pcall(function()
    local old = read(state.path)
    local revision = old and decode(old).revision or 0
    assert(
      revision == workspace.revision,
      'Save conflict: newer data preserved. Use reload or save-copy; your draft remains available.'
    )
    local candidate = model.copy(workspace)
    candidate.revision = revision + 1
    if old then
      M.atomic(state.path .. '.bak', old, state.root)
    end
    M.atomic(state.path, vim.json.encode(candidate), state.root)
    workspace.revision = candidate.revision
    local draft = M.external(state.path .. '.draft-' .. state.writer .. '.json', state.root)
    if uv.fs_stat(draft) then
      uv.fs_unlink(draft)
    end
  end)
  unlock()
  assert(ok, err)
end
function M.draft(workspace, state)
  assert(not state.readonly, 'Read-only workspace')
  M.atomic(
    state.path .. '.draft-' .. state.writer .. '.json',
    vim.json.encode(workspace),
    state.root
  )
end
function M.drafts(state)
  return vim.fn.glob(state.path .. '.draft-*.json', false, true)
end
function M.recover(state)
  assert(state.recovery, 'No valid recovery snapshot')
  local unlock = M.lock(state)
  local ok, err = pcall(function()
    local corrupt = read(state.path)
    if corrupt then
      M.atomic(state.path .. '.corrupt-' .. model.id(), corrupt, state.root)
    end
    M.atomic(state.path, vim.json.encode(state.recovery), state.root)
  end)
  unlock()
  assert(ok, err)
end
function M.save_copy(workspace, state)
  local path = state.directory .. '/recovery/' .. workspace.id .. '-' .. model.id() .. '.json'
  M.atomic(path, vim.json.encode(workspace), state.root)
  return path
end
function M.provenance(root)
  return {
    git_revision = git(root, { 'rev-parse', 'HEAD' }),
    dirty_worktree = (git(root, { 'status', '--porcelain' }) or '') ~= '',
  }
end
return M
