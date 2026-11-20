# Busybox → Zig Port — Design Document

## Intent

Перевести весь busybox на Zig, сохраняя семантику и архитектуру:
- Одно бинарное приложение `busybox` (~350 апплетов)
- Апплет-реестр с выбором апплета по имени
- Общая библиотека `libbb` → `libbb_zig`
- Конфигурация, аналогичная Kconfig
- Полная бинарная совместимость

## Goals

- Полный порт всех 705 C-файлов на Zig
- То же самое поведение, те же флаги, те же утилиты
- Одно бинарное `busybox`
- Компиляция через `zig build`
- Конфигурация через `config.zig`

## Non-Goals

- Оптимизация размера бинарного
- Добавление новых апплетов
- Поддержка ARM/MIPS — только x86_64 (пока)
- Кросс-компиляция (пока)
- Изменение API утилит (сохраняем совместимость с POSIX)

## Anti-Goals

- Смешивание C и Zig в одном бинарном (никаких C-обёрток)
- Отказ от одно-бинарного подхода
- Переписывание на другой язык (C++ и т.д.)

## Constraints

- Busybox лицензия: GPLv2+
- Zig 0.17.1 (установлен в `tools/`)
- Linux x86_64 (на начальном этапе)
- Необходимо сохранить POSIX-совместимость утилит

## Approaches

| Подход | Описание | Плюсы | Минусы |
|--------|----------|-------|--------|
| **A: 1:1 C → Zig** | Каждый C-файл → Zig-модуль, та же архитектура | Полная семантика, одно бинарное | Много работы |
| B: Zig-native | Отдельные бинарные для каждого апплета | Проще | Теряется фишка busybox |
| C: Гибрид | Часть в Zig, часть в C | Быстрее | Не полный порт |

**Выбран: A** — полный порт с сохранением архитектуры.

## The How — decided in the conversation

### 1. Структура проекта

```
busybox-zig/
├── reference/
│   └── busybox/          # исходники C (для референса)
├── tools/
│   └── zig-x86_64-0.17.1/ # Zig toolchain
├── src/
│   ├── libbb_zig/         # общая библиотека (аналог libbb)
│   ├── applets/           # реестр апплетов
│   ├── coreutils/         # coreutils (86 апплетов)
│   ├── util-linux/        # util-linux (110 апплетов)
│   ├── networking/        # networking (88 апплетов)
│   ├── miscutils/         # miscutils (47 апплетов)
│   ├── procps/            # procps (20 апплетов)
│   ├── shell/             # ash/hush (11 апплетов)
│   ├── loginutils/        # loginutils (12 апплетов)
│   ├── arch/              # arch (0 апплетов)
│   ├── findutils/         # findutils (3 апплета)
│   ├── console-tools/     # console-tools (15 апплетов)
│   ├── debianutils/       # debianutils (4 апплета)
│   ├── e2fsprogs/         # e2fsprogs (5 апплетов)
│   ├── editors/           # editors (9 апплетов)
│   ├── init/              # init (3 апплета)
│   ├── mailutils/         # mailutils (5 апплетов)
│   ├── modutils/          # modutils (9 апплетов)
│   ├── printutils/        # printutils (2 апплета)
│   ├── selinux/           # selinux (11 апплетов)
│   ├── sysklogd/          # sysklogd (5 апплетов)
│   ├── klibc-utils/       # klibc-utils (4 апплета)
│   ├── runit/             # runit (5 апплетов)
│   └── main.zig           # точка входа (аналог appletlib.c)
├── zig.zon                # Zig пакет
└── zig.build              # zig build system
```

### 2. Конфигурация

`config.zig` — файл с перечислением включённых апплетов:

```zig
pub const config = struct {
    pub const CAT = true;
    pub const LS = true;
    pub const CATV = true;
    pub const CATN = true;
    // ... и так далее для всех апплетов
};
```

Это аналог `.config` busybox. Каждый апплет проверяет `config.NAME` перед компиляцией.

### 3. Библиотека libbb_zig

Аналог `libbb/` с общими функциями:
- `string.zig` — `strcmp`, `strdup`, `snprintf`, `strsep`, `strchr`, etc.
- `io.zig` — `read`, `write`, `open`, `close`, `fdopen`
- `process.zig` — `fork`, `exec`, `waitpid`, `signal`, `setuid`, `setgid`
- `memory.zig` — `malloc`, `calloc`, `realloc`, `free`
- `socket.zig` — `socket`, `bind`, `connect`, `accept`
- `hash.zig` — SHA256, MD5, CRC32
- `util.zig` — `human_readable`, `duration`, `isqrt`, `bbunit`
- `error.zig` — `perror`, `die`, `warn`

### 4. Апплет-реестр

```zig
pub const Applet = struct {
    name: []const u8,
    main: *const fn (argc: c_int, argv: [*][*]u8) c_int,
    flags: AppletFlags,
};

pub const applets = [_]Applet{
    .{ .name = "cat", .main = &cat_main, .flags = .{} },
    .{ .name = "ls",  .main = &ls_main,  .flags = .{} },
    // ...
};
```

### 5. Точка входа (main.zig)

Аналог `appletlib.c`:
- Парсит `argv[0]` для определения апплета
- Ищет апплет в реестре
- Вызывает `applet.main(argc, argv)`

### 6. Build system

`zig build` с двумя целями:
- `zig build install` — собрать `busybox`
- `zig build help` — показать список апплетов

### 7. Перевод C → Zig

Каждый C-файл → Zig-модуль с правилами:
- `#define` → `const` или `fn`
- `struct` → `struct` (прямой перевод)
- `extern "libc"` → `@import("builtin").os.posix` или `@cImport`
- `static inline` → `inline fn`
- `#include` → `@import`
- `__attribute__((packed))` → `@Type(.{ .StructLayout = .Manual })` или `@align`
- `__builtin_bswap32` → `@byteSwap(u32, x)`

### 8. Порядок переноса

1. **libbb_zig** (162 файла) — фундамент, без него ничего не заработает
2. **Апплет-реестр + main.zig** — скелет, чтобы проверить что запуск работает
3. **Простые апплеты** (ls, cat, echo) — чтобы протестировать pipeline
4. **Категории по приоритету**:
   - coreutils (86) — самые важные
   - util-linux (110) — системные
   - networking (88) — сетевые
   - miscutils (47) — misc
   - procps (20) — процессы
   - shell (11) — ash/hush
   - loginutils (12) — auth
   - Остальное по мере необходимости

## Builder Check Answers

### 1. C-хедеры без Zig-эквивалента (`#include`)
**Решение:** Используем `@cImport` для хедеров, которые имеют Zig-эквиваленты (libc — `string.h`, `stdlib.h`, `stdio.h` и т.д.). Для kernel-хедеров (`asm/unistd.h`, `asm/ptrace.h`, `linux/` и т.п.) используем `@cImport` — это единственный реалистичный путь. Kernel-хедеры специфичны для архитектуры и не имеют альтернатив.

### 2. C-препроцессор (`#ifdef`, `#if defined`)
**Решение:** Zig не имеет препроцессора. Условная компиляция реализуется через `@import("config").NAME` — каждый `#ifdef` заменяется на `if (config.NAME)`. `#if defined(FEATURE_X) && ENABLE_Y` → `if (config.FEATURE_X and config.ENABLE_Y)`. Это меняет подход к build-system: config.zig должен генерироваться скриптом.

### 3. `extern` декларации между модулями
**Решение:** Zig имеет систему модулей. `extern int errno;` → `@import("builtin").os.posix.errno` (или экспорт из `libbb_zig`). `extern char *optarg;` → экспорт из модуля парсинга аргументов. `extern`-переменные собираются в `libbb_zig` и экспортируются как `pub`.

### 4. `static inline` и макросы
**Решение:** 
- `#define MACRO(x,y) ...` → `inline fn macro(x: type, y: type) type { ... }`
- `static inline int func(...)` → `inline fn func(...) type { ... }`
- Макросы, которые возвращают значение в выражениях, — только `inline fn`
- Макросы, которые работают с типами/размерами (`ARRAY_SIZE`, `ALIGN`), — `const` или `inline fn`

### 5. `__attribute__`
**Решение:**
- `__attribute__((packed))` → `@Type(.{ .StructLayout = .Manual })`
- `__attribute__((aligned(N)))` → `comptime struct { ... } @align(N)`
- `__attribute__((weak))` → `extern "c" fn name(...) type` (Zig по умолчанию weak для внешних символов)
- `__attribute__((used))` → `@export(..., .{ .symbol_visibility = .hidden })`
- `__attribute__((constructor))` / `__attribute__((destructor))` → `@export(..., .{ .init_priority = N })`
- `__attribute__((section("name")))` → `@export(..., .{ .section_name = "name" })`

### 6. `#pragma`
**Решение:** Игнорируем.
- `#pragma GCC optimize` — Zig оптимизирует самостоятельно
- `#pragma GCC poison` — Zig не имеет аналога, игнорируем
- `#pragma once` — Zig не имеет аналога, игнорируем

### 7. `__builtin_*` функции
**Решение:**
- `__builtin_bswap32` → `@byteSwap(u32, x)`
- `__builtin_expect` → `@expect` (Zig имеет это)
- `__builtin_constant_p` → `std.mem.isConstant` или `comptime`
- `__builtin_popcount` → `@popCount(u32, x)`
- `__builtin_clz` / `__builtin_ctz` → `@clz(u32, x)` / `@ctz(u32, x)`
- `__builtin_return_address` → `@returnAddress()`
- `__builtin_frame_address` → `@frameAddress()`
- `__builtin_memcpy` → `@memcpy`
- `__builtin_memset` → `@memset`

## Calls I made (my decisions)

1. **Конфигурация**: `config.zig` вместо Kconfig — проще для Zig, но менее масштабируемо. Можно будет добавить скрипт для генерации.
2. **Структура папок**: плоская — каждая категория в отдельной папке, как в оригинале.
3. **Первый этап**: libbb_zig + скелет + 1-2 апплета (cat/ls) для проверки pipeline.
4. **C-инклуды**: минимизируем `@cImport` для libc-хедеров, используем для kernel-хедеров.
5. **Архитектура**: сохраняем одно бинарное, апплет-реестр, выбор по имени.
6. **Условная компиляция**: `config.NAME` вместо `#ifdef` — это ключевое изменение архитектуры.
7. **Зависимости**: Zig не имеет стандартной библиотеки для некоторых вещей (например, SHA256), нужно будет написать свои реализации.
