# NODER · Remnawave Node Manager

Универсальный установщик и менеджер нод Remnawave (Xray-core).
Маскировка трафика, идемпотентная установка, firewall hardening,
автообновления, Telegram-управление парком нод.

```
═══════════════════════════════════════════════
   N O D E R   ·   Remnawave Node Manager
                                     by popokole
═══════════════════════════════════════════════
```

## Быстрая установка

На чистый Ubuntu 22.04 (x86_64 или ARM64):

```bash
bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
```

После установки команда `noder` доступна глобально и открывает главное меню.

## Установка без интерактива

```bash
noder install --random \
  --name FI-1 \
  --panel-ip 1.2.3.4 \
  --node-port 2222 \
  --secret SECRET_HERE
```

Подробнее — `noder help` или меню.

## Возможности

- **Установка ноды Remnawave** в двух режимах: Reality (без домена) и Selfsteal (Caddy + Let's Encrypt).
- **Маскировка** под крупные международные сайты с TLS 1.3 + HTTP/2. Российские сайты и сайты из реестра РКН в качестве масок не используются.
- **Идемпотентность** — повторный запуск установки не ломает существующее.
- **Firewall hardening** — nftables (default drop), fail2ban с алертами в Telegram, sysctl-tuning.
- **Гео-списки** routing (xray geosite/geoip) и firewall (плохие IP), автообновление раз в сутки с валидацией и rollback при ошибке.
- **Telegram-управление** — один бот на парк нод, inline-кнопки, whitelist разрешённых ID.
- **Автообновления** Xray и образа ноды с подтверждением кнопкой в Telegram.
- **Regen** — ручная перегенерация параметров на случай подозрения на блокировку, с пошаговой инструкцией для панели.
- **Backup / Restore** — ежедневный авто-бэкап + ручные через меню.
- **Опциональная** интеграция с API Remnawave: автоприменение Apply после regen/update, регистрация ноды.

## Требования

| | |
|---|---|
| ОС | Ubuntu 22.04 LTS (x86_64 или ARM64) |
| Доступ | root |
| Сеть | публичный IPv4; порты по умолчанию: 443 (Reality), 22 (SSH), NODE_PORT (только для IP панели) |

## Структура

```
/opt/noder/                    # сам инструмент
/etc/noder/state.json          # параметры ноды (0600 root:root)
/var/log/noder/                # логи (JSONL, ротация logrotate)
/var/backups/noder/            # бэкапы
```

## Безопасность

- `state.json` хранится с правами `0600 root:root`.
- API-токен панели и токен Telegram-бота никогда не выводятся в логи в открытом виде — маскируются как `abcd***wxyz`.
- API-токен панели (если интеграция включена) шифруется AES-256-GCM, ключ выводится из `/etc/machine-id` + соли.
- nftables по умолчанию: `drop` на INPUT, открыто только то, что нужно ноде и SSH.
- fail2ban с jail'ами для SSH и для NODE_PORT (агрессивный бан попыток с не-панельных IP).

## Лицензия

См. файл `LICENSE`.

---
by popokole
