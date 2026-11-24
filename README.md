# busybox-zig

Порт [BusyBox](https://busybox.net/) на Zig: один многофункциональный бинарный
файл `busybox`, который выбирает applet по имени (`argv[0]` или первому
аргументу). Архитектура сохраняется как в оригинале: реестр applet-ов, общая
библиотека `libbb_zig` и конфигурация в стиле Kconfig.

## Статус

Порт applet-ов BusyBox 1.39.0 завершён: в сгенерированном манифесте 443 имени,
в конфигурации `configs/defconfig` включено 411 applet-ов, и все 411
зарегистрированы в `src/applets.zig` с реальными реализациями. Заглушек
(`stubNotImplemented`) не осталось; `stubMain` остаётся только как защитный
fallback для имён, которые отключены конфигурацией или дополнительными
гейтами (`busybox`, `unit`, `minips`, `mkfs.reiser`) и поэтому не попадают
в реестр defconfig.

**Полной совместимости с BusyBox 1.39.0 не объявлено.** Остались честно
учтённые расхождения:

- **Shell (волна Task 22):** 100 из 327 тестов upstream `ash_test`
  расходятся. Приняты как exotics только `[[ ]]`, `<(...)`, stop/resume
  заданий; остальные корзины (ash-misc, ash-vars, quoting, heredoc, redir,
  parsing, psubst, arith, glob) — реальные пробелы в рамках задачи,
  запаркованные решением breaker'а и перенесённые в финальный отчёт.
- **Отложенные minor-пункты** по отдельным applet-ам перечислены в
  `.superpowers/sdd/2026-11-21-full-parity-master-plan/progress.md`.
- Дифференциальный и golden-стенды: по 3860 PASS / 100 capability SKIP /
  0 FAIL. Обнаруженные 10 дрейфов host-state исправлены узкими
  нормализаторами для конкретных полей и перезаписью golden из референса;
  найденные fuzz-ом расхождения записаны в отчёт как баги.

Итоговая проверка и формулировки — в
`.superpowers/sdd/2026-11-21-full-parity-master-plan/task-27-report.md`.

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
./zig-out/bin/busybox --version     # версия (BusyBox v1.39.0.git)

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

Проверка свежести сгенерированных файлов (манифест, конфиг, usage, meta-CLI):

```sh
zig build manifest
zig build config-check
python3 scripts/parity/extract_usage.py --check
python3 scripts/parity/gen_meta_golden.py --check
```

Дифференциальный и golden-стенды (сравнение с референсным бинарником):

```sh
python3 scripts/parity/run.py --all --ref /tmp/opencode/bb-ref2/busybox --zig zig-out/bin/busybox
python3 scripts/parity/run.py --all --golden tests/parity/golden --zig zig-out/bin/busybox
```

Fuzz/smoke парсеров и форматов, а также генерация итогового отчёта:

```sh
python3 scripts/parity/fuzz.py --ref /tmp/opencode/bb-ref2/busybox --zig zig-out/bin/busybox --smoke
python3 scripts/parity/report.py --differential diff.log --golden golden.log --out parity.md
```

## Конфигурация

Applet-ы включаются и отключаются флагами `APPLET_*` в `src/config.zig`
(аналог `.config` в Kconfig); файл генерируется из `configs/defconfig`
командой `zig build gen-config`. Реестр в `src/applets.zig` использует эти
флаги, поэтому аппарат, отключённый в конфигурации, не попадает в бинарный
файл и в `--list`. В defconfig включено 411 applet-ов; во all-on конфигурации
доступны все 443 имени манифеста. `busybox` дополнительно требует
`FEATURE_SH_STANDALONE` и `FEATURE_TAB_COMPLETION`, `unit` — `UNIT_TEST`.

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
- [Матрица совместимости BusyBox 1.39.0](docs/superpowers/specs/2026-11-21-busybox-parity-matrix.md)
- [План порта](docs/superpowers/plans/2026-11-18-busybox-zig-port.md)
- [Журнал выполнения](docs/superpowers/plans/execution-ledger.md)
- [Итоговый отчёт Task 27](.superpowers/sdd/2026-11-21-full-parity-master-plan/task-27-report.md)

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
