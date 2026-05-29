<div align="center">

```
 ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗
 ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗
 ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝
 ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗
 ██║ ╚████║╚██████╔╝██████╔╝███████╗██║  ██║
 ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝
                                    by popokole
```

**Установщик и менеджер нод Remnawave с in-kernel DDoS-фильтром, BBR-тюнингом и Telegram-управлением.**

</div>

---

## установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
sudo noder install
```

3-4 минуты — и у вас работающая нода Remnawave с защитой, мониторингом и Telegram-ботом. Дальше — `sudo noder` и навигация по меню.

```
═══════════════════════════════════════════════
   N O D E R   ·   Remnawave Node Manager
                                     by popokole
═══════════════════════════════════════════════

  Статус: ● установлена (FI-1)

  [ 1] Установить ноду
  [ 2] Управление нодой (start / stop / restart)
  [ 3] Состояние и health-check
  [ 4] Просмотр логов
  [ 5] Обновление (Xray / образ)
  [ 6] Перегенерация параметров (regen)
  [ 7] Показать конфигурацию ноды
  [ 8] Изменить IP/домен панели
  [ 9] Обновить геолисты сейчас
 [10] Backup / Restore
 [11] Настройки Telegram-бота
 [12] SSH hardening (опционально)
 [13] Интеграция с API панели (опционально)
 [14] Удалить ноду
 [15] Ядро · BBRv3 · DDoS-фильтр (XanMod)
  [ 0] Выход
```

---

## Что внутри

| | |
|---|---|
| **In-kernel DDoS-фильтр** | nftables dynamic sets вместо fail2ban-цикла «лог → regex → exec». Port-scan honeypot + SYN-flood meter. ~20× быстрее в hot-path |
| **BBR + sysctl-тюнинг** | TCP Fast Open, 67MB буферы, conntrack 524K, ephemeral port range 10000-65000 |
| **Telegram-бот** | long-polling демон с inline-кнопками, whitelist, один бот на парк нод |
| **Auto-обновления** | weekly-проверка Xray и образа через GitHub/Docker Hub, алерт с кнопкой «Обновить сейчас» в TG |
| **Auto-backup** | daily tar.gz state+compose+nft+fail2ban, ротация 30 копий |
| **Гео-списки** | xray geosite/geoip + nftables blocklist, daily-синхронизация с валидацией |
| **Regen** | смена short-id / dest / port / keypair одной командой + пошаговая инструкция в TG |
| **Health-check** | контейнер, xray, порт, TLS-handshake до dest, доступность панели, conntrack, размер логов, детектор аномалий трафика (упал до 0 на 4+ часа → алерт) |

---

## Архитектура

```
┌──────────────────┐                           ┌──────────────────┐
│  Remnawave       │  ─── push xray config ──▶ │   remnanode      │
│  Panel           │ ◀── push juser updates ── │   container      │
│  (где угодно)    │                           │  (xray inside)   │
└──────────────────┘                           └────────┬─────────┘
        ▲                                               │
        │ панель в whitelist nft                        │ bind 0.0.0.0:443
        │                                               │
        │                                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                            HOST KERNEL                            │
│                                                                   │
│  ┌────────────┐  nft INPUT chain  ┌─────────────────────────┐   │
│  │ public 443 │ ────────────────▶ │  scanners4 (24h ban)    │   │
│  │ public 22  │ ────────────────▶ │  synflood4 (1h ban)     │   │
│  │ NODE_PORT  │ ────────────────▶ │  blocklist4 (CIDR set)  │   │
│  └────────────┘                   └─────────────────────────┘   │
│                                                                   │
│  sysctl: bbr | TFO=3 | tcp_rmem=67M | conntrack_max=524K          │
└──────────────────────────────────────────────────────────────────┘
        ▲
        │ управление + алерты
        │
┌───────┴──────────────┐                 ┌─────────────────────┐
│  Вы (через SSH)      │   Telegram      │  noder-tg.service   │
│  $ sudo noder        │ ◀───────────────│  (long-polling)     │
│                      │   /status       │                     │
└──────────────────────┘                 └─────────────────────┘
```

---

## Установка

### Что нужно от вас

- **VPS** с чистым Ubuntu 22.04 или 24.04 (x86_64 или ARM64)
- **Root-доступ** по SSH
- **Уже работающая Remnawave Panel** где-то ещё (этот скрипт ставит только **ноду**, не панель)
- **Docker-compose snippet** из панели — кнопка «Copy docker-compose.yml» в `Nodes → + Add Node`
- 3-4 минуты времени

### Первый запуск

```bash
# 1. Подключиться к VPS
ssh root@<IP-vasi-VPS>

# 2. Запустить bootstrap
bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
```

Bootstrap качает tarball репозитория, кладёт в `/opt/noder/`, регистрирует `/usr/local/bin/noder`.

После:

```bash
sudo noder install
```

Откроется мастер. По шагам:

```
┌─────────────────────────────────────────────┐
│ 1. Имя ноды                  FI-1           │
│ 2. Режим маскировки          reality        │
│ 3. Dest-маска                www.swift.com  │
│ 4. Reality-порт              443            │
│ 5. IP/домен панели           1.2.3.4        │
│ 6. NODE_PORT + SECRET_KEY    из compose     │
│ 7. Telegram (опционально)    пропустить     │
│ 8. SSH hardening (опц.)      пропустить     │
│ 9. Kernel/BBRv3              да             │
│ 10. Подтверждение            y              │
└─────────────────────────────────────────────┘
```

### Установка одной строкой (для автоматизации)

```bash
sudo noder install --random \
  --name FI-1 \
  --panel-host panel.example.com \
  --compose-file /root/panel-compose.yml \
  --no-tg \
  --yes
```

`--random` означает «всё что не задано — сгенерируй автоматически» (имя суффиксом, маска из пула, ключи). `--compose-file` читает compose из файла вместо paste в терминал.

### Откуда взять `panel-compose.yml`

В Remnawave Panel → `Nodes` → `+ Add Node` → жмёте «Copy docker-compose.yml» → на VPS:

```bash
sudo nano /root/panel-compose.yml
# вставляете compose из буфера, Ctrl+O Enter Ctrl+X
```

В нём важны две строки:

```yaml
environment:
  - NODE_PORT=2222
  - SECRET_KEY="eyJub2RlQ2VydFBlbSI6Ii0t...="
```

`noder` распарсит файл и подложит в свой `/opt/remnanode/docker-compose.yml` с правильным форматом + добавит `cap_add NET_ADMIN`, `ulimits`, `volumes`.

### Что происходит во время установки

```
[info] Запуск установки…
[info] Проверка системы
[ok]   ОС: ubuntu 24.04
[ok]   Архитектура: amd64
[info] Устанавливаю пакеты: python3-venv fail2ban ...
[ok]   Pre-flight завершён
[info] Установка Docker
[ok]   Docker установлен: Docker version 24.0.7
[info] Генерация ключей Reality
[info] Сохранение state.json
[info] Создание docker-compose ноды
[ok]   compose записан: /opt/remnanode/docker-compose.yml
[ok]   .env записан:    /opt/remnanode/.env
[info] Применяю kernel-тюнинг + XanMod (если совместимо)
[warn] XanMod репозиторий недоступен (CDN временно лежит)
[warn] Пропускаю XanMod (репо недоступен), применяю sysctl + BBR(v1)
[ok]   sysctl применён
[info] Применение правил firewall
[ok]   nftables применён
[ok]   fail2ban настроен (только jail для SSH)
[info] Скачиваю geo-файлы для xray
[ok]   geosite.dat обновлён
[ok]   geoip.dat обновлён
[info] Запуск контейнера ноды
[ok]   Контейнер remnanode запущен
[info] Установка systemd-таймеров
[ok]   noder-updates.timer  (воскресенье 04:00 МСК)
[ok]   noder-blocklists.timer  (01:00 МСК ежедневно)
[ok]   noder-backup.timer  (03:30 ежедневно)
[info] Финальная проверка

═══════════════════════════════════════════════
  Параметры для вставки в Remnawave Panel
                                     by popokole
═══════════════════════════════════════════════

Нода:           FI-1
Адрес ноды:     1.2.3.4:2222
SECRET_KEY:     (уже введён вами)

Inbound VLESS-Reality:
  Порт:          443
  Dest:          www.swift.com:443
  Server names:  www.swift.com
  Private key:   ABcdEfghIjKlMnOpQrSt-uvwx_yz1234567890ABCdef0
  Public key:    ZYxwVuTsRqPoNmLkJiHgFeDcBa-9876543210_aBcDef
  Short ID:      a1b2c3d4
  Flow:          xtls-rprx-vision

Скопируйте эти параметры в Config Profile в панели.
[ok] Нода установлена
```

Эти параметры идут в **Remnawave Panel → Config Profiles → Edit Config**.

---

## Меню — каждый пункт

После установки команда `noder` без аргументов открывает главное меню. Все 15 пунктов работают по цифрам.

### `[1]` Установить ноду

Тот же мастер что и `noder install`. Если нода уже установлена — спросит «переустановить?», бэкап старой конфиги сохранится.

### `[2]` Управление нодой

```
  [1] Запустить ноду
  [2] Остановить ноду
  [3] Перезапустить ноду
  [4] Перезапустить с пересозданием контейнера
```

Wrapper над `docker compose up/stop/restart/down --force-recreate`. Пункт 4 нужен после смены compose-параметров.

### `[3]` Состояние и health-check

```
  Нода: FI-1

  ● Контейнер ноды         running
  ● Процесс Xray           активен
  ● Прослушивание порта    слушает :443
  ● TLS-handshake к dest   TLS 1.3 OK → www.swift.com:443
  ● Доступность панели     1.2.3.4:2222
  · CPU / RAM              CPU 1.2% · RAM 412/3915MB (10%)
  · Размер логов           node=2.4M · noder=156K
  · Активные подключения   47
  · Systemd-таймеры        3 активных
  · Время с обновления блоклистов  4ч назад
```

Зелёные точки — всё ок. Жёлтые — warning. Красные — fail. Снизу — детектор аномалий: если активных подключений было >0 и упало до 0 на 4+ часов — внизу появится:

```
  📉 трафик упал до нуля 6ч (см. п.11 ТЗ — возможна блокировка)
```

### `[4]` Логи

```
  [1] Логи Xray (последние 200 строк)
  [2] Логи Xray (follow в реальном времени)
  [3] Логи контейнера ноды
  [4] Логи noder (установка/обновления)
  [5] Логи fail2ban (кого банило)
  [6] Логи Telegram-слушателя
```

JSONL-логи самого noder лежат в `/var/log/noder/noder.log`, ротируются logrotate'ом (50MB × 5 файлов, gzip).

### `[5]` Обновления

```
  [1] Проверить обновления сейчас
  [2] Обновить Xray (последний)
  [3] Обновить образ ноды
  [4] Откатить к предыдущей версии (из бэкапа)
  [5] Настроить расписание автопроверок
```

Раз в неделю (воскресенье 04:00 МСК) systemd-таймер сам проверяет:
- последний release `XTLS/Xray-core` через GitHub API
- digest `remnawave/node:latest` через Docker Hub

Если новее — алерт в Telegram:

```
🔄 FI-1 (1.2.3.4): обнаружена новая версия
Текущая: 26.3.27 → Новая: 26.4.0

[ Обновить сейчас ]  [ Отложить 24ч ]  [ Игнорировать ]
```

Жмёте «Обновить сейчас» (если ваш TG-ID в whitelist) → noder делает `docker pull` + recreate + отчёт.

### `[6]` Перегенерация параметров (regen)

```
  [1] Сменить short-id (быстро)
  [2] Сменить dest-маску
  [3] Сменить порт
  [4] Полная перегенерация (всё + новый keypair)
  [5] Откатить к предыдущему набору
```

После любой перегенерации — алерт в Telegram с пошаговой инструкцией: какие поля и куда вставить в Config Profile панели.

### `[7]` Показать конфигурацию

Дамп `state.json` с маскированными секретами. Удобно когда забыли публичный ключ или short_id и нужно подсмотреть.

```json
{
  "node_name": "FI-1",
  "reality": {
    "port": 443,
    "dest": "www.swift.com:443",
    "server_names": ["www.swift.com"],
    "public_key": "ZYxwVuTsRqPoNm...",
    "private_key": "ABcd***ABCdef0",
    "short_ids": ["a1b2c3d4"]
  },
  "panel": {
    "ip": "1.2.3.4",
    "node_port": 2222,
    "secret_key": "eyJu***biJ9"
  },
  "telegram": {
    "enabled": true,
    "tg_token": "1234***wxyz",
    "chat_id": 123456789,
    "trusted_ids": [123456789]
  }
}
```

### `[8]` Изменить IP/домен панели

Если переезжаете на другой адрес панели:

```
Новый IP или домен панели [1.2.3.4]: 5.6.7.8
[info] Резолвлю...
[ok] panel.host=5.6.7.8, panel.ip=5.6.7.8
[info] Перерисовываю nft (NODE_PORT теперь только для 5.6.7.8)...
[ok] nftables применён
Перезапустить ноду сейчас? [y/N]: y
```

nftables перестраиваются автоматически — старый IP панели больше не имеет доступа к NODE_PORT.

### `[9]` Гео-списки

Два независимых списка (см. ТЗ 9):
- **Routing (список A)** — `geosite.dat` + `geoip.dat` для xray. Российские сайты идут напрямую с реального IP клиента, минуя ноду.
- **Firewall (список B)** — `@blocklist4` set в nftables, известные сканеры/ботнеты.

```
  [1] Обновить оба списка
  [2] Обновить только routing
  [3] Обновить только firewall
  [4] Показать текущие источники
  [5] Изменить URL источников
  [6] Откатить к предыдущей версии
```

Daily-таймер в 01:00 МСК. Валидация перед применением: размер не упал >50%, формат парсится, sha совпадает. При неудаче — старая версия остаётся, алерт в TG с кнопкой «Повторить».

### `[10]` Backup / Restore

```
  [1] Создать бэкап сейчас
  [2] Восстановить из последнего бэкапа
  [3] Восстановить из выбранного бэкапа
  [4] Скачать бэкап (показать путь)
  [5] Расписание автобэкапов
```

Бэкапит: state.json + compose + .env + nftables ruleset + fail2ban + Caddy + последние гео-списки. Хранит:
- `/var/backups/noder/auto/` — 30 последних суток (daily в 03:30)
- `/var/backups/noder/manual/` — ручные, без ротации

### `[11]` Настройки Telegram

```
  [1] Включить интеграцию
  [2] Выключить интеграцию
  [3] Изменить токен бота
  [4] Изменить chat_id
  [5] Управление whitelist Telegram-ID
  [6] Отправить тестовое сообщение
  [7] Показать настройки (маскированно)
```

Подробнее — [секция «Telegram-бот»](#telegram-бот) ниже.

### `[12]` SSH hardening

```
  [1] Установить fail2ban на SSH
  [2] Сменить SSH-порт
  [3] Отключить вход по паролю
  [4] Показать текущие настройки SSH
```

**Защита от самоблокировки**: перед сменой порта или отключением паролей проверяется наличие ключа в `~/.ssh/authorized_keys`. Нет ключей → отказ. Новый порт открывается в nft **до** изменения `sshd_config`. После применения — таймер 5 минут: не подтвердили `noder ssh confirm` в новой сессии — `sshd_config` откатывается.

### `[13]` API панели (опционально)

```
  [1] Включить интеграцию
  [2] Выключить интеграцию
  [3] Изменить параметры
  [4] Проверить подключение
  [5] Настроить автодействия
  [6] Показать настройки (токен маскирован)
  [7] Удалить токен (shred)
```

⚠️ Токен от API панели = полный доступ к панели. По умолчанию выключено. При включении — экран с предупреждением о рисках. Токен шифруется AES-Fernet (ключ от `/etc/machine-id` + соль `/etc/noder/.salt`). Все API-вызовы логируются в `/var/log/noder/api.log` с маскированным токеном.

**Автодействия** (по умолчанию все выключены):
- `auto_apply_after_regen` — после regen сразу PATCH inbound + Apply на ноду через API
- `auto_apply_after_update` — после Xray update сразу Apply
- `require_telegram_confirm` — перед любым API-действием кнопка в TG (по умолчанию ВКЛ)

### `[14]` Удалить ноду

Двойное подтверждение: confirm + ввод имени ноды строкой. Перед удалением — финальный tar.gz бэкап в `/var/backups/noder/uninstall_YYYY-MM-DD_HH-MM-SS.tar.gz` (на случай отката).

Удаляется: контейнер, образ, /opt/remnanode/, /etc/noder/, /var/log/noder/, /var/lib/noder/, systemd-юниты, nftables table `inet noder`, fail2ban jail, sysctl-файлы, modprobe-файлы, /usr/local/bin/noder symlink.

Сохраняется: /opt/noder/ (сам инструмент) и /var/backups/noder/ (бэкапы).

### `[15]` Ядро · BBRv3 · DDoS-фильтр

```
  ── Ядро ──
  [1] Установить XanMod + sysctl-тюнинг
  [2] Применить только sysctl + BBR(v1)
  [3] Показать ядро / congestion / TFO / conntrack
  [4] Подготовить reboot на XanMod
  [5] Откатить sysctl к дефолтам ОС

  ── Firewall · DDoS ──
  [6] Применить (re-apply) nftables
  [7] Включить жёсткий режим
  [8] Выключить жёсткий режим
  [9] Статус Firewall
 [10] Очистить @scanners (разбанить всех)
 [11] Переустановить fail2ban на SSH
```

**Жёсткий режим** = per-IP rate-limit на Reality (200 новых TCP/мин). Может ломать пользователей за CGNAT (МТС/Мегафон/Билайн/Tele2 — там тысячи юзеров с одного IP). По умолчанию ВЫКЛ.

---

## CLI

```bash
noder                                         # → главное меню
noder install [flags]                         # установка
noder regen [short-id|dest|port|full]         # перегенерация
noder regen rollback                          # откат к предыдущим параметрам
noder status                                  # health-check (то же что [3])
noder update [check|xray|image|rollback]      # обновления
noder uninstall [--yes]                       # удалить ноду
noder backup [create|list|restore-last]       # бэкап
noder ssh [show|f2b|port|no-password|confirm] # SSH hardening
noder firewall [apply|status|strict on|off]   # firewall
noder kernel [install|sysctl|status|revert]   # ядро
noder blocklists [update|routing|firewall]    # гео-списки
noder health                                  # alias to status
noder tg [notify|daemon|test|setup]           # Telegram бот напрямую
noder api [enable|test|wipe|apply-regen]      # API панели
noder version | help
```

Флаги install:

```
--random              генерировать всё что не задано
--name <NAME>         имя ноды
--mode reality|selfsteal
--port <PORT>         Reality-порт
--dest <HOST:PORT>    dest-маска
--domain <FQDN>       домен для selfsteal
--panel-ip <IP>       IP панели
--panel-host <HOST>   хост панели
--node-port <PORT>    NODE_PORT
--secret <KEY>        SECRET_KEY
--compose <STRING>    docker-compose snippet целиком
--compose-file <PATH> путь к файлу с compose
--tg-token <TOKEN>    Telegram бот токен
--tg-chat <ID>        chat_id для алертов
--panel-url <URL>     URL панели (для API)
--panel-token <TOK>   API-токен панели
--auto-register       зарегистрировать ноду в панели через API
--no-tg               пропустить настройку Telegram
--no-kernel           не применять kernel-тюнинг
--yes, -y             не задавать вопросов
```

Минимальный non-interactive deploy:

```bash
sudo noder install \
  --random \
  --name FI-1 \
  --panel-host panel.example.com \
  --compose-file /root/panel-compose.yml \
  --no-tg \
  --yes
```

---

## Telegram-бот

### Зачем

Когда у вас не одна нода, а парк — лазить по SSH на каждую неудобно. С Telegram-ботом:

- Алерты в одном чате (`✅ FI-1`, `⚠️ DE-2`, `❌ NL-3`)
- Inline-кнопки для типовых действий
- `/status_all` — сводка по всем нодам
- whitelist кто может управлять — посторонние нажатия игнорируются

### Подготовка

**1. Создать бота у @BotFather**:
- В Telegram открыть [@BotFather](https://t.me/BotFather)
- `/newbot` → имя → username → получите токен вида `1234567890:AAH...xyz`

**2. Узнать ваш chat_id**:
- Откройте [@userinfobot](https://t.me/userinfobot) → `Start` → пришлёт ID

**3. (Опционально) Создать группу/канал**:
- Если хотите алерты в группу — добавьте туда вашего бота как админа
- chat_id группы возьмите у [@username_to_id_bot](https://t.me/username_to_id_bot) (формат `-1001234567890`)

### Подключение в noder

```
sudo noder
 → [11] Настройки Telegram-бота
 → [1] Включить интеграцию

Токен Telegram-бота (BotFather): ********************
Chat ID для алертов: 123456789
Отправить тестовое сообщение? [y/N]: y
✅ FI-1 (1.2.3.4): тест noder — связь есть
```

### Что приходит в чат

```
✅ FI-1 (1.2.3.4): нода успешно запущена
⚠️ FI-1 (1.2.3.4): Xray перезапустился (3 раз за час)
❌ FI-1 (1.2.3.4): контейнер упал, попытка автоперезапуска
🔄 FI-1 (1.2.3.4): обновление Xray до 26.4.0 завершено
🛡 FI-1 (1.2.3.4): fail2ban забанил 5.6.7.8 (10 попыток SSH)
📉 FI-1 (1.2.3.4): трафик упал до нуля 6 часов назад
🌐 FI-1 (1.2.3.4): обновление гео-списков не удалось
```

Большие сообщения (regen-инструкция, новые параметры для панели) — с footer `by popokole`.

### Inline-кнопки

```
🔄 FI-1: обнаружена новая версия Xray
Текущая: 26.3.27 → Новая: 26.4.0

[ Обновить сейчас ]  [ Отложить 24ч ]  [ Игнорировать ]
```

Любое нажатие → бот проверяет ваш Telegram-ID в whitelist (`telegram.trusted_ids` + `/opt/noder/data/trusted_tg_ids`). Не в списке — нажатие игнорируется, попытка пишется в `/var/log/noder/telegram.log`.

### Whitelist

Управление через меню:

```
sudo noder
 → [11] Telegram
 → [5] Управление whitelist
```

```
Текущий список:
    123456789
    987654321

  [1] Добавить ID
  [2] Удалить ID
  [0] Назад
```

---

## Firewall + DDoS-фильтр

### Идея

Большинство атак на VPS — это либо **SSH brute-force** (для них fail2ban), либо **сканирование портов и SYN-flood** (для них нужна **скорость на packet-rate**). 

fail2ban — это userspace-цикл: парсит лог, грепает по regex, exec'нет iptables. Для тысяч сканеров в секунду — медленно.

`noder` использует **nftables dynamic sets**. IP, который коснулся закрытого порта, попадает в `@scanners4` с timeout 24h, и каждый последующий пакет от него дропается **прямо в ядре** в hot-path. Без userspace.

### Что закрыто и что открыто

```
chain input — default DROP

  ⏵ loopback     — accept (lo)
  ⏵ INVALID      — drop (tier-aware conntrack)
  ⏵ established  — accept (hot path)

  ⏵ @scanners4   — drop (бан 24h: кто стучался на закрытые порты)
  ⏵ @synflood4   — drop (бан 1h: >60 SYN/sec с одного IP)
  ⏵ @blocklist4  — drop (внешний список известных ботнетов)

  ⏵ ICMP echo    — rate-limited 5/sec

  ⏵ SYN-flood meter:  > 60 SYN/sec с IP → +@synflood4 → drop
  ⏵ SSH (port X) — accept (rate-limit 10/min/IP, 5 burst)
  ⏵ Reality (443) — accept
  ⏵ NODE_PORT     — accept ТОЛЬКО для IP панели

  ⏵ tcp dport не в [SSH, Reality, NODE_PORT] → +@scanners4 → drop
  ⏵ udp на любой порт → +@scanners4 → drop

  ⏵ catch-all → log + drop (rate-limited)
```

### Жёсткий режим (опциональный)

В нормальном режиме `Reality (443)` принимает любые подключения. Если включить «жёсткий режим» (`noder firewall strict on`):

```
tcp dport 443 ct state new \
    add @scanners4 { ip saddr limit rate over 200/minute burst 50 packets } \
    counter drop
```

Это per-IP rate-limit: больше 200 новых соединений в минуту с одного IP → этот IP в бан на 1h.

**Когда полезно**: если в логах видно реальные DDoS-атаки на 443.

**Когда вредно**: мобильный CGNAT. МТС/Мегафон могут пропускать ТЫСЯЧИ юзеров через один CGNAT-IP. Все они попадут под лимит → ваши легитимные клиенты получат ban.

По умолчанию — ВЫКЛ.

### Конкретные цифры

| Метрика | Значение |
|---|---|
| SYN-flood порог | 60 SYN/sec на IP |
| Scanner timeout | 24h |
| Synflood timeout | 1h |
| SSH rate-limit | 10/min, burst 5 |
| Conntrack max | 524288 |
| Conntrack hashsize | 131072 |
| ICMP echo rate | 5/sec |

### Sysctl-тюнинг

`noder` пишет в `/etc/sysctl.d/99-noder-net.conf`:

```ini
# TCP congestion + queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr      # ← или bbr3 на XanMod

# TCP Fast Open
net.ipv4.tcp_fastopen = 3                  # server + client

# Path-MTU probing — survives PMTUD blackholes
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# Низкая задержка для маленьких write'ов
net.ipv4.tcp_notsent_lowat = 16384

# Big buffers для high-BDP RU links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# SYN-flood defences
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 16384

# Conntrack — tier-aware timeouts
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30

# Anti-spoof
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0

# Ephemeral ports — шире для xray's upstream conns
net.ipv4.ip_local_port_range = 10000 65000
```

И в `/etc/modprobe.d/noder-conntrack.conf`:

```
options nf_conntrack hashsize=131072
```

### XanMod + BBRv3

XanMod — это тюнингованное ядро Linux с BBRv3 (новейшая версия Google's congestion control, опубликован в 2024). Версия v1 (которая в стандартном Ubuntu) хорошо работает на стабильных каналах, v3 — заметно лучше на lossy paths (мобильные сети, дальние трансатлантические маршруты).

**Совместимость**:
- KVM, bare-metal — установится без проблем
- **OpenVZ, LXC** — нельзя (ядро у всех общее с хост-нодой)
- **ARM64** — нет официального XanMod-релиза, фолбэк на стоковое + BBR(v1)

**Boot-watchdog** (защита от bricked сервера):
1. Старое ядро остаётся как **default** в GRUB
2. XanMod ставится с `grub-reboot` (next-boot only)
3. После reboot если XanMod запустился ОК — `noder-boot-ok.service` ждёт 10 минут, потом делает XanMod default
4. Если XanMod не запустился (kernel panic, hang) — следующий boot вернётся на default = старое ядро

Сейчас CDN xanmod.org **в ауте** (отдаёт 404). `noder` это видит и фолбэкает на BBR(v1) — потеря 10-15% throughput на длинных коннектах.

---

## Жизненный цикл ноды

```
   ┌──────────────┐
   │   ставите    │
   │  bootstrap   │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐    нода работает, xray держит 443
   │  noder       │    fail2ban банит SSH-брутфорсеров
   │  install     │    nft банит сканеров
   └──────┬───────┘    Telegram молчит когда всё ок
          │
          ▼
   ┌──────────────┐    раз в неделю в воскресенье 04:00 МСК
   │  weekly      │ ─── алерт «найдена новая версия Xray»
   │  update      │     ⏯ кнопка «Обновить» в TG
   │  check       │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐    раз в сутки в 01:00 МСК
   │  daily       │ ─── обновление geosite.dat / geoip.dat
   │  blocklists  │     обновление @blocklist4 в nft
   │              │     алерт если что-то не скачалось
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐    раз в сутки в 03:30
   │  daily       │ ─── tar.gz бэкап в /var/backups/noder/auto/
   │  backup      │     ротация 30 последних
   │              │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐    раз в 30 минут
   │  health      │ ─── проверка контейнера + xray + порта
   │  check       │     если упало — алерт в TG
   │              │     если трафик 0 на 4ч+ → подозрение на блок
   └──────────────┘
```

---

## Troubleshooting (FAQ из реальных косяков)

### `name: unbound variable` на старте install

```
/opt/noder/modules/install.sh: line 37: name: unbound variable
```

Старый коммит. Подтяните свежую версию:
```bash
bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
```

### `command not found` или `line 130, exit 127` в логах

Фантомная ошибка из старого коммита. Тоже лечится обновлением.

### `apt update exit 100` на этапе XanMod

```
E: The repository 'http://deb.xanmod.org releases Release' does not have a Release file.
```

XanMod CDN временно недоступен (404 на всё). `noder` после фикса проверяет и пропускает XanMod с фолбэком на BBR(v1) + sysctl. Если у вас старая версия — обновите.

### `hostname must be a string`

```
validating /opt/remnanode/docker-compose.yml: services.remnanode.hostname must be a string
```

`state.json` не содержит `node_name`. Старый компоуз с пустым `hostname:`. Регенерируйте:
```bash
sudo bash <<'SH'
export NODER_HOME=/opt/noder
source /opt/noder/modules/00_common.sh
source /opt/noder/modules/07_node.sh
NP="$(python3 /opt/noder/modules/03_state.py get panel.node_port)"
SC="$(python3 /opt/noder/modules/03_state.py get panel.secret_key)"
node::write_files "$NP" "$SC"
SH
sudo docker compose -f /opt/remnanode/docker-compose.yml up -d --force-recreate
```

### `NODE_PORT: Required` / `SECRET_KEY: Required` в логах контейнера

Образ Remnawave читает только `environment:` блок в compose, не `env_file:`. Свежие версии `noder` пишут оба. Регенерируйте compose как в фиксе выше.

### `SPAWN_ERROR: xray` + `failed to open file: geoip.dat`

xray-конфиг от панели содержит `geoip:` правило, но geo-файлов нет. На свежих версиях `noder install` скачивает их сам. Если установка была на старой версии:

```bash
sudo mkdir -p /usr/local/share/xray
sudo curl -fsSL -o /usr/local/share/xray/geoip.dat \
    https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
sudo curl -fsSL -o /usr/local/share/xray/geosite.dat \
    https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
sudo docker compose -f /opt/remnanode/docker-compose.yml restart
```

### `failed to read client hello` при подключении клиента

Старая версия `noder` ставила MSS clamp в nft output/forward chains. На мобильных RU-каналах с малым path-MTU большой TLS ClientHello (1100+ байт) фрагментировался и Reality его не успевал собрать.

Лечение — обновить `noder` и применить firewall:
```bash
bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
sudo noder firewall apply
```

### «Подключение работает, но интернет не идёт»

99% случаев — Subscription URL клиента указывает не на ту ноду или с неправильным `pbk` (publicKey). Достаньте subscription:

```bash
curl -sL "<ваш-sub-URL>" | base64 -d
```

Найдите строку `vless://...@94.156.179.98:443?...` (где 94.156.179.98 — IP вашей ноды). Сверьте:
- `pbk=` совпадает с PublicKey от privateKey в xray-конфиге ноды
- `sni=` совпадает с одним из `serverNames`
- `sid=` совпадает с `shortIds`

Для проверки PublicKey:
```bash
sudo docker run --rm remnawave/node:latest xray x25519 -i <privateKey>
```

`Password (PublicKey)` в выводе и есть нужный `pbk=`.

### «Клиент не доходит до 443»

Возможно ваш собственный IP попал в `@scanners4` после серии curl/nc тестов. Разбанить:

```bash
sudo nft flush set inet noder scanners4
sudo nft flush set inet noder scanners6
sudo nft flush set inet noder synflood4
sudo nft flush set inet noder synflood6
```

### `Inbounds with same tag already exists`

В Remnawave Panel теги инбаундов глобально уникальны. Переименуйте `"tag": "Reality"` на что-то вроде `"tag": "Reality-FI1"`.

---

## Сравнение

|  | eGames-script | noder |
|---|---|---|
| **DDoS-фильтр** | iptables, простые правила | nftables + dynamic sets + port-scan honeypot + SYN-flood meter (in-kernel) |
| **fail2ban** | SSH | SSH + кастомный action с TG-алертами |
| **Telegram-бот** | нет | long-polling, inline-кнопки, whitelist |
| **Гео-списки** | руками | daily auto-update с валидацией |
| **Auto-updates** | руками | weekly check + TG-алерт + кнопка «Обновить» |
| **Auto-backups** | нет | daily tar.gz + ротация 30 копий |
| **Regen** | руками | `noder regen` + автоинструкция в TG |
| **State** | конфиги | централизованный state.json + atomic write |
| **Health-check** | `docker logs` | `noder status` со всеми компонентами + детектор аномалий |
| **Идемпотентность** | повторный запуск иногда ломает | каждый шаг проверяет состояние перед действием + rollback |
| **API панели** | нет | reverse-engineered + AES-Fernet шифрованный токен |
| **Selfsteal** | nginx, вылизан | каркас Caddy (не доводил) |
| **Production maturity** | проверено сотнями | новее, баги отлавливаются |
| **Объём** | один файл | 31 файл, 6300+ строк |

Когда брать noder:
- Парк из 3+ нод
- Под нагрузкой, нужна in-kernel защита
- Хочется TG-управление и monitoring
- Готовы быть ранним пользователем

Когда брать eGames:
- Одна нода, минимум обвязки
- Не нужны TG и health-check
- Хочется max stability прямо сейчас
- Selfsteal с nginx нужен «вот сразу»

---

## Что под капотом

```
/opt/noder/
├── noder.sh              # entry-point, регистрируется как /usr/local/bin/noder
├── install.sh            # curl-bootstrap для нового сервера
├── locales/ru.json       # все строки UI (i18n готов под англ.)
├── data/
│   ├── reality_masks.json
│   ├── blocklist_sources.json
│   └── trusted_tg_ids
└── modules/
    Bash:                    Python:
    00_common.sh             03_state.py
    01_preflight.sh          04_random.py
    02_docker.sh             05_reality.py
    06_regen.sh              09_telegram.py    ← long-polling bot
    06_selfsteal.sh          panel_api.py      ← AES-Fernet token
    07_node.sh
    08_firewall.sh   ← in-kernel DDoS
    09_telegram.sh   ← bash-обёртка для меню
    10_updates.sh
    11_blocklists.sh
    12_health.sh
    13_menu.sh
    14_kernel.sh    ← XanMod + GRUB watchdog
    backup.sh, install.sh, ssh_harden.sh, uninstall.sh
```

State хранится:
- `/etc/noder/state.json` — params (0600 root:root)
- `/etc/noder/.salt` — соль для AES (0600)
- `/var/log/noder/*.log` — JSONL, logrotate 50MB×5 gzip
- `/var/lib/noder/` — runtime state (kernel-state, tg-offset, traffic-stats)
- `/var/backups/noder/` — бэкапы

---

## Безопасность

- `state.json` — 0600 root:root, никогда не commit'ится (в `.gitignore`)
- Любой секрет (`tg_token`, `api_token`, `secret_key`, `private_key`) маскируется как `abcd***wxyz` в логах, UI, дампах
- API-токен панели шифруется AES-128-Fernet, ключ выводится из `/etc/machine-id` + соли в `/etc/noder/.salt` через scrypt
- При `noder api wipe` соль перезаписывается случайными байтами перед удалением — токен невозможно расшифровать даже из бэкапа
- nftables default policy — DROP на INPUT
- fail2ban — только SSH (NODE_PORT защищён kernel-фильтром, который быстрее)
- Telegram-бот игнорирует всё что не от ID из whitelist, попытки несанкционированного доступа пишутся в `/var/log/noder/telegram.log`

---

## Roadmap

Что есть, но не отполировано:
- **Selfsteal Caddy** — каркас есть в `06_selfsteal.sh`, но без `unix:/dev/shm/nginx.sock` режима для совместимости с моделью «proxy_protocol → nginx fallback». Скоро добавлю поддержку nginx-варианта.
- **panel_api.py** — структура и сигнатуры API подобраны по примерным эндпоинтам Remnawave, в production не оттестировано
- **regen-all через SSH-цепочку** (см. ТЗ 7.9) — отложен на v2

Что планируется:
- `noder selfsteal-setup --domain X` — автоматизация nginx + Let's Encrypt + правильный mount /dev/shm в контейнер
- Англ. локаль (`locales/en.json`)
- Web-UI для health-check (FastAPI на 127.0.0.1 + nginx reverse-proxy в Caddy/nginx)
- Метрики в Prometheus формат (опционально)
- Multi-node CLI (one binary, manages stack remote через SSH)

---

## Удаление

```bash
sudo noder uninstall              # двойное подтверждение (имя ноды)
sudo noder uninstall --yes        # без вопросов

# полная очистка вместе с инструментом:
sudo rm -rf /opt/noder /var/backups/noder /usr/local/share/xray
sudo apt-get purge -y --autoremove \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin fail2ban nftables
```

---

## Поддержка

- **Баги** — issues в этом репо
- **Вопросы по Remnawave Panel** — [docs.rw](https://docs.rw) и [t.me/remnawave](https://t.me/remnawave)
- **Этот скрипт** — issue или PR

---

<div align="center">

```
═══════════════════════════════════════════════
   N O D E R   ·   Remnawave Node Manager
                                     by popokole
═══════════════════════════════════════════════
```

[MIT](LICENSE) · © 2026 popokole

</div>
