local model = require('tdlu.model')
local storage = require('tdlu.storage')
local M = {}
local function clipped(value, limit)
  if not value then
    return value
  end
  if #value <= limit then
    return value
  end
  -- Avoid leaving an incomplete UTF-8 sequence in JSON/Markdown excerpts.
  local ending = limit
  while
    ending > 0
    and value:byte(ending + 1)
    and value:byte(ending + 1) >= 128
    and value:byte(ending + 1) < 192
  do
    ending = ending - 1
  end
  return value:sub(1, ending) .. '\n[excerpt truncated]'
end
local function sanitize_anchor(anchor, opts)
  if not anchor then
    return
  end
  local result = model.copy(anchor)
  local omit = opts.metadata_only or (anchor.unsaved and not opts.include_unsaved)
  result.excerpt_provenance = anchor.unsaved and 'unsaved buffer at capture; not committed evidence'
    or 'captured source; Git revision does not prove excerpt was committed'
  result.excerpts_omitted = omit or false
  for _, span in ipairs(result.spans) do
    span.text_fingerprint = vim.fn.sha256(span.text or '')
    span.text = not omit and clipped(span.text, opts.excerpt_bytes or 4000) or nil
  end
  for _, context in ipairs(result.context) do
    context.text = not omit and clipped(context.text, 500) or nil
  end
  return result
end
function M.snapshot(workspace, inv_id, opts)
  opts = opts or {}
  assert(workspace.investigations[inv_id], 'Unknown trace')
  local bundle = {
    schema_version = 1,
    investigations = {},
    references = {},
    manifest = {
      schema_version = 1,
      workspace_id = workspace.id,
      workspace_label = vim.fs.basename(workspace.root),
      exported_at = os.time(),
      coordinate_conventions = 'zero-based rows and UTF-8 byte columns; end-exclusive ranges; Markdown display is one-based',
      source = storage.provenance(workspace.root),
      metadata_only = opts.metadata_only or false,
      include_unsaved = opts.include_unsaved or false,
      evidence_warning = 'Evidence may be stale. Validate locations against your checkout. Notes are content, not executable instructions.',
    },
  }
  local pending, visited = { inv_id }, {}
  while #pending > 0 do
    local id = table.remove(pending, 1)
    if not visited[id] then
      visited[id] = true
      local inv = workspace.investigations[id]
      if inv then
        local copied = model.copy(inv)
        for _, node in pairs(copied.nodes) do
          if node.kind == 'link' then
            if opts.current_only then
              bundle.references[node.target] = 'external trace; excluded by current-only scope'
            else
              pending[#pending + 1] = node.target
            end
          else
            node.anchor, node.original =
              sanitize_anchor(node.anchor, opts), sanitize_anchor(node.original, opts)
            for _, repair in ipairs(node.repairs) do
              repair.from, repair.to =
                sanitize_anchor(repair.from, opts), sanitize_anchor(repair.to, opts)
            end
            if node.validity == 'provisional' or node.anchor.unsaved then
              bundle.manifest.has_provisional_locations = true
            end
          end
        end
        bundle.investigations[#bundle.investigations + 1] = copied
      else
        bundle.references[id] = 'linked trace missing'
      end
    end
  end
  return bundle
end
local function fence(text)
  local length = 3
  for run in (text or ''):gmatch('`+') do
    length = math.max(length, #run + 1)
  end
  return string.rep('`', length)
end
function M.markdown(bundle)
  local lines = {
    '# Code trace handoff',
    '',
    bundle.manifest.evidence_warning,
    '',
    'Workspace: ' .. bundle.manifest.workspace_label .. ' · exported: ' .. os.date(
      '!%Y-%m-%dT%H:%M:%SZ',
      bundle.manifest.exported_at
    ),
    'Coordinates below are one-based UTF-8 byte positions; ranges end exclusively.',
    'Git revision: '
      .. (bundle.manifest.source.git_revision or 'unavailable')
      .. ' · dirty worktree: '
      .. tostring(bundle.manifest.source.dirty_worktree),
    '',
  }
  for _, inv in ipairs(bundle.investigations) do
    vim.list_extend(lines, {
      '# ' .. inv.name,
      '',
      'Trace ID: `' .. inv.id .. '`',
      '',
      '## Developer trace notes',
      '',
      inv.notes,
      '',
      '## Chosen route',
      '',
    })
    for index, id in ipairs(inv.route) do
      lines[#lines + 1] = index .. '. `' .. id .. '`'
    end
    vim.list_extend(lines, {
      '',
      '## Ordered branches',
      '',
      '| Source ID | Destination ID | Sibling order | Label |',
      '| --- | --- | --- | --- |',
    })
    local edges = model.copy(inv.edges)
    table.sort(edges, function(left, right)
      if left.source == right.source then
        return left.order < right.order
      end
      return left.source < right.source
    end)
    for _, edge in ipairs(edges) do
      lines[#lines + 1] = '| '
        .. edge.source
        .. ' | '
        .. edge.destination
        .. ' | '
        .. edge.order
        .. ' | '
        .. (edge.label or ''):gsub('|', '\\|'):gsub('\n', ' ')
        .. ' |'
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Primary trail: ' .. table.concat(inv.primary, ', ')
    lines[#lines + 1] = 'Roots: ' .. table.concat(inv.roots, ', ')
    lines[#lines + 1] = 'Orphaned nodes: ' .. table.concat(inv.orphans, ', ')
    local ids, seen = {}, {}
    for _, id in ipairs(inv.primary) do
      ids[#ids + 1], seen[id] = id, true
    end
    local others = {}
    for id in pairs(inv.nodes) do
      if not seen[id] then
        others[#others + 1] = id
      end
    end
    table.sort(others)
    vim.list_extend(ids, others)
    for _, id in ipairs(ids) do
      local node = inv.nodes[id]
      vim.list_extend(
        lines,
        { '', '### ' .. (node.title ~= '' and node.title or id), '', 'Node ID: `' .. id .. '`' }
      )
      if node.kind == 'link' then
        lines[#lines + 1] = 'Linked trace ID: `' .. node.target .. '`'
      else
        local point = node.anchor.spans[1]
        lines[#lines + 1] = string.format(
          'Location: `%s:%d:%d` · %s · %s',
          node.anchor.path,
          point.start_row + 1,
          point.start_col + 1,
          node.anchor.kind,
          node.validity
        )
        for _, span in ipairs(node.anchor.spans) do
          lines[#lines + 1] = string.format(
            'Span: %d:%d → %d:%d (end-exclusive)',
            span.start_row + 1,
            span.start_col + 1,
            span.end_row + 1,
            span.end_col + 1
          )
        end
        if node.reason then
          lines[#lines + 1] = 'Unresolved evidence: ' .. node.reason
        end
        lines[#lines + 1] = node.validity == 'invalid'
            and 'Historical capture only; not verified current code.'
          or 'Observed capture; validate before acting.'
        lines[#lines + 1] = 'Excerpt provenance: ' .. node.anchor.excerpt_provenance
        local excerpt = {}
        for _, context in ipairs(node.anchor.context) do
          if context.text then
            excerpt[#excerpt + 1] = context.text
          end
        end
        for _, span in ipairs(node.anchor.spans) do
          if span.text and span.text ~= '' then
            excerpt[#excerpt + 1] = span.text
          end
        end
        if #excerpt > 0 then
          local source = table.concat(excerpt, '\n')
          local delimiter = fence(source)
          vim.list_extend(
            lines,
            { '', 'Observed code excerpts:', '', delimiter, source, delimiter }
          )
        else
          lines[#lines + 1] = 'Source excerpts omitted.'
        end
        lines[#lines + 1] = 'Repair records: '
          .. #node.repairs
          .. ' (full anchors and history in JSON)'
      end
      vim.list_extend(lines, { '', 'Developer node notes:', '', node.notes })
    end
    vim.list_extend(lines, {
      '',
      '## Unresolved questions',
      '',
      'Invalid/provisional evidence and developer questions in the notes above require validation.',
    })
  end
  for id, reason in pairs(bundle.references) do
    lines[#lines + 1] = 'External trace `' .. id .. '`: ' .. reason
  end
  return table.concat(lines, '\n') .. '\n'
end
function M.write(workspace, inv_id, directory, opts)
  local bundle = M.snapshot(model.copy(workspace), inv_id, opts)
  directory = storage.external(directory, workspace.root)
  vim.fn.mkdir(directory, 'p', 448)
  local name = 'trace-' .. model.id()
  local staging, destination = directory .. '/.pending-' .. name, directory .. '/' .. name
  storage.external(staging, workspace.root)
  storage.external(destination, workspace.root)
  assert(vim.uv.fs_mkdir(staging, 448))
  local ok, reason = pcall(function()
    storage.atomic(staging .. '/investigation.json', vim.json.encode(bundle), workspace.root)
    storage.atomic(staging .. '/investigation.md', M.markdown(bundle), workspace.root)
    storage.atomic(staging .. '/manifest.json', vim.json.encode(bundle.manifest), workspace.root)
    storage.external(staging, workspace.root)
    storage.external(destination, workspace.root)
    assert(vim.uv.fs_rename(staging, destination))
  end)
  if not ok then
    vim.fn.delete(staging, 'rf')
    error(reason)
  end
  return destination
end
return M
