-- The extension launches the same dependency-free browser, preserving the full
-- drill-down/repair/export contract instead of maintaining a second UI policy.
return require('telescope').register_extension({
  exports = {
    investigations = function(opts)
      require('tdlu').notify(require('tdlu').list(opts and opts.filter))
    end,
    locations = function(opts)
      require('tdlu').notify(require('tdlu').locations(opts and opts.name))
    end,
  },
})
