# xray — Обход DPI: транспорты и настройка

## Содержание
1. [Выбор транспорта](#выбор-транспорта)
2. [Управление через 3x-ui](#управление-через-3x-ui)
3. [VLESS + TCP + Reality](#vless--tcp--reality)
4. [VLESS + XHTTP + Reality](#vless--xhttp--reality)
5. [VLESS + WebSocket + TLS](#vless--websocket--tls)
6. [Несколько inbound'ов одновременно](#несколько-inboundов-одновременно)
7. [Оптимальные настройки](#оптимальные-настройки)
8. [Установка xray в Docker (без 3x-ui)](#установка-xray-в-docker-без-3x-ui)
9. [Диагностика](#диагностика)

---

## Выбор транспорта

| Транспорт | Домен | Порт | Flow | CDN | Когда использовать |
|-----------|-------|------|------|-----|-------------------|
| VLESS + TCP + Reality | Нет | 443 | `xtls-rprx-vision` | Нет | **Основной.** Лучший обход DPI |
| VLESS + XHTTP + Reality | Нет | 2083 | **пусто** | Да | **Резерв.** CDN-совместимый (Cloudflare) |
| VLESS + WS + TLS | Да | 8443 | **пусто** | Да | ⚠️ **Устаревает → мигрируй на XHTTP.** Только для старых клиентов |

**Стратегия:** Reality → XHTTP Reality (резерв) → WS+TLS (только если клиент не поддерживает XHTTP).
Все транспорты можно запустить одновременно на разных портах.

> **WebSocket устаревает:** команда xray официально помечает WS как deprecated и планирует его удалить в будущих версиях. XHTTP работает через CDN так же, как WS, но лучше скрывает трафик. Если используешь WS+TLS — запланируй миграцию на XHTTP.

### Совместимость клиентов

| Клиент | TCP Reality | XHTTP Reality | WS+TLS |
|--------|-----------|--------------|--------|
| v2rayN 7+ | ✅ | ✅ | ✅ |
| Nekobox / Nekoray | ✅ | ✅ | ✅ |
| Hiddify | ✅ | ✅ | ✅ |
| Streisand (iOS) | ✅ | ✅ | ✅ |
| AmneziaVPN | ❌ | ❌ | ❌ |
| Keenetic (роутер) | ❌ | ❌ | ❌ |

> AmneziaVPN и роутеры — используй AmneziaWG (wg-easy), не xray.

---

## Управление через 3x-ui

3x-ui — веб-панель для xray с встроенным xray-core. Рекомендуемый способ управления.

### Установка

```yaml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:<VERSION>  # актуальный тег с github releases; при мажорном переходе — читай changelog
    container_name: 3x-ui
    volumes:
      - ./db:/etc/x-ui
      - ./certs:/root/certs:ro
    ports:
      - "<PANEL_PORT>:<PANEL_PORT>"
      - "443:443"           # Reality
      - "8443:8443"         # WS+TLS
      - "2083:2083"         # XHTTP Reality
    restart: unless-stopped
    network_mode: bridge
```

### Критично: порты в docker-compose

**При добавлении нового inbound в 3x-ui — обязательно:**
1. Добавь порт в `docker-compose.yml` секцию `ports`
2. Пересоздай контейнер: `docker compose up -d`
3. Открой порт в UFW: `sudo ufw allow <PORT>/tcp`

Без этого xray слушает внутри контейнера, но порт недоступен снаружи!

### Безопасность панели

- Сменить стандартный порт (не 2053!)
- Добавить базовый путь (например `/42dd4c47bad9/`)
- HTTPS: указать webCertFile/webKeyFile в настройках панели
- UFW: ограничить порт панели доверенными IP + VPN-подсетью

---

## VLESS + TCP + Reality

Основной транспорт. Не требует домена. Маскируется под TLS крупных сайтов.

### Настройка в 3x-ui

| Поле | Значение |
|------|----------|
| Протокол | VLESS |
| Порт | `443` |
| **Flow клиента** | **`xtls-rprx-vision`** (обязательно!) |
| Decryption | `none` |
| Транспорт | TCP (RAW) |
| Безопасность | Reality |
| uTLS | `chrome` |
| Target | `www.microsoft.com:443` |
| SNI | `www.microsoft.com` |
| Short IDs | Generate |
| Ключи | Generate (новая пара) |
| Sniffing | `http`, `tls` |

### Выбор SNI Target

Крупный сайт с TLS 1.3 + HTTP/2, доступный из страны сервера:
- `www.microsoft.com`, `dl.google.com`, `www.cloudflare.com`
- Проверка: `curl -I https://<TARGET>` с сервера

### Ручной конфиг (config.json)

```json
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "<UUID>", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "<SNI_TARGET>:443",
        "serverNames": ["<SNI_TARGET>"],
        "privateKey": "<PRIVATE_KEY>",
        "shortIds": ["<SHORT_ID>"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
```

---

## VLESS + XHTTP + Reality

Новый транспорт xray 25+. Работает поверх HTTP chunked encoding. CDN-совместимый.

### Настройка в 3x-ui

| Поле | Значение |
|------|----------|
| Протокол | VLESS |
| Порт | `2083` |
| **Flow клиента** | **пусто** (НЕ xtls-rprx-vision!) |
| Decryption | `none` |
| Транспорт | **XHTTP** |
| Path | `/dl` (или любой) |
| Mode | `auto` |
| Безопасность | Reality |
| uTLS | `chrome` |
| Target | `www.microsoft.com:443` |
| SNI | `www.microsoft.com` |
| Ключи | **Generate (новая пара**, независимая от TCP Reality!) |
| Short IDs | Generate |
| Sniffing | `http`, `tls` |

**Порт 2083** — CDN-совместимый HTTPS-порт (Cloudflare пропускает).

### Отличия от TCP Reality

| | TCP + Reality | XHTTP + Reality |
|---|---|---|
| Flow | `xtls-rprx-vision` | **пусто** |
| Транспорт | TCP (RAW) | XHTTP |
| CDN-совместимость | Нет | Да |
| Reality ключи | Пара 1 | **Пара 2** (отдельная!) |

---

## VLESS + WebSocket + TLS (устаревает)

> ⚠️ **WebSocket официально помечен как deprecated в xray-core.** Планируется удаление в одной из будущих версий. Если нужен CDN-совместимый транспорт — используй XHTTP + Reality (см. раздел выше). WS+TLS оставляй только для клиентов, которые не поддерживают XHTTP.
>
> **Миграция WS → XHTTP:** создай новый XHTTP inbound (порт 2083, Flow пусто, отдельная пара Reality-ключей), раздай клиентам новый конфиг, затем удали WS inbound.

Требует домен с A-записью на IP сервера и TLS-сертификат.

### Настройка в 3x-ui

| Поле | Значение |
|------|----------|
| Протокол | VLESS |
| Порт | `8443` |
| **Flow клиента** | **пусто** |
| Decryption | `none` |
| Транспорт | WebSocket |
| Path | `/<RANDOM_PATH>` (случайный, длинный) |
| Host | `<DOMAIN>` |
| Безопасность | TLS |
| SNI | `<DOMAIN>` |
| **ALPN** | **только `http/1.1`** (убрать h2!) |
| uTLS | `chrome` |
| Min/Max TLS | 1.2 / 1.3 |
| Cert | путь к cert.pem |
| Key | путь к key.pem |
| Sniffing | `http`, `tls` |

### Важно: ALPN для WebSocket

**Только `http/1.1`!** WebSocket работает через HTTP/1.1 Upgrade.
Если в ALPN есть `h2`, клиент может согласовать HTTP/2, и WebSocket-апгрейд не сработает.

### Сертификат через acme.sh

```bash
curl https://get.acme.sh | sh -s email=<EMAIL>
~/.acme.sh/acme.sh --issue -d <DOMAIN> --standalone

~/.acme.sh/acme.sh --install-cert -d <DOMAIN> \
  --key-file /path/to/key.pem \
  --fullchain-file /path/to/cert.pem \
  --reloadcmd "/usr/local/bin/cert-reload.sh"
```

Скрипт `cert-reload.sh`: `systemctl reload nginx && docker restart 3x-ui`

### Ручной конфиг (config.json)

```json
{
  "inbounds": [{
    "port": 8443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "<UUID>"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/path/to/cert.pem",
          "keyFile": "/path/to/key.pem"
        }],
        "minVersion": "1.2",
        "alpn": ["http/1.1"]
      },
      "wsSettings": {"path": "/<WS_PATH>"}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
```

---

## Несколько inbound'ов одновременно

Все транспорты — разные порты, один контейнер (3x-ui или xray).

### docker-compose.yml порты

```yaml
ports:
  - "<PANEL_PORT>:<PANEL_PORT>"
  - "443:443"      # TCP Reality
  - "8443:8443"    # WS+TLS
  - "2083:2083"    # XHTTP Reality
```

### UFW

```bash
sudo ufw allow 443/tcp comment 'xray Reality'
sudo ufw allow 8443/tcp comment 'xray WS+TLS'
sudo ufw allow 2083/tcp comment 'xray XHTTP Reality'
```

---

## Оптимальные настройки

### Правило Flow

| Транспорт | Flow |
|-----------|------|
| TCP + Reality | `xtls-rprx-vision` (обязательно) |
| XHTTP + Reality | **пусто** |
| WebSocket + TLS | **пусто** |

**Flow используется ТОЛЬКО с TCP-транспортом.** Для XHTTP и WebSocket — всегда пусто.

### Sniffing

Всегда включать `http` + `tls` на всех inbound'ах. Без sniffing невозможна маршрутизация по доменам.

### Reality ключи

Для каждого Reality-inbound'а — **отдельная пара ключей**. Не переиспользовать между TCP и XHTTP.

### uTLS

`chrome` — наиболее распространённый fingerprint. Для WS+TLS менее критичен (TLS свой, не Reality).

---

## Установка xray в Docker (без 3x-ui)

Для ручного управления конфигом (без веб-панели).

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core
    container_name: xray
    volumes:
      - ./config:/etc/xray
      - ./certs:/etc/xray/certs:ro
    ports:
      - "443:443"
      - "8443:8443"
    restart: unless-stopped
```

### Генерация ключей

```bash
docker run --rm ghcr.io/xtls/xray-core xray uuid
docker run --rm ghcr.io/xtls/xray-core xray x25519
openssl rand -hex 4   # Short ID
```

### Проверка конфига

```bash
docker run --rm -v ./config:/etc/xray ghcr.io/xtls/xray-core xray run -test -config /etc/xray/config.json
```

---

## Диагностика

### Базовая проверка

```bash
sudo docker ps | grep -E 'xray|3x-ui'
sudo docker logs <container> --tail 50
sudo ss -tlnp | grep -E '443|8443|2083'
```

### Типичные ошибки

**"failed to listen TCP"** — порт уже занят:
```bash
sudo ss -tlnp | grep <PORT>
sudo docker ps --format "table {{.Names}}\t{{.Ports}}"
```

**"reality: failed"** — неверный SNI target или недоступен с сервера:
```bash
curl -I https://<SNI_TARGET>
```

**"VLESS (with no Flow) is deprecated"** — warning для XHTTP/WS inbound'ов. Пока работает, но апстрим ведёт реальную миграцию на «VLESS with flow» ([discussion #5568](https://github.com/XTLS/Xray-core/discussions/5568)) — при обновлении xray-core сверяйся с release notes. Там же на подходе встроенное VLESS Encryption (пост-квантовое).

**"WebSocket transport is deprecated"** — WS официально устаревает, xray планирует его удалить. Мигрируй на XHTTP: создай XHTTP+Reality inbound, раздай клиентам новый конфиг, удали WS inbound.

**WS подключение не работает** — проверь:
1. ALPN = только `http/1.1` (не h2!)
2. Путь совпадает в конфиге и клиенте
3. Сертификат валиден и доступен контейнеру

**Порт не слушается снаружи** — проверь:
1. `docker-compose.yml` содержит порт в `ports`
2. UFW разрешает порт
3. Контейнер пересоздан после изменения docker-compose

**TLS certificate error** — неверный путь или права:
```bash
ls -la /path/to/certs/
docker exec <container> ls -la /root/certs/
```
