vim.opt.runtimepath:prepend(vim.fn.getcwd())
require('tdlu') -- install the runtime's random ID source
local storage = require('tdlu.storage')
local root, directory = unpack(arg)
local workspace, state = storage.load(root, directory)
io.stdout:write('READY\n')
io.stdout:flush()
assert(io.stdin:read('*l') == 'save')
local inv = workspace.investigations[next(workspace.investigations)]
inv.notes = 'stale instance'
local ok, reason = pcall(storage.save, workspace, state)
assert(not ok and tostring(reason):find('conflict', 1, true))
storage.draft(workspace, state)
vim.cmd('qa!')
