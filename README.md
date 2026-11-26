# ekko-docker

Кастомный Docker-образ [Ekko Studio](https://github.com/EKKOLearnAI/ekko-studio):
починенные права на `$HOME`, полноценный надзор s6-overlay (PID 1 = `/init`),
предустановленный `gh` CLI. Ветка по умолчанию — `master`.

## Зачем

В апстримном образе (`ekkoye8888/hermes-web-ui` поверх `nousresearch/hermes-agent`):

1. **`$HOME` сломан.** `ENV HOME=/home/agent`, но каталог никто не создаёт и не `chown`'ит —
   он остаётся `root:root 755`. Рантайм не может создать `~/.config`, `~/.local`,
   `~/.bashrc`, `~/.ssh`.
2. **s6 выброшен.** В `nousresearch/hermes-agent` есть s6-overlay 3.2.3 с сервисами
   `main-hermes`, `dashboard` и `profile-gateways` (вложенный `s6-svscan`, который
   надзирает per-profile гейтвеи в `/run/hermes-service`). Но `start-studio-all.sh`
   делает `exec node ...`, поэтому PID 1 — это `node`, а не `/init`. Дерево надзора
   мертво.
3. **Следствие для cron.** `hermes gateway install` определяет менеджер сервисов
   (`detect_service_manager()` → `_s6_running()` → `container`) и отказывается:
   «the container runtime is your service manager». Гейтвей приходится запускать
   руками в фоне, он не переживает падение и не восстанавливается после рестарта.

Этот образ закрывает все три пункта.

## Что делает Dockerfile

1. Ребейз на **опубликованный** тег Studio (сборка из исходников — `npm ci` + Vite,
   десятки минут и гигабайты; apt-слой — 1–2 минуты).
2. Debian-утилиты: `jq yq less tree htop unzip zip rsync gnupg ripgrep fd-find bat fzf
   sqlite3 vim-tiny procps` (+ симлинки `fd`, `bat`).
3. **`gh`** из официального apt-репозитория `cli.github.com` (2.106.0; в `trixie/main`
   только 2.46.0).
4. Создаёт и `chown`'ит `/home/agent`, готовит `.config .local .cache .ssh` и `.bashrc`.
5. Ставит s6-сервис `studio` в bundle `user` и возвращает `ENTRYPOINT /init`.

## Контракт рантайма (важно, это breaking change)

**Контейнер должен стартовать как root.** Это не «root ради root»:

- s6 stage2 (`/etc/cont-init.d/01-hermes-setup`) делает UID/GID remap (`usermod -u`),
  `chown` data-volume и seed конфигов — всё это требует root;
- `stage2-hook.sh` **явно отвергает** запуск с произвольным `--user <uid>` и
  подсказывает правильный путь;
- сам сервер работает **не** под root: `docker/s6-rc.d/studio/run` делает
  `exec /command/s6-setuidgid hermes node ...`.

Поэтому вместо `user:` uid передаётся переменными:

```yaml
environment:
  - HERMES_UID=1000
  - HERMES_GID=1000
```

`Dockerfile` ставит `ENV HERMES_UID=${RUNTIME_UID}`, так что если собирать под тот же
uid, что и запускать, — переменные можно не задавать.

Второе следствие: **`--user 1234` больше не поддерживается** (в предыдущей версии
образа был OpenShift-паттерн). Взамен получаем настоящий надзор и работающий
`hermes gateway install`.

## Что даёт s6

- Studio — supervised longrun: упал сервер → s6 перезапускает его.
- `finish`-скрипт гасит контейнер, когда сервис умер окончательно, поэтому
  `restart: unless-stopped` продолжает работать как раньше.
- Гейтвеи: `hermes gateway install` → `hermes -p <profile> gateway start` создаёт слот
  в `/run/hermes-service`, его надзирает `profile-gateways`, а
  `cont-init.d/02-reconcile-profiles` восстанавливает слоты из data-volume при загрузке.
  Cron больше не зависит от вручную запущенного процесса.

## Важно про теги

Нумерация тегов на Docker Hub **немонотонна**: `v1.1.0` опубликован 2026-11-17,
`v0.8.30` — 2026-11-21, `latest` указывал на `v0.8.30`. Проверяй дату сборки:

```bash
./scripts/check-base.sh                  # список тегов
./scripts/check-base.sh v1.1.0 v0.8.30   # created для конкретных
```

Скрипт работает через registry API — docker-демон не нужен.

## Сборка и проверка

```bash
make build                     # RUNTIME_UID/RUNTIME_GID берутся из id -u / id -g
make verify                    # грузит контейнер, проверяет всё, гасит
make verify-quick              # только проверки слоя образа
```

`verify.sh` поднимает реальный контейнер и проверяет:

| проверка | почему |
|---|---|
| default user = root | иначе stage2 не сделает remap |
| сервис `studio` в bundle | иначе `/init` ничего не запустит |
| PID 1 = `/init` | иначе s6 inert |
| `s6-svstat` = up | сервис реально поднялся |
| uid процесса = `HERMES_UID` | non-root соблюдён |
| `$HOME` писабелен для `hermes` | исходный баг закрыт |
| `/home/agent/.hermes` owner = uid | stage2 chown сработал |
| `gateway install` ≠ container-backend | цель варианта B достигнута |
| контейнер умирает вместе с сервисом | restart-политика не сломана |

## Подключение к деплою

```bash
docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' <container>
```

Затем `compose.override.example.yml` → `docker-compose.override.yml`. Из override
обязательно убрать `user:` (см. контракт рантайма) и добавить `HERMES_UID`.

## Что остаётся эфемерным

Volume'ы только два: `/home/agent/.hermes` и `/home/agent/.hermes-web-ui`. Всё
остальное под `$HOME` — слой образа: переживает `restart`, не переживает `compose down`.
Логины CLI (`gh auth`, `~/.ssh`) слетают при пересоздании; для персистентности
монтируй `/home/agent` целиком.

## Публикация образов

CI (`.github/workflows/build.yml`): hadolint → сборка → `verify.sh` → **push только
если смоук-тест прошёл**.

### GHCR — ничего не нужно

Пуш идёт от `GITHUB_TOKEN`, который workflow получает сам. В репозитории дефолтные
права токена — `read`, поэтому нужен явный блок:

```yaml
permissions:
  contents: read
  packages: write
```

Пакет появляется как `ghcr.io/pravets/ekko-docker`. Для приватного репозитория он
тоже приватный (видимость наследуется).

Тянуть на хосте:

```bash
echo "$PAT" | docker login ghcr.io -u pravets --password-stdin   # PAT: read:packages
docker pull ghcr.io/pravets/ekko-docker:latest
```

`gh` для этого нужен scope `read:packages`; текущая авторизация в контейнере его не
имеет (`repo`, `workflow`, `gist`, `read:org`) — если понадобится смотреть пакеты
через `gh api`, нужен `gh auth refresh -h github.com -s read:packages`.

### Docker Hub — нужны два секрета

Аккаунт Docker Hub + PAT (Account settings → Personal access tokens → **Read & Write**),
затем в репозитории: Settings → Secrets and variables → Actions:

| секрет | значение |
|---|---|
| `DOCKERHUB_USERNAME` | логин на Hub |
| `DOCKERHUB_TOKEN` | PAT, не пароль |

Workflow проверяет их наличие и, если их нет, просто публикует только в GHCR
(в лог пишется notice). Появятся — включится автоматически, править YAML не нужно.

Важно про тарифы: на бесплатном плане Docker Hub разрешён **1 приватный**
репозиторий образов (публичные — без ограничений). Лимиты pull'ов (100/6ч анонимно,
200/6ч авторизованно) касаются только скачивания с Hub.

### Теги, которые получаются

| триггер | теги |
|---|---|
| push в `master` | `latest`, `master`, `sha-<short>`, `studio-v0.8.30` |
| тег `v1.2.3` | `v1.2.3`, `sha-<short>`, `studio-v0.8.30` |
| PR | ничего не публикуется |

Собирается только `linux/amd64`. Для `arm64` нужен `docker/setup-qemu-action` и
`platforms: linux/amd64,linux/arm64` (базовый образ arm64 содержит), но тогда
`load: true` для verify невозможен — пришлось бы разделять сборку и смоук-тест.
