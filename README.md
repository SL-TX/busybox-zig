# busybox-zig

Порт [BusyBox](https://busybox.net/) на Zig: один многофункциональный бинарный
файл `busybox`, который выбирает applet по имени (`argv[0]` или первому
аргументу). Архитектура сохраняется как в оригинале: реестр applet-ов, общая
библиотека `libbb_zig` и конфигурация в стиле Kconfig.

## Статус

Проект в активной разработке. В `src/config.zig` объявлено 316 applet-ов, в
реестре `src/applets.zig` зарегистрировано более 250. Часть applet-ов пока
представлена заглушками (`stubNotImplemented`) и постепенно заменяется
реальными реализациями.

## Требования

- Zig **0.17.1**
- Linux x86_64

CI использует готовый образ `registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1`
с зашитым тулчейном — пайплайн не зависит от доступности ziglang.org.
Локально можно использовать системный Zig 0.17.1 или тот же образ:

```sh
docker run --rm -v "$PWD:/workspace" \
  registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1 zig build
```

## Сборка

```sh
zig build
```

Готовый бинарный файл: `zig-out/bin/busybox`.

## Запуск

```sh
./zig-out/bin/busybox --list        # список applet-ов
./zig-out/bin/busybox echo "hello"  # через аргумент
./zig-out/bin/busybox --version     # версия (1.36.1)

# многофункциональный режим: имя символической ссылки задаёт applet
ln -s busybox zig-out/bin/echo
./zig-out/bin/echo "hello"
```

## Тесты

```sh
zig build test
```

Тестовый стенд подключает те же модули, что и исполняемый файл, и проверяет
реестр applet-ов (`src/applets_test.zig`, `src/tests.zig`).

## Конфигурация

Applet-ы включаются и отключаются флагами `APPLET_*` в `src/config.zig`
(аналог `.config` в Kconfig). Реестр в `src/applets.zig` использует эти флаги
через `putIfEnabled`, поэтому аппарат, отключённый в конфигурации, не попадает
в бинарный файл.

## Структура

| Путь | Назначение |
| --- | --- |
| `src/main.zig` | Точка входа, диспетчеризация applet-ов |
| `src/applets.zig` | Реестр applet-ов |
| `src/config.zig` | Флаги конфигурации `APPLET_*` |
| `src/libbb_zig/` | Общая библиотека (`libbb` → Zig) |
| `src/coreutils/`, `src/util-linux/`, `src/networking/`, `src/miscutils/`, `src/procps/`, `src/shell/`, `src/loginutils/`, `src/remaining/` | Категории applet-ов |
| `reference/` | C-исходники BusyBox для референса (не в репозитории) |
| `tools/` | Локальный инструментарий Zig (не в репозитории) |
| `docs/superpowers/` | Проектная документация, спецификация и план порта |
| `ci/Dockerfile` | Образ CI с зафиксированным тулчейном Zig |

## Документация

- [Спецификация порта](docs/superpowers/specs/2026-11-18-busybox-zig-port-design.md)
- [План порта](docs/superpowers/plans/2026-11-18-busybox-zig-port.md)
- [Журнал выполнения](docs/superpowers/plans/execution-ledger.md)

## Образ CI

Образ собирается из локального тулчейна в `tools/` (каталог не версионируется),
поэтому сборка не требует скачивания Zig:

```sh
docker build -f ci/Dockerfile \
  -t registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1 .
docker push registry.sl-tx.ru/develop/busybox-zig/zig:0.17.1
```

При смене версии Zig обнови `ZIG_VERSION` в `ci/Dockerfile`, тег в
`.gitlab-ci.yml` и опубликуй образ под новым тегом.

## Лицензия

GPLv2+ — как и оригинальный BusyBox.
