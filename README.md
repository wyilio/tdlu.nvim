# tdlu.nvim

## What this is

TDLU is a Neovim plugin inspired by Mitchell Hashimoto's concept of [Trace Down, Learn Up](https://mitchellh.com/writing/contributing-to-complex-projects#trace-down:~:text=down%2C%20learn%20up.%E2%80%9D-,Trace%20Down,-I%20start%20with). 

The plugin allows you to save down a list of revisitable code locations as you trace down the code and write exportable markdown notes as you learn up.

## Install

### vim-plug

Add this line inside `plug#begin()` / `plug#end()`:

```vim
Plug 'wyilio/tdlu.nvim'
```

Then, after `call plug#end()`:

```vim
lua << EOF
require('tdlu').setup({
  side = 'right',
  width = 48,
  -- data_dir = '/Users/you/tdlu-data', -- optional; defaults to stdpath('data')/tdlu
})
EOF
```

Restart Neovim and run `:PlugInstall`.

TDLU stores all traces, drafts, locks, and exports **outside your
repositories**, by default under `stdpath('data')/tdlu`. Set `data_dir` to an
absolute path to move it; it must resolve outside any Git repository or
worktree.

## Basic commands

| Command | Action |
| --- | --- |
| `:TDLU new [name]` | Create and activate a named trace. |
| `:TDLU list [active\|archived\|all]` | Browse saved traces. |
| `:TDLU open [name]` | Resume a trace at its saved selection. |
| `:TDLU add [title]` | Append the cursor position or visual selection as a step. |
| `:TDLU previous` | Jump to the previous step on the chosen route. |
| `:TDLU next` | Jump to the next step on the chosen route. |
| `:TDLU jump [index]` | Jump to a route index, node ID, or active entry. |
| `:TDLU panel` | Show or hide the docked trail and notes sidebar. |
| `:TDLU save` | Flush trace state, anchors, and notes to disk. |

## Suggested mappings

TDLU sets no global mappings; add your own. For example:

```vim
nnoremap <leader>tl <Cmd>TDLU list<CR>
nnoremap <leader>tp <Cmd>TDLU panel<CR>
nnoremap <leader>ta <Cmd>TDLU add<CR>
nnoremap <leader>tb <Cmd>TDLU branches<CR>
xnoremap <leader>ta :TDLU add<CR>
```

## Disclaimer

This initial prototype is heavily vibe-coded. Use at your own peril.

## License

MIT — see [LICENSE](LICENSE).
