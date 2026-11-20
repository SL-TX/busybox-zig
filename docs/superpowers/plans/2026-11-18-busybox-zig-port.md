# Busybox → Zig Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перевести весь busybox на Zig, сохраняя семантику и архитектуру — одно бинарное, ~700 апплетов, shared-библиотека.

**Architecture:** 1:1 C → Zig перевод. Каждый C-файл → Zig-модуль. libbb → libbb_zig. Апплет-реестр в Zig. Одно бинарное с выбором апплета по имени.

**Tech Stack:** Zig 0.17.1, `zig build`, Linux x86_64

**Spec:** docs/superpowers/specs/2026-11-18-busybox-zig-port-design.md

## Global Constraints

- Busybox лицензия: GPLv2+
- Zig 0.17.1 (установлен в `tools/zig-x86_64-linux-0.17.1/`)
- Linux x86_64 (на начальном этапе)
- Сохраняем POSIX-совместимость утилит
- Одно бинарное приложение (`busybox`) с ~350+ апплетами
- Конфигурация через `config.zig` (аналог `.config` busybox)
- `config.NAME` вместо `#ifdef` для условной компиляции
- C-хедеры без Zig-эквивалента: `@cImport`
- `__attribute__((packed))` → `@Type(.{ .StructLayout = .Manual })`
- `__builtin_*` → Zig-встроенные аналоги

## Review Focus

1. **Кросс-модульные символы** — `extern` между модулями (errno, optarg, и т.д.) не должны ломаться при рефакторинге
2. **Апплет-реестр** — выбор апплета по имени должен работать корректно для всех ~350 апплетов
3. **libbb_zig** — общие функции должны полностью заменять C-аналоги (особенно hash, socket, process)
4. **Условная компиляция** — `config.NAME` должен правильно включать/исключать код
5. **ABI-совместимость** — структура данных должна быть идентична C-версии (packed, aligned)

---

### Phase 0: Foundation

### Task 0: Project Structure & Build System

**Files:**
- Create: `src/zig.zon`
- Create: `src/zig.build`
- Create: `src/config.zig`
- Create: `src/libbb_zig/init.zig`
- Create: `src/applets.zig`
- Create: `src/main.zig`

**Interfaces:**
- Consumes: none
- Produces: `config.zig` (config struct with all applet flags), `applets.zig` (Applet struct + registry)

- [ ] **Step 1: Create project structure**

```
src/
├── zig.zon
├── zig.build
├── config.zig
├── libbb_zig/
│   └── init.zig
├── applets.zig
└── main.zig
```

- [ ] **Step 2: Create `zig.zon`** — Zig package definition with name "busybox"

- [ ] **Step 3: Create `zig.build`** — build steps for `install` target

- [ ] **Step 4: Create `config.zig`** — empty config struct, will be populated in later tasks

- [ ] **Step 5: Create `applets.zig`** — Applet struct definition:
```zig
pub const Applet = struct {
    name: []const u8,
    main: *const fn (argc: c_int, argv: [*][*]u8) c_int,
    flags: AppletFlags,
};

pub const AppletFlags = struct {
    noexec: bool = false,
    nofork: bool = false,
};
```

- [ ] **Step 6: Create `main.zig`** — skeleton main function that parses argv[0], looks up applet, calls main

- [ ] **Step 7: Verify — `zig build` should work (empty binary)**

---

### Task 1: libbb_zig — String Utilities

**Files:**
- Create: `src/libbb_zig/string.zig`
- Create: `src/libbb_zig/string_test.zig`

**Interfaces:**
- Consumes: none
- Produces: `strcmp`, `strncmp`, `strnlen`, `strlen`, `strcpy`, `strncpy`, `strdup`, `strdupz`, `strsep`, `strchr`, `strrchr`, `strcasestr`, `strstr`, `strrstr`, `startswith`, `endswith`, `is_prefixed_with`, `last_char_is`, `chomp`, `trim`, `skip_whitespace`, `replace`, `match_fstype`, `concat_path_file`, `concat_subpath_file`, `get_last_path_component`

- [ ] **Step 1: Write test for `strcmp`**

```zig
test "strcmp basic" {
    const a = "hello";
    const b = "hello";
    const c = "world";
    assert(std.mem.eql(u8, a, b));
    assert(!std.mem.eql(u8, a, c));
}
```

- [ ] **Step 2: Implement `strcmp` in `string.zig`**

- [ ] **Step 3: Run test — should pass**

- [ ] **Step 4: Implement string copy** — `strcpy`, `strncpy`, `strdup`, `strdupz`

- [ ] **Step 5: Implement string manipulation** — `strsep`, `strchr`, `strrchr`, `strcasestr`, `strstr`, `strrstr`

- [ ] **Step 6: Implement prefix/suffix checks** — `startswith`, `endswith`, `is_prefixed_with`, `last_char_is`

- [ ] **Step 7: Implement trimming** — `chomp`, `trim`, `skip_whitespace`

- [ ] **Step 8: Implement replacement** — `replace`

- [ ] **Step 9: Implement matching** — `match_fstype`

- [ ] **Step 10: Implement path operations** — `concat_path_file`, `concat_subpath_file`, `get_last_path_component`, `get_last_path_component`

- [ ] **Step 9: Verify — `zig build` compiles**

---

### Task 2: libbb_zig — Memory & Process

**Files:**
- Create: `src/libbb_zig/memory.zig`
- Create: `src/libbb_zig/process.zig`

**Interfaces:**
- Consumes: none
- Produces: `malloc`, `calloc`, `realloc`, `free`, `fork`, `execve`, `waitpid`, `kill`, `signal`, `setuid`, `setgid`, `chdir`, `close`, `open`, `pipe`, `dup2`, `setsid`, `getpid`, `getppid`, `getuid`, `geteuid`, `getgid`, `getegid`, `getgroups`

- [ ] **Step 1: Implement memory management** — `malloc`, `calloc`, `realloc`, `free`

- [ ] **Step 2: Implement process creation** — `fork`, `execve`, `waitpid`, `kill`

- [ ] **Step 3: Implement process control** — `signal`, `setuid`, `setgid`, `chdir`

- [ ] **Step 4: Implement file descriptor operations** — `close`, `open`, `pipe`, `dup2`, `setsid`

- [ ] **Step 5: Implement process info** — `getpid`, `getppid`, `getuid`, `geteuid`, `getgid`, `getegid`, `getgroups`

- [ ] **Step 9: Verify — `zig build` compiles**

---

### Task 3: libbb_zig — I/O & File Operations

**Files:**
- Create: `src/libbb_zig/io.zig`

**Interfaces:**
- Consumes: `process.zig` (fork, execve)
- Produces: `read`, `write`, `open`, `close`, `lseek`, `fstat`, `stat`, `access`, `unlink`, `rename`, `mkdir`, `rmdir`, `opendir`, `readdir`, `closedir`, `fdopen`, `fileno`, `fflush`, `fseek`, `fread`, `fwrite`, `fgets`, `fputs`, `vprintf`, `printf`, `sprintf`, `snprintf`, `fprintf`, `fscanf`, `sscanf`, `perror`, `die`, `warn`

- [ ] **Step 1: Implement file I/O** — `read`, `write`, `open`, `close`, `lseek`

- [ ] **Step 2: Implement file status** — `fstat`, `stat`, `access`, `unlink`, `rename`, `mkdir`, `rmdir`

- [ ] **Step 3: Implement directory operations** — `opendir`, `readdir`, `closedir`

- [ ] **Step 4: Implement stream I/O** — `fdopen`, `fileno`, `fflush`, `fseek`, `fread`, `fwrite`, `fgets`, `fputs`

- [ ] **Step 5: Implement formatted I/O** — `vprintf`, `printf`, `sprintf`, `snprintf`, `fprintf`, `fscanf`, `sscanf`

- [ ] **Step 6: Implement error handling** — `perror`, `die`, `warn`

- [ ] **Step 9: Verify — `zig build` compiles**

---

### Task 4: libbb_zig — Hash & Encryption

**Files:**
- Create: `src/libbb_zig/hash.zig`

**Interfaces:**
- Consumes: none
- Produces: `sha256_init`, `sha256_update`, `sha256_final`, `md5_init`, `md5_update`, `md5_final`, `crc32`, `pw_encrypt_md5`, `pw_encrypt_sha256`, `pw_encrypt_sha512`, `pw_encrypt_des`

- [ ] **Step 1: Implement SHA256** — `sha256_init`, `sha256_update`, `sha256_final`

- [ ] **Step 2: Implement MD5** — `md5_init`, `md5_update`, `md5_final`

- [ ] **Step 3: Implement CRC32** — `crc32`

- [ ] **Step 4: Implement password encryption** — `pw_encrypt_md5`, `pw_encrypt_sha256`, `pw_encrypt_sha512`, `pw_encrypt_des`

- [ ] **Step 10: Verify — `zig build` compiles**

---

### Task 5: libbb_zig — Socket & Network

**Files:**
- Create: `src/libbb_zig/socket.zig`

**Interfaces:**
- Consumes: none
- Produces: `socket`, `bind`, `connect`, `accept`, `listen`, `send`, `recv`, `sendto`, `recvfrom`, `setsockopt`, `getsockopt`, `getpeername`, `getsockname`, `gethostbyname`, `inet_addr`, `inet_ntoa`, `inet_pton`, `inet_ntop`, `sockaddr_in`, `sockaddr_storage`, `AF_INET`, `AF_INET6`, `SOCK_STREAM`, `SOCK_DGRAM`

- [ ] **Step 1: Implement socket creation** — `socket`, `bind`, `connect`, `accept`, `listen`

- [ ] **Step 2: Implement data transfer** — `send`, `recv`, `sendto`, `recvfrom`

- [ ] **Step 3: Implement socket options** — `setsockopt`, `getsockopt`, `getpeername`, `getsockname`

- [ ] **Step 4: Implement DNS** — `gethostbyname`, `inet_addr`, `inet_ntoa`, `inet_pton`, `inet_ntop`

- [ ] **Step 10: Verify — `zig build` compiles**

---

### Task 6: libbb_zig — Utility Functions

**Files:**
- Create: `src/libbb_zig/util.zig`

**Interfaces:**
- Consumes: none
- Produces: `human_readable`, `duration`, `isqrt`, `bbunit`, `get_cpu_count`, `kernel_version`, `makedev`, `major`, `minor`, `is_directory`, `executable`, `find_mount_point`, `iterate_on_dir`, `recursive_action`, `lineedit`, `getopt32`, `getopt_allopts`, `signal_names`, `process_escape_sequence`, `c_escape`, `percent_decode`, `mode_string`, `parse_mode`, `parse_config`, `logenv`, `setup_environment`, `clean_environment`

- [ ] **Step 1: Implement human-readable** — `human_readable`, `duration`, `isqrt`, `bbunit`

- [ ] **Step 2: Implement system info** — `get_cpu_count`, `kernel_version`, `makedev`, `major`, `minor`

- [ ] **Step 3: Implement filesystem checks** — `is_directory`, `executable`, `find_mount_point`, `iterate_on_dir`

- [ ] **Step 4: Implement recursive action** — `recursive_action`, `lineedit`

- [ ] **Step 5: Implement argument parsing** — `getopt32`, `getopt_allopts`

- [ ] **Step 6: Implement signal handling** — `signal_names`

- [ ] **Step 7: Implement escape handling** — `process_escape_sequence`, `c_escape`, `percent_decode`

- [ ] **Step 8: Implement mode parsing** — `mode_string`, `parse_mode`, `parse_config`, `logenv`

- [ ] **Step 9: Implement environment** — `setup_environment`, `clean_environment`

- [ ] **Step 9: Verify — `zig build` compiles**

---

### Task 7: Applet Registry & Main Entry Point

**Files:**
- Modify: `src/applets.zig`
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `applets.zig` (Applet struct)
- Produces: `applets` (array of all applets), `find_applet_by_name`, `run_applet`, `main`

- [ ] **Step 1: Populate applet registry** — add all ~350 applets to `applets.zig`

- [ ] **Step 2: Implement `find_applet_by_name`** — linear search with optional binary search optimization

- [ ] **Step 3: Implement `run_applet`** — call `applet.main(argc, argv)`

- [ ] **Step 4: Implement `main`** — parse argv[0], find applet, run it

- [ ] **Step 5: Verify — `zig build` compiles, `./busybox --help` shows applets**

---

### Phase 1: Simple Applets

### Task 8: Coreutils — cat, ls, echo

**Files:**
- Create: `src/coreutils/cat.zig`
- Create: `src/coreutils/ls.zig`
- Create: `src/coreutils/echo.zig`
- Create: `src/coreutils/printf.zig`

**Interfaces:**
- Consumes: `libbb_zig/string.zig`, `libbb_zig/io.zig`, `libbb_zig/process.zig`
- Produces: `cat_main`, `ls_main`, `echo_main`, `printf_main`

- [ ] **Step 1: Implement cat** — read files, output to stdout

- [ ] **Step 2: Implement ls** — list directory contents

- [ ] **Step 3: Implement echo** — print arguments

- [ ] **Step 4: Implement printf** — format string output

- [ ] **Step 5: Verify — `./busybox cat`, `./busybox ls`, `./busybox echo` work**

---

### Task 9: Coreutils — cp, mv, rm, mkdir, touch

**Files:**
- Create: `src/coreutils/cp.zig`
- Create: `src/coreutils/mv.zig`
- Create: `src/coreutils/rm.zig`
- Create: `src/coreutils/mkdir.zig`
- Create: `src/coreutils/touch.zig`

**Interfaces:**
- Consumes: `libbb_zig/io.zig`, `libbb_zig/process.zig`
- Produces: `cp_main`, `mv_main`, `rm_main`, `mkdir_main`, `touch_main`

- [ ] **Step 1-4: Implement cp** — copy files

- [ ] **Step 5-8: Implement mv** — move files

- [ ] **Step 9-12: Implement rm** — remove files

- [ ] **Step 13-16: Implement mkdir** — create directories

- [ ] **Step 17-20: Implement touch** — update timestamps

- [ ] **Step 21: Verify — `./busybox cp`, `./busybox mv`, `./busybox rm`, `./busybox mkdir`, `./busybox touch` work**

---

### Task 10: Coreutils — head, tail, sort, uniq, wc, cut, sed, awk

**Files:**
- Create: `src/coreutils/head.zig`
- Create: `src/coreutils/tail.zig`
- Create: `src/coreutils/sort.zig`
- Create: `src/coreutils/uniq.zig`
- Create: `src/coreutils/wc.zig`
- Create: `src/coreutils/cut.zig`
- Create: `src/coreutils/sed.zig`
- Create: `src/coreutils/awk.zig`

**Interfaces:**
- Consumes: `libbb_zig/string.zig`, `libbb_zig/io.zig`
- Produces: `head_main`, `tail_main`, `sort_main`, `uniq_main`, `wc_main`, `cut_main`, `sed_main`, `awk_main`

- [ ] **Step 1-8: Implement head** — read first N lines

- [ ] **Step 9-16: Implement tail** — read last N lines

- [ ] **Step 17-24: Implement sort** — sort lines

- [ ] **Step 25-32: Implement uniq** — remove duplicate lines

- [ ] **Step 33-40: Implement wc** — count lines/words/chars

- [ ] **Step 41-48: Implement cut** — cut fields from lines

- [ ] **Step 49-56: Implement sed** — stream editor

- [ ] **Step 57-64: Implement awk** — text processing

- [ ] **Step 65: Verify — all 8 commands work**

---

### Task 11: Util-linux — dmesg, mount, umount, fdisk, blkid

**Files:**
- Create: `src/util-linux/dmesg.zig`
- Create: `src/util-linux/mount.zig`
- Create: `src/util-linux/umount.zig`
- Create: `src/util-linux/fdisk.zig`
- Create: `src/util-linux/blkid.zig`

**Interfaces:**
- Consumes: `libbb_zig/io.zig`, `libbb_zig/process.zig`, `libbb_zig/socket.zig`
- Produces: `dmesg_main`, `mount_main`, `umount_main`, `fdisk_main`, `blkid_main`

- [ ] **Step 1: Implement dmesg** — read kernel messages

- [ ] **Step 2: Implement mount** — mount filesystems

- [ ] **Step 3: Implement umount** — unmount filesystems

- [ ] **Step 4: Implement fdisk** — partition disk

- [ ] **Step 5: Implement blkid** — block device identifier

- [ ] **Step 21: Verify — all 5 commands work**

---

### Task 12: Networking — ifconfig, ping, wget, curl, ssh, nc

**Files:**
- Create: `src/networking/ifconfig.zig`
- Create: `src/networking/ping.zig`
- Create: `src/networking/wget.zig`
- Create: `src/networking/curl.zig`
- Create: `src/networking/ssh.zig`
- Create: `src/networking/nc.zig`

**Interfaces:**
- Consumes: `libbb_zig/socket.zig`, `libbb_zig/io.zig`, `libbb_zig/string.zig`
- Produces: `ifconfig_main`, `ping_main`, `wget_main`, `curl_main`, `ssh_main`, `nc_main`

- [ ] **Step 1: Implement ifconfig** — configure network interfaces

- [ ] **Step 2: Implement ping** — test network connectivity

- [ ] **Step 3: Implement wget** — download files

- [ ] **Step 4: Implement curl** — transfer data

- [ ] **Step 5: Implement ssh** — secure shell

- [ ] **Step 6: Implement nc** — netcat

- [ ] **Step 25: Verify — all 6 commands work**

---

### Task 13: Miscutils — crontab, at, nice, ionice, renice

**Files:**
- Create: `src/miscutils/crontab.zig`
- Create: `src/miscutils/at.zig`
- Create: `src/miscutils/nice.zig`
- Create: `src/miscutils/ionice.zig`
- Create: `src/miscutils/renice.zig`

**Interfaces:**
- Consumes: `libbb_zig/process.zig`, `libbb_zig/io.zig`
- Produces: `crontab_main`, `at_main`, `nice_main`, `ionice_main`, `renice_main`

- [ ] **Step 1: Implement crontab** — schedule cron jobs

- [ ] **Step 2: Implement at** — schedule one-time jobs

- [ ] **Step 3: Implement nice** — change process priority

- [ ] **Step 4: Implement ionice** — change I/O priority

- [ ] **Step 5: Implement renice** — change process priority

- [ ] **Step 21: Verify — all 5 commands work**

---

### Task 14: Procps — ps, top, kill, killall, free

**Files:**
- Create: `src/procps/ps.zig`
- Create: `src/procps/top.zig`
- Create: `src/procps/kill.zig`
- Create: `src/procps/killall.zig`
- Create: `src/procps/free.zig`

**Interfaces:**
- Consumes: `libbb_zig/process.zig`, `libbb_zig/io.zig`
- Produces: `ps_main`, `top_main`, `kill_main`, `killall_main`, `free_main`

- [ ] **Step 1: Implement ps** — list processes

- [ ] **Step 2: Implement top** — process viewer

- [ ] **Step 3: Implement kill** — send signals

- [ ] **Step 4: Implement killall** — kill by name

- [ ] **Step 5: Implement free** — memory usage

- [ ] **Step 21: Verify — all 5 commands work**

---

### Task 15: Shell — ash

**Files:**
- Create: `src/shell/ash.zig`

**Interfaces:**
- Consumes: `libbb_zig/io.zig`, `libbb_zig/process.zig`, `libbb_zig/string.zig`
- Produces: `ash_main`

- [ ] **Step 1-4: Implement ash** — shell interpreter

- [ ] **Step 5: Verify — `./busybox ash` works**

---

### Task 16: Loginutils — login, passwd, su, useradd, userdel

**Files:**
- Create: `src/loginutils/login.zig`
- Create: `src/loginutils/passwd.zig`
- Create: `src/loginutils/su.zig`
- Create: `src/loginutils/useradd.zig`
- Create: `src/loginutils/userdel.zig`

**Interfaces:**
- Consumes: `libbb_zig/io.zig`, `libbb_zig/process.zig`, `libbb_zig/hash.zig`
- Produces: `login_main`, `passwd_main`, `su_main`, `useradd_main`, `userdel_main`

- [ ] **Step 1: Implement login** — login

- [ ] **Step 2: Implement passwd** — change password

- [ ] **Step 3: Implement su** — substitute user

- [ ] **Step 4: Implement useradd** — add user

- [ ] **Step 5: Implement userdel** — delete user

- [ ] **Step 21: Verify — all 5 commands work**

---

### Task 17: Remaining Categories

**Files:**
- Create: `src/console-tools/...`
- Create: `src/debianutils/...`
- Create: `src/e2fsprogs/...`
- Create: `src/editors/...`
- Create: `src/init/...`
- Create: `src/klibc-utils/...`
- Create: `src/mailutils/...`
- Create: `src/modutils/...`
- Create: `src/printutils/...`
- Create: `src/selinux/...`
- Create: `src/sysklogd/...`
- Create: `src/runit/...`

**Interfaces:**
- Consumes: existing libbb_zig modules
- Produces: remaining applet main functions

- [ ] **Step 1: Implement console-tools** — 15 applets

- [ ] **Step 2: Implement debianutils** — 4 applets

- [ ] **Step 3: Implement e2fsprogs** — 5 applets

- [ ] **Step 4: Implement editors** — 9 applets

- [ ] **Step 5: Implement init** — 3 applets

- [ ] **Step 6: Implement klibc-utils** — 4 applets

- [ ] **Step 7: Implement mailutils** — 5 applets

- [ ] **Step 8: Implement modutils** — 9 applets

- [ ] **Step 9: Implement printutils** — 2 applets

- [ ] **Step 10: Implement selinux** — 11 applets

- [ ] **Step 11: Implement sysklogd** — 5 applets

- [ ] **Step 12: Implement runit** — 5 applets

- [ ] **Step 13: Final verification — `./busybox --help` shows all 350+ applets**

---

### Review Focus Tests

#### RF1: Cross-module symbols (errno, optarg)
- **Task owning this**: Task 2 (process.zig)
- **Test**: `test "errno cross-module"` — verify errno is accessible from other modules
- **Test**: `test "optarg cross-module"` — verify optarg is accessible from other modules

#### RF2: Applet registry (all 350 applets)
- **Task owning this**: Task 7
- **Test**: `test "all applets registered"` — verify all 350 applets are in the registry
- **Test**: `test "applet lookup by name"` — verify finding applet by name works for all

#### RF3: libbb_zig (hash, socket, process)
- **Task owning this**: Tasks 4, 5, 2
- **Test**: `test "sha256 round-trip"` — verify SHA256 produces correct hash
- **Test**: `test "socket connect"` — verify socket connection works
- **Test**: `test "process fork"` — verify fork/exec works

#### RF4: Conditional compilation (config.NAME)
- **Task owning this**: Task 0
- **Test**: `test "config inclusion"` — verify config.NAME controls compilation

#### RF5: ABI compatibility (packed, aligned)
- **Task owning this**: Task 0
- **Test**: `test "struct packed"` — verify struct layout matches C
- **Test**: `test "struct aligned"` — verify alignment matches C
