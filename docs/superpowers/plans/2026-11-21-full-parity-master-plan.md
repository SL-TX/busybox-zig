# BusyBox 1.39.0 Full Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Довести `busybox-zig` до полного поведенческого паритета с BusyBox 1.39.0 (коммит `6412da2`): 443 апплета, 411 в defconfig, 946 config-символов, точные usage-тексты, метаданные и дифференциальные тесты против референса.

**Architecture:** Сначала генерация манифеста/конфига/usage и дифференциальный стенд; затем волны категорий. libbb-хелперы добавляются под текущую волну и сразу покрываются unit-тестами. Каждый апплет реализуется по протоколу TDD: кейсы → падение → реализация → зелёный прогон → коммит.

**Tech Stack:** Zig 0.17.1, `zig build`, Python 3 (stdlib only) для скриптов паритета, Linux x86_64, статический бинарник без C-кода.

**Spec:** `docs/superpowers/specs/2026-11-21-full-parity-design.md`

## Global Constraints

- Zig **0.17.1**; Linux **x86_64**; один статический бинарник `busybox`.
- Референс закреплён: `reference/busybox`, git `6412da255d465be1f1860ae109ccbf2564810af2`, BusyBox **1.39.0.git**.
- Цель: **443** имени апплетов; **411** в defconfig; **946** символов конфигурации (895 boolean, 51 не-boolean).
- Точный текст `APPLET --help`; точные `--list`, `--list-full`, `--install`, `--show`, `--version`.
- Никакого C-кода в бинарнике; никаких вызовов системных `busybox`/`coreutils` вместо реализации.
- Лицензия GPLv2+.
- Тесты не трогают реальные `/etc/passwd`, `/etc/shadow`, диски, интерфейсы и сервисы; только песочницы, tmpfs, loop-образы, namespace и контейнер с capability.
- CI работает без сети; референсный бинарник и golden-файлы готовятся заранее и коммитятся.
- После каждого таска `zig build` и `zig build test` зелёные.

## Review Focus

1. **Диспетчеризация по `argv[0]`:** symlink с путём и завершающим `/`, вызов `busybox <applet>`, applet с именем `busybox`, специальные случаи `test --help`, `true --help`, `false --help`, `echo --help`, `[ --help`, `[[ --help` — `--help` не должен перехватываться общим мета-обработчиком.
2. **Отключённые конфигом апплеты:** отсутствуют в `--list` и в бинарнике; включение feature-флага реально меняет поведение, а не игнорируется.
3. **Имена и аргументы:** пробелы, переводы строк, non-UTF8, имена, начинающиеся с `-`, `--`, пустые аргументы; вывод сравнивается побайтно.
4. **Побочные эффекты вне cwd:** `passwd`, `crontab`, `syslogd`, `httpd`, `udhcpc`, `mount` и подобные обязаны уважать override-пути и не писать на хост.
5. **Недетерминизм:** время, pid, uid/gid, hostname, `/proc`, порядок строк; каждая нормализация объявляется в кейсе явно, а не глобальным фильтром.
6. **SUID и привилегии:** `drop`/`require`/`maybe`, `--install -s`, сброс groups/euid/egid; проверка только в контейнере с capability.

---

## How to Use This Plan

Это **master plan** программы паритета. Задачи 1–6 и libbb-задачи выполняются
как есть. Задачи-волны 7–26 — это эпики: перед началом волны для неё
пишется детальный sub-plan по тому же шаблону (`superpowers:writing-plans`),
но протокол реализации апплета ниже обязателен и не переписывается.

### Applet Implementation Protocol (обязателен для каждой волны)

Для каждого апплета `<name>` из списка волны:

- [ ] **P1. Прочитать референс.** Открыть C-файл апплета и его usage в
  `reference/busybox`; выписать все опции, аргументы, коды возврата и
  side effects.
- [ ] **P2. Написать кейсы.** Создать
  `tests/parity/cases/<category>/<name>.json` с минимумом: `--help`, без
  аргументов, каждая документированная опция, неверная опция, отсутствующий
  операнд, stdin/file/dir-режим и один граничный случай.
- [ ] **P3. Убедиться, что кейсы падают.** Запустить
  `python3 scripts/parity/run.py --applet <name>`; ожидается FAIL
  (`missing` или `stub`).
- [ ] **P4. Реализовать.** Добавить `<name>_main` в
  `src/<category>/<name>.zig` (или в сгруппированный файл для мелких
  апплетов), зарегистрировать в `src/applets.zig`; использовать только
  libbb-хелперы, не системные утилиты.
- [ ] **P5. Добиться зелёного.** `run.py --applet <name>` → PASS;
  `zig build test` → PASS.
- [ ] **P6. Коммит.** `git add ... && git commit -m "feat(<category>): implement <name>"`.

### Definition of Done для волны

- Все апплеты волны зарегистрированы; для default-enabled нет заглушек.
- Для каждого апплета есть кейсы и они зелёные против референса.
- `--help` совпадает.
- Матрица паритета перегенерирована.
- `zig build test` и `python3 scripts/parity/run.py --all` зелёные.

---

## Shared Interfaces

Эти типы и сигнатуры фиксируются до начала волн. Поздние задачи обязаны
использовать именно их.

```zig
// src/generated/applet_manifest.zig — генерируется, не редактируется руками
pub const Location = enum { bin, sbin, usr_bin, usr_sbin, root };
pub const Suid = enum { drop, require, maybe };
pub const Entry = struct {
    name: []const u8,
    main: []const u8,
    flag: []const u8,
    location: Location,
    suid: Suid,
    noexec: bool,
    nofork: bool,
    scripted: bool,
    category: []const u8,
    default_enabled: bool,
};
pub const entries: [443]Entry;
```

```zig
// src/applets.zig
pub const MainFn = *const fn (c_int, [*][*:0]const u8) c_int;
pub const Applet = struct {
    name: []const u8,
    main: MainFn,
    location: Location,
    suid: Suid,
    noexec: bool = false,
    nofork: bool = false,
    scripted: bool = false,
    usage: []const u8,
};
pub fn mainFor(comptime name: []const u8) MainFn;
pub fn findAppletByName(name: []const u8) ?Applet;
pub fn appletNames(allocator: std.mem.Allocator) ![][]const u8;
pub fn appletNamesFull(allocator: std.mem.Allocator) ![][]const u8;
```

```zig
// src/libbb_zig/getopt.zig
pub const Arg = enum { none, required, optional };
pub const LongOpt = struct { name: []const u8, has_arg: Arg = .none, val: u8 };
pub const Options = struct {
    flags: u32,
    index: usize,
    optarg: ?[]const u8,
    args: []const []const u8,
};
pub fn getopt32(
    argv: []const []const u8,
    optstring: []const u8,
    longopts: []const LongOpt,
) !Options;
```

```zig
// src/libbb_zig/regex/regex.zig
pub const Flags = struct {
    extended: bool = false,
    ignore_case: bool = false,
    newline: bool = false,
};
pub const Match = struct { start: usize, end: usize };
pub const Regex = struct { /* opaque */ };
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: Flags) !Regex;
pub fn exec(self: *const Regex, text: []const u8, matches: []Match) !usize;
```

```zig
// src/libbb_zig/xfuncs.zig
pub fn die(msg: []const u8) noreturn;
pub fn errorMsg(errnum: c_int, comptime fmt: []const u8, args: anytype) void;
pub fn perrorMsg(comptime fmt: []const u8, args: anytype) void;
pub fn xmalloc(allocator: std.mem.Allocator, n: usize) ![]u8;
pub fn xstrdup(allocator: std.mem.Allocator, s: []const u8) ![]u8;
pub fn xopen(path: []const u8, flags: std.posix.O, mode: std.posix.mode_t) !std.posix.fd_t;
pub fn xread(fd: std.posix.fd_t, buf: []u8) !usize;
pub fn xwrite(fd: std.posix.fd_t, buf: []const u8) !void;
```

```python
# scripts/parity/run.py CLI
# python3 scripts/parity/run.py --ref PATH --zig PATH --cases DIR \
#   [--applet NAME] [--all] [--golden DIR] [--update-golden] [--verbose]
# exit 0 = pass, 1 = mismatch, 2 = harness error
```

Схема кейса:

```json
{
  "applet": "echo",
  "cases": [
    {
      "name": "basic",
      "argv": ["hello", "world"],
      "stdin": null,
      "files": { "file.txt": "content" },
      "dirs": ["sub"],
      "symlinks": { "link": "file.txt" },
      "env": { "TZ": "UTC", "LC_ALL": "C" },
      "cwd": ".",
      "timeout_ms": 5000,
      "normalize": ["tmp_path"],
      "requires": [],
      "expect": { "exit": 0 }
    }
  ]
}
```

Тестовые хелперы `runApplet(name, argv) u8` и
`runAppletCapture(name, argv) []const u8` живут в `src/test_helpers.zig` и
используются тестами диспетчера/usage.

Допустимые `normalize`: `tmp_path`, `pid`, `uid`, `gid`, `hostname`,
`timestamp`, `sort_lines`, `regex:<pattern>`. Каждая запись означает
конкретную замену в stdout/stderr, а не «игнорировать различия».

---

## Phase 0 — Infrastructure

### Task 1: Reference snapshot and applet manifest

**Files:**
- Create: `scripts/parity/extract_manifest.py`
- Create: `scripts/parity/tests/test_extract_manifest.py`
- Create: `scripts/parity/fixtures/applets.h`
- Create: `scripts/parity/fixtures/.config`
- Create: `src/generated/applet_manifest.zig`
- Create: `tests/parity/manifest.json`
- Modify: `docs/superpowers/specs/2026-11-21-busybox-parity-matrix.md` (regenerate)
- Modify: `build.zig` (add `manifest` step)

**Interfaces:**
- Consumes: `reference/busybox/include/applets.h` (generated by
  `make O=/tmp/opencode/bb-ref defconfig`) or committed
  `tests/parity/manifest.json`.
- Produces: `Entry`, `entries`, `tests/parity/manifest.json`, matrix.

- [ ] **Step 1: Write the failing fixture test**

`scripts/parity/fixtures/applets.h` содержит строки:

```c
IF_CAT(APPLET(cat, BB_DIR_BIN, BB_SUID_DROP))
IF_BZCAT(APPLET_ODDNAME(bzcat, bunzip2, BB_DIR_USR_BIN, BB_SUID_DROP, bzcat))
IF_LS(APPLET_NOEXEC(ls, ls, BB_DIR_BIN, BB_SUID_DROP, ls))
IF_CLEAR(APPLET_NOFORK(clear, clear, BB_DIR_USR_BIN, BB_SUID_DROP, clear))
IF_SH_IS_ASH(APPLET_SCRIPTED(sh, sh, BB_DIR_BIN, BB_SUID_DROP, sh))
IF_BUSYBOX(IF_FEATURE_SH_STANDALONE(IF_FEATURE_TAB_COMPLETION(APPLET(busybox, BB_DIR_BIN, BB_SUID_MAYBE))))
//TODO alias to "tune2fs -L LABEL": //applet:IF_E2LABEL(APPLET_ODDNAME(e2label, tune2fs, BB_DIR_SBIN, BB_SUID_DROP, e2label))
```

`scripts/parity/tests/test_extract_manifest.py`:

```python
def test_parses_all_applet_kinds():
    entries = extract("scripts/parity/fixtures/applets.h", "scripts/parity/fixtures/.config")
    assert [e["name"] for e in entries] == ["cat", "bzcat", "ls", "clear", "sh", "busybox"]
    assert entries[1]["main"] == "bunzip2"
    assert entries[2]["noexec"] is True
    assert entries[3]["nofork"] is True
    assert entries[4]["scripted"] is True
    assert entries[5]["suid"] == "maybe"
    assert "e2label" not in [e["name"] for e in entries]
```

- [ ] **Step 2: Run it and watch it fail**

Run: `python3 -m unittest scripts/parity/tests/test_extract_manifest.py -v`
Expected: FAIL, `extract` is not defined.

- [ ] **Step 3: Implement `extract_manifest.py`**

Парсит строки `IF_<FLAG>(...APPLET...)`, поддерживает `APPLET`,
`APPLET_ODDNAME`, `APPLET_NOEXEC`, `APPLET_NOFORK`, `APPLET_SCRIPTED`,
вложенные `IF_*`, игнорирует `//TODO`-строки и `////applet:`. Определяет
`default_enabled` по `CONFIG_<FLAG>=y` из `.config`. Категорию берёт из
исходного C-файла; для сгенерированного `applets.h` категория передаётся
отдельным map-файлом `tests/parity/categories.json`, который создаётся
сканированием `reference/busybox/**/*.c`.

- [ ] **Step 4: Run the fixture test and the reference integration test**

Run:
```bash
python3 -m unittest scripts/parity/tests/test_extract_manifest.py -v
python3 scripts/parity/extract_manifest.py --ref reference/busybox --check
```
Expected: fixture PASS; reference check prints `443 applets, 411 default-enabled` and exits 0. Если `reference/` отсутствует, integration-тест пропускается с явным `SKIP: reference not present`.

- [ ] **Step 5: Generate committed artifacts**

Run:
```bash
python3 scripts/parity/extract_manifest.py --ref reference/busybox \
  --out-src src/generated/applet_manifest.zig \
  --out-json tests/parity/manifest.json \
  --out-matrix docs/superpowers/specs/2026-11-21-busybox-parity-matrix.md
```
Expected: files created; `src/generated/applet_manifest.zig` compiles in Step 6.

- [ ] **Step 6: Add `zig build manifest` freshness check**

`build.zig` получает шаг, который запускает Python-скрипт с `--check-json`
(сверяет `src/generated/applet_manifest.zig` с `tests/parity/manifest.json`,
не требуя `reference/`). В CI шаг обязателен.

- [ ] **Step 7: Commit**

```bash
git add scripts/parity src/generated/applet_manifest.zig tests/parity docs/superpowers/specs/2026-11-21-busybox-parity-matrix.md build.zig
git commit -m "feat(parity): generate applet manifest from reference"
```

### Task 2: Config generation

**Files:**
- Create: `scripts/parity/gen_config.py`
- Create: `scripts/parity/tests/test_gen_config.py`
- Create: `scripts/parity/fixtures/config.sample`
- Create: `configs/defconfig`
- Create: `src/generated/config.zig`
- Modify: `src/config.zig` (becomes generated; header `DO NOT EDIT`)
- Modify: `build.zig` (config module uses `src/generated/config.zig`)
- Modify: `.gitlab-ci.yml` (freshness check)

**Interfaces:**
- Consumes: `.config` text.
- Produces: `pub const CONFIG_<SYMBOL> = <value>;` for all 946 symbols and
  `pub const APPLET_<name> = CONFIG_<FLAG>;` for all 443 applets.

- [ ] **Step 1: Write the failing generator test**

Fixture `config.sample`:

```text
CONFIG_CAT=y
# CONFIG_LS is not set
CONFIG_FEATURE_LONG_OPTS=y
CONFIG_FEATURE_BUFFERS_GO_ON_STACK=y
CONFIG_DHCPC_DEFAULT_SCRIPT="/usr/share/udhcpc/default.script"
CONFIG_FEATURE_SYSLOGD_READ_BUFFER_SIZE=256
```

Test asserts generated text contains:

```zig
pub const CONFIG_CAT = true;
pub const CONFIG_LS = false;
pub const CONFIG_DHCPC_DEFAULT_SCRIPT = "/usr/share/udhcpc/default.script";
pub const CONFIG_FEATURE_SYSLOGD_READ_BUFFER_SIZE = 256;
pub const APPLET_cat = CONFIG_CAT;
pub const APPLET_ls = CONFIG_LS;
```

- [ ] **Step 2: Run and watch it fail**

Run: `python3 -m unittest scripts/parity/tests/test_gen_config.py -v`
Expected: FAIL, `generate` not defined.

- [ ] **Step 3: Implement the generator**

Правила: `=y` → `true`, `=n` → `false`, `# CONFIG_X is not set` → `false`,
целое → integer, строка в кавычках → Zig-строка с escaping. Для каждого
апплета из `tests/parity/manifest.json` генерируется alias
`APPLET_<name>` с `CONFIG_<flag>`.

- [ ] **Step 4: Generate the real config**

Run:
```bash
cp /tmp/opencode/bb-ref/.config configs/defconfig
python3 scripts/parity/gen_config.py --config configs/defconfig --out src/config.zig
./tools/zig-x86_64-linux-0.17.1/zig build
```
Expected: build succeeds; `grep -c '^pub const CONFIG_' src/config.zig` → 946;
`grep -c '^pub const APPLET_' src/config.zig` → 443.

- [ ] **Step 5: Add `-Dconfig=path` support**

`build.zig` принимает `-Dconfig=path`; без флага используется
`configs/defconfig`. Шаг `gen-config` перегенерирует `src/config.zig`.
CI проверяет, что файл не устарел.

- [ ] **Step 6: Commit**

```bash
git add scripts/parity configs/defconfig src/config.zig build.zig .gitlab-ci.yml
git commit -m "feat(parity): generate full config from reference defconfig"
```

### Task 3: Applet metadata and meta-CLI

**Files:**
- Modify: `src/applets.zig`
- Modify: `src/main.zig`
- Create: `src/meta_test.zig`
- Modify: `src/applets_test.zig`, `src/final_review_test.zig`
- Modify: `src/generated/applet_manifest.zig` (consumed)

**Interfaces:**
- Consumes: `applet_manifest.entries`, `config.APPLET_*`.
- Produces: `Applet` с метаданными; `appletNames`, `appletNamesFull`;
  `findAppletByName`; мета-опции `busybox`.

- [ ] **Step 1: Write failing tests**

`src/meta_test.zig`:

```zig
test "list has no internal helper names" {
    const names = try applets.appletNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 411), names.len);
    for (names) |n| try std.testing.expect(!std.mem.eql(u8, n, "tls_aes"));
    try std.testing.expect(std.mem.indexOfScalar([]const u8, names, "[") != null);
}

test "version is 1.39.0 banner only" {
    // run main with argv = ["busybox", "--version"], capture stdout
    try std.testing.expect(std.mem.startsWith(u8, out, "BusyBox v1.39.0"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "multi-call binary"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "list-full format has no leading slash" {
    const full = try applets.appletNamesFull(std.testing.allocator);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("usr/bin/[", full[0]);
    // "cat" is at index after the bracketed names; format is "bin/cat"
}

test "POSIX special cases are not intercepted as meta help" {
    // "busybox test --help", "true --help", "false --help", "echo --help",
    // "[ --help", "[[ --help" must reach their applets
    try std.testing.expectEqual(@as(u8, 0), code);
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `./tools/zig-x86_64-linux-0.17.1/zig build test`
Expected: FAIL on list length, version string, and/or help interception.

- [ ] **Step 3: Rebuild the registry from the manifest**

`initApplets` итерирует `applet_manifest.entries`; для каждого имени берёт
`mainFor(name)`; если апплет ещё не реализован, `mainFor` возвращает
`stubMain`. Удалить 46 не-applet-записей и ручные `putIfEnabled`-строки.
`putIfEnabled` заменяется проверкой `@field(config, "APPLET_" ++ name)`.
Апплет `busybox` регистрируется только при `FEATURE_SH_STANDALONE`; при
вызове как `busybox` мета-диспетчер имеет приоритет над applet-записью.

- [ ] **Step 4: Implement the meta-CLI**

`src/main.zig` обрабатывает: `--help [APPLET]`, `--list`, `--list-full`
(при `FEATURE_INSTALLER`), `--show SCRIPT` (при `FEATURE_SHOW_SCRIPT`),
`--install [-s] [DIR]` (при `FEATURE_INSTALLER`), `--version`, отсутствие
аргументов. Специальные случаи `test`, `true`, `false`, `echo`, `[`, `[[`
проверяются до общего `--help`. `--version` печатает только banner
референса. `--install` использует `Applet.location`; `-s` создаёт symlink,
без `-s` — hardlink (как в референсе).

- [ ] **Step 5: Add metadata tests**

Проверить на 10 репрезентативных апплетах: `cat` (`bin`, `drop`),
`passwd` (`usr/bin`, `maybe`/`require` по референсу), `init` (`sbin`),
`sh` (`bin`, `scripted`), `ls` (`noexec`), `clear` (`nofork`).
Тест берёт значения из `tests/parity/manifest.json` и сравнивает с
`findAppletByName`.

- [ ] **Step 6: Run tests and commit**

Run: `./tools/zig-x86_64-linux-0.17.1/zig build test`
Expected: PASS.
```bash
git add src/applets.zig src/main.zig src/meta_test.zig src/applets_test.zig src/final_review_test.zig
git commit -m "feat(parity): applet metadata and busybox meta-CLI"
```

### Task 4: Usage text and `--help`

**Files:**
- Create: `scripts/parity/extract_usage.py`
- Create: `scripts/parity/tests/test_extract_usage.py`
- Create: `tests/parity/usage/<applet>.txt` (golden)
- Create: `src/generated/usage.zig`
- Modify: `src/applets.zig`, `src/main.zig`
- Create: `src/usage_test.zig`

**Interfaces:**
- Produces: `pub fn usageFor(name: []const u8) ?[]const u8;`
- `APPLET --help` печатает `usageFor(name)`, exit 0; `busybox --help APPLET`
  делает то же.

- [ ] **Step 1: Write failing tests**

```zig
test "cat --help matches reference golden" {
    try std.testing.expectEqualStrings(
        try std.fs.cwd().readFileAlloc(std.testing.allocator, "tests/parity/usage/cat.txt", 1 << 20),
        usageFor("cat").?,
    );
}
test "test --help is a normal argument, not help" {
    // POSIX: "test --help" is no different from "test --foo"
    try std.testing.expectEqual(@as(u8, 0), runApplet("test", &.{"--help"}));
}
test "echo --help prints the literal argument" {
    try std.testing.expectEqualStrings("--help\n", runAppletCapture("echo", &.{"--help"}));
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `./tools/zig-x86_64-linux-0.17.1/zig build test`
Expected: FAIL, `usageFor` not defined.

- [ ] **Step 3: Implement usage extraction**

`extract_usage.py` запускает референсный бинарник для каждого имени:
`busybox <applet> --help`, сохраняет stdout в `tests/parity/usage/<applet>.txt`
и генерирует `src/generated/usage.zig` как Zig-строки. Если бинарник
недоступен, использует уже закоммиченные golden-файлы. Референсный бинарник
собирается в `ci/reference.Dockerfile`; при проблемах с хост-заголовками
допускается отключить проблемные апплеты в конфиге сборки референса
(например, `CONFIG_TC=n`), usage остальных от этого не меняется.

- [ ] **Step 4: Wire `--help`**

`main.zig` при `argv[1] == "--help"` для апплета печатает usage и выходит 0.
Для `test`, `[`, `[[` — сначала applet-usage. `busybox --help` без апплета
печатает общий help референса.

- [ ] **Step 5: Verify and commit**

Run:
```bash
./tools/zig-x86_64-linux-0.17.1/zig build test
python3 scripts/parity/run.py --ref /tmp/opencode/bb-ref/busybox --zig zig-out/bin/busybox --applet cat --cases tests/parity/cases
```
Expected: PASS.
```bash
git add scripts/parity src/generated/usage.zig tests/parity/usage src/usage_test.zig src/main.zig src/applets.zig
git commit -m "feat(parity): reference usage text and applet --help"
```

### Task 5: Differential test harness

**Files:**
- Create: `scripts/parity/run.py`
- Create: `scripts/parity/sandbox.py`
- Create: `scripts/parity/normalize.py`
- Create: `scripts/parity/pty.py`
- Create: `scripts/parity/ns.py`
- Create: `scripts/parity/tests/test_run.py`
- Create: `tests/parity/cases/_smoke/echo.json`
- Create: `tests/parity/cases/_smoke/true.json`
- Create: `tests/parity/cases/_smoke/pwd.json`
- Create: `tests/parity/known-failures.txt` (empty at release)
- Modify: `.gitlab-ci.yml` (parity-golden stage)

**Interfaces:**
- CLI as in Shared Interfaces.
- `sandbox.py`: `materialize(case, root) -> None`, `snapshot(root) -> Tree`.
- `normalize.py`: `apply(text, rules) -> str`.
- `pty.py`: `run_pty(argv, script, timeout) -> (stdout, exit)`.
- `ns.py`: `run_ns(kind, argv) -> CompletedProcess`.

- [ ] **Step 1: Write the harness self-test**

```python
def test_same_binary_passes(tmp_path):
    result = run_case(binary=sys.executable, argv=["-c", "print('x')"], case=...)
    assert result.status == "pass"

def test_different_output_fails(tmp_path):
    result = compare(expected="a\n", actual="b\n")
    assert result.status == "fail"
    assert "stdout" in result.diff
```

- [ ] **Step 2: Run and watch it fail**

Run: `python3 -m unittest scripts/parity/tests/test_run.py -v`
Expected: FAIL, `run_case` not defined.

- [ ] **Step 3: Implement sandbox and comparison**

Для каждого кейса создаются два каталога `ref/` и `zig/` с одинаковыми
файлами, каталогами, symlink-ами и env. Запуск с `cwd` внутри песочницы,
stdin из `stdin`, timeout. Сравниваются stdout/stderr/exit и снимок дерева
(тип, содержимое, mode, symlink target). `tmp_path` заменяет абсолютный
путь песочницы на `<TMP>` в обоих выводах.

- [ ] **Step 4: Add smoke cases and record known failures**

`echo`, `true`, `pwd` должны пройти против референса. Если `pwd`/`echo`
расходятся, записать кейс в `known-failures.txt` с причиной и не считать
волну закрытой.

- [ ] **Step 5: Add golden mode and CI**

`--update-golden` сохраняет эталонный вывод; `--golden` сравнивает с ним.
CI job `parity-golden` запускает все кейсы в golden-режиме и падает при
непустом `known-failures.txt` (начиная с волны 9).

- [ ] **Step 6: Add pty/ns helpers with skip policy**

`pty.py` и `ns.py` возвращают `SKIP` только при явном `requires` в кейсе;
молчаливый пропуск запрещён. Тест харнесса проверяет, что `SKIP` без
`requires` — ошибка.

- [ ] **Step 7: Commit**

```bash
git add scripts/parity tests/parity .gitlab-ci.yml
git commit -m "feat(parity): differential test harness with golden mode"
```

---

## Phase 1 — Wave 1: coreutils, findutils, debianutils, printutils, klibc

### Task 6: libbb core (Wave 1 prerequisites)

**Files:**
- Create: `src/libbb_zig/xfuncs.zig`, `messages.zig`, `getopt.zig`,
  `path.zig`, `io_more.zig`, `regex/regex.zig`, `regex/parse.zig`,
  `regex/exec.zig`
- Modify: `src/libbb_zig/string.zig`, `env.zig`, `util.zig`, `io.zig`,
  `init.zig`
- Create tests: `src/libbb_zig/xfuncs_test.zig`, `getopt_test.zig`,
  `path_test.zig`, `regex_test.zig`

**Interfaces:**
- `getopt32` and `Regex` as in Shared Interfaces.
- `concatPathFile`, `simplifyPath`, `getLastPathComponent`,
  `processEscapeSequence`, `fullRead`, `fullWrite`, `xgetcwd`, `xreadlink`,
  `humanReadable`, `xatou`, `xatoi`, `xatol`.

- [ ] **Step 1: Write failing tests for xfuncs/messages**

Проверить: `die` печатает `<prog>: <msg>\n` в stderr и выходит 1;
`errorMsg` добавляет `strerror(errno)`; `xmalloc(0)` возвращает валидный
пустой slice; `xopen` на отсутствующем файле печатает ошибку и выходит.

- [ ] **Step 2: Implement xfuncs/messages and make tests pass**

Run: `./tools/zig-x86_64-linux-0.17.1/zig build test`
Expected: PASS.

- [ ] **Step 3: Write failing tests for `getopt32`**

Таблица кейсов: `-abc`, `-o val`, `-oval`, `--long`, `--long=val`,
`--long val`, optional arg, `--`, неизвестная опция, `+` (stop at first
non-option), permutation. Ожидаемые `flags`, `optarg`, `index`, `args`
сверяются с референсным `getopt32` (эталонные значения в тесте).

- [ ] **Step 4: Implement `getopt32` and make tests pass**

Семантика — по `reference/busybox/libbb/getopt32.c`; ошибки — через
`errorMsg` с теми же текстами.

- [ ] **Step 5: Write failing tests for path/io helpers**

Кейсы: `concatPathFile("/a/", "b")` → `/a/b`; `simplifyPath("a//b/../c")`
→ `a/c`; `getLastPathComponent("/a/b/")` → `b`; `processEscapeSequence`
(`\n`, `\t`, `\x41`, `\0`); `fullWrite` на pipe с короткими записями.

- [ ] **Step 6: Implement path/io helpers and make tests pass**

- [ ] **Step 7: Write failing regex tests**

Обязательный минимум BRE/ERE: литералы, `.`, `*`, `+`, `?`, `[]`, `[^]`,
`^`, `$`, `\{m,n\}`, `\|`, `\(...\)`, backreferences `\1`, классы
`[[:alpha:]]`, `[[:digit:]]`, `[[:space:]]`. Векторы — из `grep`/`sed`
референса и POSIX examples.

- [ ] **Step 8: Implement regex engine and make tests pass**

Движок: backtracking или Thompson NFA; для backreferences — backtracking.
Ограничение по времени/шагам, чтобы катастрофический backtracking не вешал
процесс; лимит настраивается и возвращает ошибку, а не OOM.

- [ ] **Step 9: Commit**

```bash
git add src/libbb_zig
git commit -m "feat(libbb): core xfuncs, getopt32, path/io and POSIX regex"
```

### Task 7: Coreutils wave (99 applets)

**Files:**
- Create/modify: `src/coreutils/<applet>.zig` (или `src/coreutils/main.zig`
  для мелких)
- Modify: `src/applets.zig` (mainFor)
- Create: `tests/parity/cases/coreutils/<applet>.json`

**Interfaces:**
- Consumes: Task 6 helpers, `getopt32`, `regex`.
- Produces: `pub fn <applet>_main(argc: c_int, argv: [*][*:0]const u8) c_int;`

Апплеты (99):

```text
[ [[ arch base32 base64 basename cat chgrp chmod chown chroot cksum comm cp
crc32 cut date dd df dirname dos2unix du echo env expand expr factor false
fold fsync groups head hostid id install join link ln logname ls md5sum mkdir
mkfifo mknod mktemp mv nice nl nohup nproc od paste printenv printf pwd
readlink realpath rm rmdir seq sha1sum sha256sum sha384sum sha3sum sha512sum
shred shuf sleep sort split stat stty sum sync tac tail tee test timeout
touch tr true truncate tsort tty uname unexpand uniq unix2dos unlink users
usleep uudecode uuencode w wc who whoami yes
```

Разбить на под-волны, каждая — отдельный sub-plan:

- **7a. Простые (45):** `true false echo printf pwd basename dirname cat head tail
  wc tee yes sleep usleep nproc sync fsync link unlink rmdir mkdir mkfifo
  mknod mktemp readlink realpath truncate install printenv env id whoami
  logname groups users who w tty hostid uname arch nice nohup timeout`.
- **7b. Текст/числа (34):** `sort uniq cut fold expand unexpand join nl od paste
  split shuf comm sum cksum crc32 base32 base64 md5sum sha1sum sha256sum
  sha384sum sha3sum sha512sum uudecode uuencode factor expr seq tac tr tsort
  dos2unix unix2dos`.
- **7c. Файлы/метаданные:** `cp mv rm ln ls du df chmod chown chgrp chroot
  touch stat dd date stty shred`.
- **7d. Тестовые встроенные:** `test [ [[` (общий `test_main` с разбором
  POSIX-выражений и `--help`-спецслучаем).

- [ ] **Step 1: Для каждого апплета выполнить P1–P6 протокола.**
- [ ] **Step 2: После под-волны запустить полный набор.**

Run:
```bash
./tools/zig-x86_64-linux-0.17.1/zig build test
python3 scripts/parity/run.py --all --golden tests/parity/golden
```
Expected: все кейсы coreutils PASS; `known-failures.txt` не пополняется.

- [ ] **Step 3: Commit под-волны**

```bash
git add src/coreutils tests/parity/cases/coreutils src/applets.zig
git commit -m "feat(coreutils): wave 7a simple applets"
```

### Task 8: findutils, debianutils, printutils, klibc (14 applets)

**Files:**
- Create: `src/findutils/<applet>.zig`, `src/debianutils/<applet>.zig`,
  `src/printutils/<applet>.zig`, `src/klibc/<applet>.zig`
- Modify: `src/applets.zig`, `build.zig`
- Create: `tests/parity/cases/<category>/<applet>.json`

Апплеты:

```text
find grep egrep fgrep xargs
which pipe_progress run-parts start-stop-daemon
lpd lpq lpr
nuke resume
```

- [ ] **Step 1: Реализовать `find`** (P1–P6): `-name`, `-type`, `-perm`,
  `-size`, `-mtime`, `-newer`, `-exec`, `-print`, `-print0`, `-depth`,
  `-maxdepth`, `-mindepth`, `-prune`, `!`, `-a`, `-o`, скобки.
- [ ] **Step 2: Реализовать `grep`/`egrep`/`fgrep`** (P1–P6): BRE/ERE/fixed,
  `-i -v -c -l -L -n -H -h -o -q -s -r -R -E -F -A -B -C -e -f -w -x`,
  несколько файлов, `--`, stdin.
- [ ] **Step 3: Реализовать `xargs`** (P1–P6): `-0 -n -I -L -P -r -t -x`,
  лимит ARG_MAX, exit-коды.
- [ ] **Step 4: Реализовать debianutils** (`which`, `pipe_progress`,
  `run-parts`, `start-stop-daemon`) по протоколу.
- [ ] **Step 5: Реализовать printutils/klibc** (`lpd`, `lpq`, `lpr`, `nuke`,
  `resume`); для `lpd`/`lpr` использовать pty/локальный сокет-тест, не
  реальный принтер.
- [ ] **Step 6: Прогнать волну и закоммитить**

```bash
python3 scripts/parity/run.py --all --golden tests/parity/golden
git add src/findutils src/debianutils src/printutils src/klibc tests/parity/cases src/applets.zig build.zig
git commit -m "feat(wave1): findutils, debianutils, printutils and klibc applets"
```

---

## Phase 2 — Wave 2: util-linux, e2fsprogs, modutils

### Task 9: libbb filesystem/process (Wave 2 prerequisites)

**Files:**
- Create: `src/libbb_zig/file.zig`, `recursive.zig`, `copy.zig`,
  `process_more.zig`, `identity.zig`, `utmp.zig`, `mtab.zig`
- Modify: `src/libbb_zig/process.zig`, `io.zig`, `util.zig`
- Tests: `src/libbb_zig/file_test.zig`, `recursive_test.zig`,
  `process_more_test.zig`, `identity_test.zig`

**Interfaces:**
- `copyFile(src, dst, opts) !void`, `copyFd(src_fd, dst_fd) !u64`,
  `recursiveAction(path, opts, callback) !void`, `removeFile(path, flags)`,
  `makeDirectory(path, mode)`, `findMountPoint(path) ?[]const u8`,
  `changeIdentity(uid, gid) !void`, `setupEnvironment(...)`, `vforkDaemon()`.

- [ ] **Step 1: Write failing tests for copy/recursive/remove**
- [ ] **Step 2: Implement and pass**
- [ ] **Step 3: Write failing tests for identity/utmp/mtab**
- [ ] **Step 4: Implement and pass**
- [ ] **Step 5: Commit**

```bash
git add src/libbb_zig
git commit -m "feat(libbb): filesystem, recursive walk, identity and utmp helpers"
```

### Task 10: util-linux wave (73 applets)

**Files:**
- Create: `src/util-linux/<applet>.zig`
- Modify: `src/applets.zig`
- Create: `tests/parity/cases/util-linux/<applet>.json`

Апплеты (73):

```text
acpid blkdiscard blkid blockdev cal chrt dmesg eject fallocate fatattr
fatlabel fbset fdflush fdformat fdisk findfs flock freeramdisk fsck.minix
fsfreeze fstrim getopt hd hexdump hwclock ionice ipcrm ipcs last linux32
linux64 losetup lsblk lspci lsusb mdev mesg mkdosfs mke2fs mkfs.ext2
mkfs.minix mkfs.reiser mkfs.vfat mkswap more mount mountpoint nologin
nsenter pivot_root rdate rdev readprofile renice rev rtcwake run-init
script scriptreplay setarch setpriv setsid swaplabel swapoff swapon
switch_root taskset uevent umount unshare uuidgen wall xxd
```

Под-волны:

- **10a. Безопасные:** `acpid blkdiscard blkid blockdev cal dmesg eject
  fallocate fatattr fatlabel fdflush flock freeramdisk fsfreeze fstrim getopt
  hd hexdump hwclock ionice ipcrm ipcs last linux32 linux64 lsblk lspci
  lsusb mesg more mountpoint nologin readprofile renice rev rtcwake script
  scriptreplay setarch setpriv setsid swaplabel taskset uevent uuidgen wall
  xxd`.
- **10b. Привилегированные/разрушительные:** `chrt fbset fdformat fdisk
  findfs fsck.minix losetup mdev mkdosfs mke2fs mkfs.ext2 mkfs.minix
  mkfs.reiser mkfs.vfat mkswap mount nsenter pivot_root rdate rdev run-init
  swapoff swapon switch_root umount unshare` — только
  tmpfs/loop/namespace/контейнер.

- [ ] **Step 1: Для каждого апплета 10a выполнить P1–P6.**
- [ ] **Step 2: Для каждого апплета 10b выполнить P1–P6 с `requires`-кейсами.**
- [ ] **Step 3: Прогнать волну и закоммитить.**

### Task 11: e2fsprogs and modutils (10 applets)

**Files:**
- Create: `src/e2fsprogs/<applet>.zig`, `src/modutils/<applet>.zig`
- Modify: `src/applets.zig`
- Create: `tests/parity/cases/<category>/<applet>.json`

Апплеты:

```text
chattr fsck lsattr tune2fs
depmod insmod lsmod modinfo modprobe rmmod
```

- [ ] **Step 1: Реализовать `chattr`/`lsattr`/`tune2fs`/`fsck`**
  на loop-образе ext2/ext4 в tmpfs; `requires: ["loop", "root"]`.
- [ ] **Step 2: Реализовать modutils** (`depmod`, `insmod`, `lsmod`,
  `modinfo`, `modprobe`, `rmmod`); тесты — на фейковом
  `/lib/modules/<ver>` в песочнице, без реальной загрузки модулей.
- [ ] **Step 3: Прогнать и закоммитить.**

---

## Phase 3 — Wave 3: networking, mailutils

### Task 12: libbb networking (Wave 3 prerequisites)

**Files:**
- Create: `src/libbb_zig/net/socket.zig`, `dns.zig`, `http.zig`, `tls/*.zig`,
  `dhcp.zig`, `inet.zig`
- Modify: `src/libbb_zig/socket.zig`
- Tests: `src/libbb_zig/net/*_test.zig`

**Interfaces:**
- `lookupHost(name, port) ![]Address`, `createAndConnect(addr) !fd`,
  `createAndBind(addr) !fd`, `httpGet(url, out) !void`,
  `tls.Client.init(...)`, `dhcp.parsePacket(...)`.

- [ ] **Step 1: DNS resolver tests** (A/AAAA, CNAME, NXDOMAIN, timeout,
  numeric IPv4/IPv6, `/etc/hosts`, `/etc/resolv.conf` override).
- [ ] **Step 2: Implement resolver.**
- [ ] **Step 3: TCP/UDP helpers tests** (bind/listen/connect/accept,
  partial reads/writes, timeouts, nonblocking).
- [ ] **Step 4: Implement socket helpers.**
- [ ] **Step 5: HTTP client/server tests** (GET, POST, chunked, redirects,
  CGI, auth, range).
- [ ] **Step 6: TLS tests** (AES, RSA, SHA, PRF, certificate parsing,
  ssl_client/ssl_server handshake against local test server).
- [ ] **Step 7: Implement TLS and HTTP.**
- [ ] **Step 8: Commit.**

### Task 13: Networking wave (59 applets)

**Files:**
- Create: `src/networking/<applet>.zig`
- Modify: `src/applets.zig`
- Create: `tests/parity/cases/networking/<applet>.json`

Апплеты (59):

```text
arp arping brctl dhcprelay dnsd dnsdomainname dumpleases ether-wake
fakeidentd ftpd ftpget ftpput hostname httpd ifconfig ifdown ifenslave
ifplugd ifup inetd ip ipaddr ipcalc iplink ipneigh iproute iprule iptunnel
nameif nbd-client nc netcat netstat nslookup ntpd ping ping6 pscan route
slattach ssl_client ssl_server tc tcpsvd telnet telnetd tftp tftpd
traceroute traceroute6 tunctl udhcpc udhcpc6 udhcpd udpsvd vconfig wget
whois zcip
```

Под-волны:

- **13a. Диагностика/адреса:** `arp arping brctl dnsdomainname ether-wake
  hostname ifconfig ifdown ifenslave ifplugd ifup ip ipaddr ipcalc iplink
  ipneigh iproute iprule iptunnel nameif netstat nslookup ping ping6 route
  slattach traceroute traceroute6 tunctl vconfig zcip`.
- **13b. Клиенты:** `ftpget ftpput nc netcat telnet tftp wget whois`.
- **13c. Серверы:** `dhcprelay dnsd dumpleases fakeidentd ftpd httpd inetd
  ntpd pscan tc tcpsvd udhcpc udhcpc6 udhcpd udpsvd telnetd tftpd`.
- **13d. TLS/спец:** `ssl_client ssl_server nbd-client`.

- [ ] **Step 1: Для 13a выполнить P1–P6 в network namespace.**
- [ ] **Step 2: Для 13b выполнить P1–P6 с локальными серверами.**
- [ ] **Step 3: Для 13c выполнить P1–P6 с pty/namespace и таймаутами.**
- [ ] **Step 4: Для 13d выполнить P1–P6 с локальным TLS-сервером.**
- [ ] **Step 5: Прогнать и закоммитить.**

### Task 14: mailutils (4 applets)

```text
makemime popmaildir reformime sendmail
```

- [ ] **Step 1: P1–P6 для каждого; `sendmail` тестировать с локальным
  SMTP-сервером в namespace, не с реальной почтой.**
- [ ] **Step 2: Прогнать и закоммитить.**

---

## Phase 4 — Wave 4: miscutils, procps, console-tools

### Task 15: libbb process/terminal (Wave 4 prerequisites)

**Files:**
- Create: `src/libbb_zig/procps.zig`, `signals_more.zig`, `term/termios.zig`,
  `term/console.zig`, `term/keyboard.zig`, `term/fb.zig`, `pty.zig`
- Tests: `src/libbb_zig/procps_test.zig`, `term/*_test.zig`

**Interfaces:**
- `parseProcStat(pid) !Stat`, `parseProcStatus(pid) !Status`,
  `findPidByName(name) ![]pid_t`, `signalByName(name) !c_int`,
  `safePoll(fds, timeout)`, `pollWithSignals(...)`,
  `readKey(...)`, `Termios.raw()`, `Console.open(...)`.

- [ ] **Step 1: Tests for `/proc` parsers and signal names.**
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Tests for termios/pty/keyboard with pty.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Commit.**

### Task 16: miscutils wave (58 applets)

**Files:**
- Create: `src/miscutils/<applet>.zig`
- Modify: `src/applets.zig`
- Create: `tests/parity/cases/miscutils/<applet>.json`

Апплеты (58):

```text
adjtimex ascii bbconfig bc beep chat conspy crond crontab dc devfsd devmem
fbsplash flash_eraseall flash_lock flash_unlock flashcp getfattr hdparm
hexedit i2cdetect i2cdump i2cget i2cset i2ctransfer inotifyd less lsscsi
makedevs man microcom mim mt nanddump nandwrite partprobe raidautorun
readahead rfkill runlevel rx seedrng setfattr setserial strings time tree ts
ttysize ubiattach ubidetach ubimkvol ubirename ubirmvol ubirsvol
ubiupdatevol volname watchdog
```

Под-волны:

- **16a. Безопасные:** `ascii bbconfig bc beep chat conspy crond crontab dc
  devmem fbsplash flash_eraseall flash_lock flash_unlock flashcp getfattr
  hdparm hexedit i2cdetect i2cdump i2cget i2cset i2ctransfer inotifyd less
  lsscsi makedevs man microcom mim mt partprobe readahead rfkill runlevel rx
  seedrng setfattr setserial strings time tree ts ttysize volname watchdog`.
- **16b. Привилегированные/устройства:** `adjtimex devfsd nanddump nandwrite
  raidautorun ubiattach ubidetach ubimkvol ubirename ubirmvol ubirsvol
  ubiupdatevol` — только loop/tmpfs/namespace.

- [ ] **Step 1: 16a по протоколу.**
- [ ] **Step 2: 16b по протоколу с `requires`.**
- [ ] **Step 3: Прогнать и закоммитить.**

### Task 17: procps wave (24 applets)

**Files:**
- Create: `src/procps/<applet>.zig`
- Modify: `src/applets.zig`
- Create: `tests/parity/cases/procps/<applet>.json`

Список (24): `free fuser iostat kill killall killall5 lsof minips mpstat
nmeter pgrep pidof pkill pmap powertop ps pstree pwdx smemcap sysctl top
uptime vmstat watch`.

- [ ] **Step 1: P1–P6 для неинтерактивных (`free fuser iostat kill killall
  killall5 lsof mpstat nmeter pgrep pidof pmap powertop ps pstree pwdx
  smemcap sysctl uptime vmstat`).**
- [ ] **Step 2: P1–P6 для `top`/`watch` с pty-сценариями и фиксированным
  `/proc`-снимком.**
- [ ] **Step 3: Прогнать и закоммитить.**

### Task 18: console-tools wave (16 applets)

Список: `chvt clear deallocvt dumpkmap fgconsole kbd_mode loadfont setfont
loadkmap openvt reset resize setconsole setkeycodes setlogcons showkey`.

- [ ] **Step 1: P1–P6; для `showkey`/`openvt`/`setfont` — pty и фейковый
  framebuffer/console в namespace.**
- [ ] **Step 2: Прогнать и закоммитить.**

---

## Phase 5 — Wave 5: archival

### Task 19: libbb compression/archive (Wave 5 prerequisites)

**Files:**
- Create: `src/libbb_zig/compression/gzip.zig`, `bzip2.zig`, `xz.zig`,
  `lzma.zig`, `lzop.zig`
- Create: `src/libbb_zig/archive/tar.zig`, `cpio.zig`, `rpm.zig`,
  `dpkg.zig`
- Tests: `src/libbb_zig/compression/*_test.zig`,
  `src/libbb_zig/archive/*_test.zig`

- [ ] **Step 1: gzip/zlib inflate/deflate tests** (RFC vectors, empty,
  multi-member, corrupt CRC, truncated).
- [ ] **Step 2: Implement gzip.**
- [ ] **Step 3: bzip2 tests/implementation.**
- [ ] **Step 4: xz/lzma tests/implementation.**
- [ ] **Step 5: lzop tests/implementation.**
- [ ] **Step 6: tar/cpio/rpm/dpkg tests/implementation** (round-trip,
  long names, sparse, symlinks, permissions, corrupt archives).
- [ ] **Step 7: Commit.**

### Task 20: archival wave (24 applets)

Список: `ar bunzip2 bzcat bzip2 cpio dpkg dpkg-deb gzip gunzip lzcat lzma
lzop lzopcat rpm rpm2cpio tar uncompress unlzma unlzop unxz unzip xz xzcat
zcat`.

- [ ] **Step 1: P1–P6 для каждого; round-trip и golden-файлы.**
- [ ] **Step 2: Прогнать и закоммитить.**

---

## Phase 6 — Wave 6: shell

### Task 21: Regex hardening for shell/editors

**Files:**
- Modify: `src/libbb_zig/regex/*.zig`
- Create: `src/libbb_zig/regex/hardening_test.zig`

- [ ] **Step 1: Добавить тесты на backreferences, вложенные группы,
  alternation, `{m,n}`, character classes, ignore-case, multiline.**
- [ ] **Step 2: Довести движок до прохождения.**
- [ ] **Step 3: Fuzz-тест: случайные паттерны не должны вешать процесс;
  лимит шагов возвращает ошибку.**
- [ ] **Step 4: Commit.**

### Task 22: Shell wave (5 applets)

**Files:**
- Create: `src/shell/lexer.zig`, `parser.zig`, `expand.zig`, `exec.zig`,
  `builtins.zig`, `job.zig`, `ash.zig`, `hush.zig`
- Modify: `src/shell/main.zig`, `src/applets.zig`
- Create: `tests/parity/cases/shell/*.json`, `tests/parity/shell/*.sh`

Апплеты: `ash bash cttyhack hush sh`.

- [ ] **Step 1: Lexer/parser tests** (quotes, escapes, `$VAR`, `${...}`,
  `$(...)`, backticks, `$((...))`, here-docs, `;`, `&&`, `||`, `|`, `&`,
  `if/while/for/case`, functions, redirections, globbing, aliases).
- [ ] **Step 2: Implement lexer/parser.**
- [ ] **Step 3: Expansion/execution tests** (PATH, builtins, `set -e`,
  `trap`, `umask`, `cd`, `export`, `readonly`, `local`, `return`, `exit`,
  subshell, job control).
- [ ] **Step 4: Implement expansion/execution/builtins.**
- [ ] **Step 5: Interactive pty tests** (prompt, `Ctrl-C`, `Ctrl-D`,
  history, tab completion if `FEATURE_TAB_COMPLETION`).
- [ ] **Step 6: Run BusyBox shell testsuite subset** from
  `reference/busybox/testsuite/` and fix divergences.
- [ ] **Step 7: Commit.**

---

## Phase 7 — Wave 7: loginutils, selinux

### Task 23: libbb crypto/login/selinux (Wave 7 prerequisites)

**Files:**
- Create: `src/libbb_zig/crypto/{md5,sha1,sha256,sha512,sha3,des,pw_encrypt,hmac,crc32,base64,uuencode}.zig`
- Create: `src/libbb_zig/login/{passwd,shadow,group,securetty,update_passwd}.zig`
- Create: `src/libbb_zig/selinux.zig`
- Tests: `src/libbb_zig/crypto/*_test.zig`, `login/*_test.zig`

- [ ] **Step 1: Hash tests** (RFC/NIST vectors for MD5, SHA1, SHA256,
  SHA512, SHA3, HMAC, CRC32).
- [ ] **Step 2: Implement hashes.**
- [ ] **Step 3: Password tests** (`$1$`, `$5$`, `$6$`, DES, yescrypt if
  reference supports; vectors from `openssl passwd`, `mkpasswd`, reference
  binary).
- [ ] **Step 4: Implement `pw_encrypt` and login helpers.**
- [ ] **Step 5: SELinux tests** (xattr set/get/list, labels, boolean files)
  on tmpfs with xattr support; `requires: ["selinux"]` for enforcement.
- [ ] **Step 6: Implement SELinux helpers.**
- [ ] **Step 7: Commit.**

### Task 24: loginutils and selinux wave (27 applets)

loginutils (15): `add-shell addgroup adduser chpasswd cryptpw delgroup
deluser getty login mkpasswd passwd remove-shell su sulogin vlock`.

selinux (12): `chcon getenforce getsebool load_policy matchpathcon
restorecon runcon selinuxenabled sestatus setenforce setfiles setsebool`.

- [ ] **Step 1: P1–P6 для loginutils; temp `PASSWD_FILE`/`SHADOW_FILE`,
  pty для `getty`/`login`/`vlock`, контейнер для `su`.**
- [ ] **Step 2: P1–P6 для selinux; `requires: ["selinux"]` где нужно.**
- [ ] **Step 3: Прогнать и закоммитить.**

---

## Phase 8 — Wave 8: init, sysklogd, runit, editors

### Task 25: libbb daemons/term extensions (Wave 8 prerequisites)

**Files:**
- Create: `src/libbb_zig/daemon/{syslog,klog,crond,inetd,httpd,udhcpd,runsv,init}.zig`
- Modify: `src/libbb_zig/term/*.zig`
- Tests: `src/libbb_zig/daemon/*_test.zig`

- [ ] **Step 1: Daemon lifecycle tests** (fork/setsid/pidfile/signals/log
  rotation) in pid namespace.
- [ ] **Step 2: Implement lifecycle helpers.**
- [ ] **Step 3: Config parser tests** (`parse_config`, `syslog.conf`,
  `inittab`, `runsv` service dirs).
- [ ] **Step 4: Implement config parsers.**
- [ ] **Step 5: Commit.**

### Task 26: init, sysklogd, runit, editors, libbb wave (30 applets)

init (6): `bootchartd halt init linuxrc poweroff reboot`.
sysklogd (4): `klogd logger logread syslogd`.
runit (11): `chpst envdir envuidgid runsv runsvdir setuidgid softlimit sv
svc svlogd svok`.
editors (7): `awk cmp diff ed patch sed vi`.
libbb (2): `busybox unit` — `busybox` только при `FEATURE_SH_STANDALONE`,
`unit` только при `UNIT_TEST`.

- [ ] **Step 1: P1–P6 для init/sysklogd/runit в pid/mount namespace.**
- [ ] **Step 2: P1–P6 для `cmp`/`diff`/`patch`.**
- [ ] **Step 3: P1–P6 для `awk`/`sed`** (полные POSIX-выражения и команды,
  regex из Task 21).
- [ ] **Step 4: P1–P6 для `ed`/`vi`** с pty-сценариями и golden-экранами.
- [ ] **Step 5: Прогнать и закоммитить.**

---

## Phase 9 — Parity hardening and release

### Task 27: Full parity hardening

**Files:**
- Modify: `src/**` (удаление заглушек)
- Modify: `tests/parity/known-failures.txt` (должен быть пуст)
- Modify: `README.md`, `docs/superpowers/specs/2026-11-21-busybox-parity-matrix.md`
- Modify: `.gitlab-ci.yml`
- Create: `scripts/parity/fuzz.py`, `scripts/parity/report.py`

- [ ] **Step 1: Remove all stubs.** `grep -rn 'stubNotImplemented' src/`
  → пусто; `grep -rn 'not implemented' src/` → пусто.
- [ ] **Step 2: Run all parity tests against the reference.**

```bash
python3 scripts/parity/run.py --all --ref /tmp/opencode/bb-ref/busybox --zig zig-out/bin/busybox
```
Expected: 0 mismatches; 0 unplanned skips.

- [ ] **Step 3: Fuzz parsers and formats.** `getopt32`, regex, sed, awk,
  shell, tar, cpio, gzip, bzip2, xz, lzop, DNS, DHCP, HTTP, TLS.
  Expected: no crash/hang/OOM; divergences recorded as bugs.

- [ ] **Step 4: Verify metadata and meta-CLI.**

```bash
diff <(./zig-out/bin/busybox --list | sort) <(/tmp/opencode/bb-ref/busybox --list | sort)
diff <(./zig-out/bin/busybox --list-full | sort) <(/tmp/opencode/bb-ref/busybox --list-full | sort)
./zig-out/bin/busybox --version
```
Expected: empty diffs; `--version` печатает banner `BusyBox v1.39.0...` без `multi-call binary`; вывод без аргументов содержит ` multi-call binary.`

- [ ] **Step 5: Verify config gating.** Build with `configs/defconfig` and
  with an all-on config; check `--list` counts 411 and 443; disable a
  feature flag and assert behavior changes in its differential case.

- [ ] **Step 6: Update docs and CI.** README status, matrix totals,
  CI stages: build, unit, parity-golden, manifest/config freshness,
  fuzz-smoke, nightly parity-reference.

- [ ] **Step 7: Final review and commit.**

```bash
git add -A
git commit -m "feat(parity): complete BusyBox 1.39.0 parity"
```

---

## Self-Review Notes

- **Spec coverage:** инфраструктура (Tasks 1–5), конфиг (2), метаданные и
  мета-CLI (3), usage (4), дифференциальный стенд (5), libbb (6, 9, 12, 15,
  19, 21, 23, 25), все 22 категории апплетов (7–26), приёмка (27).
- **Открытые решения для sub-plan'ов волн:** точные опции каждого апплета,
  внутреннее разбиение крупных апплетов, конкретные fuzz-корпуса.
- **Проверка типов:** `Applet`, `Entry`, `Options`, `Regex`, `Match`
  используются одинаково во всех задачах; `mainFor` возвращает `MainFn`,
  `usageFor` — `?[]const u8`.
- **Review Focus:** каждый пункт привязан к тестам в Task 3 (argv[0]/help),
  Task 2/27 (config gating), Task 5 (имена/нормализация), Task 24/26
  (side effects), Task 23/24 (SUID).
