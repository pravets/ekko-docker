# ekko-docker

Кастомный Docker-образ [Ekko Studio](https://github.com/EKKOLearnAI/ekko-studio)
с починенными правами на `$HOME`, non-root рантаймом и предустановленным `gh` CLI.

## Зачем

В апстримном образе (`ekkoye8888/hermes-web-ui`, поверх `nousresearch/hermes-agent`):

- `ENV HOME=/home/agent`, но каталог `/home/agent` **никто не создаёт и не `chown`'ит** —
  он остаётся `root:root 755`. Рантайм под uid 1000 не может создать `~/.config`,
  `~/.local`, `~/.bashrc`, `~/.ssh`.
- Образ заканчивается на `USER root`, а деплой стартует контейнер под «голым» числовым
  uid без записи в `/etc/passwd`.
- В `/etc/passwd` есть только `hermes` (uid **10000**, home `/opt/data`), а `/usr/local/bin`
  принадлежит uid **1001** — ни один не совпадает с рантаймом.

Этот образ закрывает все три пункта на этапе сборки.

## Что делает Dockerfile

1. Ребейз на **опубликованный** тег Studio (не сборка из исходников: `npm ci` + Vite —
   десятки минут и гигабайты; слой с apt — 1–2 минуты).
2. Debian-утилиты: `jq yq less tree htop unzip zip rsync gnupg ripgrep fd-find bat fzf
   sqlite3 vim-tiny procps` (+ симлинки `fd`/`bat`).
3. **`gh`** из официального apt-репозитория `cli.github.com`
   (2.105.0; в `trixie/main` только 2.46.0).
4. Учётка `agent` с нужным uid/gid, `chown` на `/home/agent`, готовые
   `.config .local .cache .ssh` и `.bashrc`.
5. `USER <uid>:<gid>` в конце — **non-root по умолчанию**.

Volume'ы `/home/agent/.hermes` и `/home/agent/.hermes-web-ui` не трогаются: они
монтируются поверх слоя и сохраняют свои права.

## Важно про теги

Нумерация тегов на Docker Hub **немонотонна**: `v1.1.0` опубликован 2026-11-17,
`v0.8.30` — 2026-11-21, и `latest` указывал на `v0.8.30`. Проверяй дату сборки,
а не строку версии:

```bash
./scripts/check-base.sh                  # список тегов
./scripts/check-base.sh v1.1.0 v0.8.30   # created для конкретных тегов
```

Скрипт работает через registry API — docker-демон не нужен.

## Сборка

```bash
# uid/gid должны совпадать с тем, под чем реально стартует контейнер:
docker inspect -f '{{.Config.User}} | {{.HostConfig.User}}' <container>

make build RUNTIME_UID=1000 RUNTIME_GID=1000
# или
docker build --build-arg RUNTIME_UID=1000 --build-arg RUNTIME_GID=1000 \
  -t ekko-docker:v0.8.30 .
```

Проверка, что права действительно починились (нужен docker-демон):

```bash
make verify IMAGE=ekko-docker:v0.8.30
```

## Подключение к деплою

Апстримный compose берёт образ из `WEBUI_IMAGE`. Скопируй
`compose.override.example.yml` рядом с рабочим compose как
`docker-compose.override.yml`, либо передай `-f` явно.

Сначала проверь, **какой** compose-файл реально используется:

```bash
docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' <container>
```

Если его генерирует само приложение Studio, правка может затираться при обновлении —
тогда надёжнее держать override отдельно.

## Что остаётся эфемерным

Volume'ы только два: `/home/agent/.hermes` и `/home/agent/.hermes-web-ui`.
Всё остальное под `$HOME` — слой образа/контейнера: переживает `restart`, но не
`compose down`. Значит:

- утилиты, вшитые в образ, вернутся после пересборки — это нормально;
- `apt install` руками внутри контейнера смысла не имеет;
- **логины CLI** (`gh auth`, `~/.ssh`, `~/.config`) слетают при пересоздании. Нужна
  персистентность — монтируй `/home/agent` целиком (тогда права ведёт хостовый uid,
  и слой с `chown` перекрывается).

Для «положить и забыть» без пересборки есть volume-путь `~/.hermes/bin` — он в `PATH`.

## CI

`.github/workflows/build.yml`: hadolint + сборка + `scripts/verify.sh` под uid 1000.
