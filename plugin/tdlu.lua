if vim.g.loaded_tdlu then
  return
end
vim.g.loaded_tdlu = true
local tdlu = require('tdlu')
if not tdlu.is_setup then
  tdlu.setup()
end
