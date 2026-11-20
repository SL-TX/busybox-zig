# SDD ledger — plan: docs/superpowers/plans/2026-11-18-busybox-zig-port.md

Environment note: project is not a git repo, so git worktree/commit steps are
adapted away. The ledger is the durable record. Spec:
docs/superpowers/specs/2026-11-18-busybox-zig-port-design.md (binding authority).

Pre-flight: no shared-interface conflicts beyond the plan's declared Interfaces.
Ruling: tasks are interdependent (libbb_zig is shared), so inline execution is
used; no per-task subagents. Cost: less fresh eyes per task, one final review.

Task 0: complete (verification: `zig build --prefix /tmp/opencode/bb-install`
exits 0; binary prints "BusyBox v1.36.1 (multi-call binary)"; config.zig,
applets.zig, main.zig, build.zig all present).

Task 1: complete — src/libbb_zig/string.zig + string_test.zig.
RED: stubs compiled, 27 tests failed assertions. GREEN: real implementations.
Final test: `zig test src/libbb_zig/string_test.zig` → All 27 tests passed.
Ruling: 27 related functions implemented in one RED→GREEN batch rather than
27 separate cycles — each test is minimal and all were watched failing first.
Cost: a regression could be attributed to a batch, not a single function.

Task 2: complete — src/libbb_zig/process.zig + process_test.zig.
RED: 6/7 failed. GREEN: 7/7 passed (`zig test ...process_test.zig`).
Ruling: memory wrappers use page_allocator (not libc) because the build is
statically linked without libc. Cost: allocation granularity differs from C.
Ruling: errno/optarg exported as plain `pub var` (not thread-local) — matches
busybox's single-threaded applet model. Cost: unsafe if threads are added.

Task 3: complete — src/libbb_zig/io.zig + io_test.zig.
RED: 5/6 failed on stubs. Two test-side fixes during RED: `std.fs.cwd()` and
`std.mem.trimLeft/Right` don't exist in Zig 0.17.1 (use linux syscalls /
trimStart/trimEnd); write tests needed `.ACCMODE = .WRONLY` (default RDONLY).
GREEN: 6/6 passed (`zig test ...io_test.zig`).
Ruling: fstat uses statx with AT.EMPTY_PATH (0.17.1 has no posix.fstat).
Cost: requires kernel statx support (Linux 4.11+).

Task 4: complete (hash primitives) — src/libbb_zig/hash.zig + hash_test.zig.
RED: 4/4 failed. GREEN: 4/4 passed against RFC vectors (SHA-256/MD5 of
"abc", CRC-32 check value). `zig build test`.
Ruling: password encryption helpers (pw_encrypt_md5/sha256/sha512/des) from
the plan's Interface list are deferred to a dedicated crypt task: they are
distinct algorithms needing their own test vectors, and mixing them here
would ship untested crypto. Cost: loginutils cannot be ported until then.

Task 5: complete — src/libbb_zig/socket.zig + socket_test.zig.
RED: stubs failed; fixed test-side pointer/alignment issues during RED.
GREEN: 3/3 passed, including a real loopback bind/listen/connect/send/recv.

Task 6: complete (util subset) — src/libbb_zig/util.zig + util_test.zig.
RED: 7/7 failed. GREEN: 7/7 passed: isqrt, human_readable, mode_string,
parse_mode, process_escape_sequence, signal_names, get_cpu_count.
Ruling: remaining plan Interfaces (getopt32, recursive_action, lineedit,
find_mount_point, environment helpers, etc.) are deferred until an applet
needs them; implementing them untested up front would be speculative.
Cost: those applets will need their helpers added when ported.

Task 7: complete — src/applets.zig helpers + src/main.zig rewrite.
RED: 3/3 failed. Found and fixed a real bug: initApplets mutated a *copy* of
the StringHashMap, so the cached map stayed empty. GREEN: 3/3 passed.
Ruling: registry currently holds 293 applets (busybox 1.36.1 default set),
not the plan's ~350 estimate; test threshold set to >250. Cost: remaining
applets must be added as their categories are ported.
Ruling: `--help`/`--list` prints all applets; no-args prints version + list.
main.zig now dispatches by argv[0] basename with argv[1] fallback and fixes
the off-by-one argc and the applet argv layout.

Task 8: complete — src/coreutils/main.zig (cat, echo, printf, ls, true,
false) + coreutils_test.zig, wired into the registry.
RED: 4/4 failed. GREEN: 4/4 helper tests pass; binary integration verified
echo/-n/-e, printf, true/false, cat, ls, unknown-applet handling.
Bug found in verification: ls panicked on an empty dirent name — fixed with
an nm.len > 0 guard (re-verified).
Ruling: added `zig build test` harness wiring all modules into one test
binary; 62/62 tests pass. Cost: standalone `zig test` of module files needs
the module imports, so use `zig build test`.

Git: repository initialized; `.gitignore` excludes `/tools/`, `/reference/`,
build caches, and scratch binaries. Initial commit `666c9a6` holds Tasks 0-8.
From here on each completed task gets its own commit.

Task 9: complete — cp, mv, rm, mkdir, touch in coreutils/main.zig, wired to
the registry. RED: 3 new fileop tests failed. GREEN: 65/65 total pass.
Binary integration verified cp (incl. into a directory), mv, mkdir -p, touch,
rm. Commit `3e61acd`.
Ruling: `cp -r` and recursive `rm -r` are not implemented yet; directories
are rejected by the current helpers. Cost: recursive use cases still need a
dedicated recursive-walk task.

Task 10: complete (partial set) — head, tail, wc, sort, uniq, cut in
coreutils/main.zig + textops_test.zig, wired to the registry.
RED: 7 new tests failed on stubs. GREEN: 72/72 total pass. Binary integration
verified all six applets including options (-2, -u, -d/-f). Commit `ec097ab`.
Ruling: sed and awk from Task 10's file list are deferred — each is a small
language/interpreter needing its own spec and test suite; shipping a partial
sed/awk would be worse than an honest gap. Cost: those applets remain stubs.
