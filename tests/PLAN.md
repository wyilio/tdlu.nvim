# Acceptance coverage

- Pure model: navigation preserves order/notes; append retains forward route; branch selection retains siblings; cycle/shared ownership rejected; reordering keeps IDs; detach transfers descendants and undo/redo restores ownership; bypass retains orphan and branches.
- Headless Neovim: exact UTF-8 point and three visual kinds; extmarks across insertion/deletion; restart relocation and ambiguity; modified-buffer-safe jumps; replacement code window; pinned multiline notes; wide/narrow browser drill/back and non-mutating preview; storage writes, conflicts, crash locks, corrupt/newer-schema recovery; external path/symlink/worktree rejection; immutable bounded exports including links/invalid/orphans; reload across separate processes.
- Layout: interactive terminal smoke checks for wide/narrow layout. Automated window/buffer checks complement this; terminal appearance is reviewed separately.

Initial verification: pure model suite plus headless integration on Neovim 0.11.5 and 0.12.2. Rendered Neovim UI checked at 150x40 and 70x32; fixtures and screenshots stayed in /tmp. Actual vim-plug/CoC/Telescope configuration startup was verified separately. The exported-snapshot seam also passed a disposable third-format (Org-mode) consumer probe; no extra abstraction was retained.
