# Terminal verification

Use an external test repository, not a valuable investigation. Test Neovim 0.11+
with `nvim -u NONE -i NONE --cmd 'set rtp+=/path/to/tdlu.nvim'`.

1. Wide terminal: create an investigation, add five points across three files,
   and type multiline notes. Browse sidebar rows without changing draft target.
   Observe header and statusline when browsing off-trail, then previous/next.
2. Create three destinations from a pinned source. Verify sibling cards and
   vertical fallback, Left/Right without jump, Enter/Up, route switching, and
   branch-depth vs node-count display. Test keyboard with mouse disabled.
3. Browser: fuzzy query, Ctrl-n/p, Enter drill/location jump, Backspace restores
   query and selection, invalid historical preview, r/i in results, literal
   r/i in insert-mode search. With `set mouse=a`, click selects, double-click opens.
4. Resize to 70 columns. Toggle pane-view between editable wrapped notes and
   trail. Confirm browser preview is stacked vertically and key hints readable.
5. Modify a source buffer and close its window. Jump and confirm no edits lost.
   Capture character/line/block selections including UTF-8, tabs and short lines.
6. Detach a primary segment with descendants. Review every transferred ID,
   cancel once, confirm once, follow link, back, undo/redo. Reopen after restart.
7. External edit: delete/duplicate anchor, inspect invalid reason, preview repair
   candidates, reattach, bypass/reparent, undo. Keep invalid descendants browseable.
8. Use two instances at the same root. Change notes in both: newer save wins,
   stale save reports conflict. Inspect save-copy/draft recovery. Simulate disk
   write failure; verify modified notes retained. Kill an instance and recover.
9. Export metadata-only and unsaved-buffer variants. Check bounded excerpts,
   stable IDs, linked investigations, relative paths and provenance. Run git
   status and inspect ignore/config/index: no plugin artifacts or changes.
