# xray — Обход DPI: транспорты и настройка

## Содержание
1. [Выбор транспорта](#выбор-транспорта)
2. [Управление через 3x-ui](#управление-через-3x-ui)
3. [VLESS + RAW + Reality](#vless--raw--reality)
4. [VLESS + XHTTP + Reality](#vless--xhttp--reality) (и XHTTP + TLS через CDN)
5. [VLESS + WebSocket + TLS](#vless--websocket--tls) — устарел
6. [Несколько inbound'ов одновременно](#несколько-inboundов-одновременно)
7. [Оптимальные настройки](#оптимальные-настройки)
8. [Установка xray в Docker (без 3x-ui)](#установка-xray-в-docker-без-3x-ui)
9. [Диагностика](#диагностика)

---

## Выбор транспорта

Состояние на сентябрь 2026: стабильный xray-core — v26.3.27 (дальше идут pre-release),
3x-ui — v3.8.x. Меняется быстро, сверяй [релизы xray](https://github.com/XTLS/Xray-core/releases).

| Транспорт | Домен | Порт | Flow | Через CDN | Когда использовать |
|-----------|-------|------|------|-----------|-------------------|
| VLESS + RAW(TCP) + Reality | Нет | 443 | `xtls-rprx-vision` | Нет | **Основной.** Лучший обход DPI |
| VLESS + XHTTP + Reality | Нет | 2083 | **пусто** | **Нет** | **Резерв** с другим отпечатком трафика |
| VLESS + XHTTP + TLS | Да | 8443 | **пусто** | Да | Когда IP сервера заблокирован и нужен CDN |
| VLESS + WS + TLS | Да | 8443 | **пусто** | Да | ⚠️ Устарел. Только для клиентов без XHTTP |

**Reality через CDN не ходит в принципе:** CDN сам завершает TLS, а Reality требует прямого
соединения клиента с сервером. Через CDN (Cloudflare) идёт только XHTTP/WS с **обычным TLS
на своём домене**. Порт 2083 в резервном Reality-inbound — просто второй порт, CDN тут ни при чём.

**Reality не на 443:** с v26.3.27 xray пишет в лог предупреждение о повышенном риске
блокировки IP. Резервный inbound на 2083 — осознанный компромисс; альтернатива — один
Reality-inbound на 443 с fallback'ом на второй транспорт.

**Стратегия:** RAW Reality → XHTTP Reality (резерв) → XHTTP+TLS через CDN (если заблокирован
IP) → WS+TLS (только старые клиенты). Все можно держать одновременно на разных портах.

> **WebSocket, gRPC, HTTPUpgrade** в xray помечены deprecated: работают, но не
> рекомендуются, при старте пишут предупреждение «might be removed». В коде это пока
> «NonRemovalDeprecated» (удалять не собираются), но строить новое на них не стоит.
> Замена — XHTTP (H2/H3). Удалены совсем транспорты HTTP (h2) и QUIC. `tcp` переименован
> в `raw`, старое имя принимается.

### Совместимость клиентов

| Клиент | RAW Reality | XHTTP Reality | WS+TLS |
|--------|-----------|--------------|--------|
| v2rayN 7+ (Windows/macOS/Linux) | ✅ | ✅ | ✅ |
| Throne (преемник NekoRay, desktop) | ✅ | ✅ (через xray-core) | ✅ |
| Hiddify | ✅ | ✅ (по changelog) | ✅ |
| Streisand, Happ (iOS) | ✅ | ✅ | ✅ |
| NekoBox (Android, sing-box) | ✅ | ❓ вероятно нет | ✅ |
| AmneziaVPN 5.x | ✅ | ✅ | ❓ не проверено |
| Keenetic (роутер) | ❌ нативно | ❌ | ❌ |

NekoRay заархивирован в декабре 2024 — ставить Throne. Keenetic умеет xray только через
Entware + XKeen; для роутера проще AmneziaWG (wg-easy).

---

## Управление через 3x-ui

3x-ui — веб-панель для xray с встроенным xray-core. Рекомендуемый способ управления.
Ветка 3.x (с мая 2026): новый фронтенд, multi-node; в v3.3.0 API панели переехал под
`/panel/api` (ломает скрипты, дёргавшие `/panel/setting`, `/panel/xray`); с v3.7.0 —
автомиграции БД, поэтому **бэкап `./db` перед каждым обновлением**. Поддерживает XHTTP,
VLESS Encryption и поле `target` для Reality.

### Установка

```yaml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:<VERSION>  # актуальный тег с github releases; при мажорном переходе — читай changelog
    container_name: 3x-ui
    volumes:
      - ./db:/etc/x-ui
      - ./certs:/root/certs:ro
    cap_add:                # как в upstream docker-compose.yml
      - NET_ADMIN
      - NET_RAW
    ports:
      - "<PANEL_PORT>:<PANEL_PORT>"
      - "443:443"           # RAW Reality
      - "8443:8443"         # XHTTP/WS + TLS
      - "2083:2083"         # XHTTP Reality
    restart: unless-stopped
    network_mode: bridge
```

**Docker-образ стартует с дефолтами `admin`/`admin`, порт 2053, путь `/`** (случайные значения
генерирует только `install.sh`, не образ). До того как открыть порт наружу: сменить логин,
пароль, порт и base path — первым делом, с доверенного IP.

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

## VLESS + RAW + Reality

Основной транспорт (RAW — прежнее TCP). Не требует домена. Для DPI выглядит как TLS-соединение
с чужим сайтом (target); без ключа Reality сервер честно проксирует на этот сайт.

### Настройка в 3x-ui

| Поле | Значение |
|------|----------|
| Протокол | VLESS |
| Порт | `443` |
| **Flow клиента** | **`xtls-rprx-vision`** (обязательно!) |
| Decryption | `none` |
| Транспорт | TCP (RAW) |
| Безопасность | Reality |
| uTLS | `chrome` (дефолт) |
| Target | `<TARGET>:443` — см. ниже |
| SNI | `<TARGET>` |
| Short IDs | Generate |
| Ключи | Generate (новая пара) |
| Sniffing | `http`, `tls` |

### Выбор Target (сайт, под который маскируется Reality)

Требования: иностранный сайт, TLS 1.3 + HTTP/2, без редиректа на главной. Лучше всего —
сайт **в той же ASN (дата-центре), что и сервер**: трафик «к соседу» выглядит естественно.
Подобрать такой: [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) по подсети сервера.

**Не брать:**
- `microsoft`, `apple`, `icloud`, домены `.ru`/`.ir`/`.cn` — с v26.3.27 xray пишет
  предупреждение в лог: такие target'ы массово используются и легко детектятся;
- сайты за Cloudflare (в т.ч. `www.cloudflare.com`) — сервер становится открытым
  форвардером к CF.

Приемлемый запасной вариант без сканирования — `dl.google.com`. Проверка с сервера:
`curl -sI --http2 https://<TARGET> | head -1` → `HTTP/2 200` (не 301/302).

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
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "target": "<SNI_TARGET>:443",
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

`dest` и `tcp` — старые имена `target` и `raw`, принимаются как алиасы. На клиенте поле
публичного ключа теперь `password` (старое `publicKey` тоже принимается). Необязательные
поля Reality: `limitFallbackUpload`/`limitFallbackDownload` (ограничение скорости для
«чужих», зашедших на fallback), `mldsa65Seed` (пост-квантовая подпись; target должен
отдавать цепочку сертификатов > 3500 байт), `minClientVer`.

**Минимальная версия клиента.** Новые сборки xray (в т.ч. внутри 3x-ui 3.x) при старте пишут
`REALITY: The default minimal client version is Xray-core v26.3.27, other clients may be
refused to connect` — клиенты на старом xray-core могут перестать подключаться после
обновления сервера. Перед обновлением xray/3x-ui обновить клиенты или явно задать
`minClientVer` ниже.

---

## VLESS + XHTTP + Reality

Транспорт XHTTP есть с xray v24.10.31. Сервер отдаёт поток по H2/H3, клиент шлёт данные
POST-пакетами (`packet-up`) или потоком (`stream-up`/`stream-one`). `mode: auto` выбирает
сам: при Reality — `stream-one`. **Upstream советует задавать только `path`**, остальное
(XMUX, padding) оставить по умолчанию. Через CDN этот вариант **не** работает — см. таблицу
выбора транспорта.

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
| Target | `<TARGET>:443` (тот же выбор, что для RAW) |
| SNI | `<TARGET>` |
| Ключи | **Generate (новая пара**, независимая от RAW Reality!) |
| Short IDs | Generate |
| Sniffing | `http`, `tls` |

### Отличия от RAW Reality

| | RAW + Reality | XHTTP + Reality |
|---|---|---|
| Flow | `xtls-rprx-vision` | **пусто** |
| Транспорт | RAW (бывш. TCP) | XHTTP |
| Через CDN | Нет | Нет (для CDN — XHTTP + TLS на своём домене) |
| Reality ключи | Пара 1 | **Пара 2** (отдельная!) |

### VLESS + XHTTP + TLS через CDN

Вариант для случая, когда IP сервера заблокирован: домен проксируется через Cloudflare
(«оранжевое облако»). Inbound: XHTTP, `path` длинный случайный, security **TLS** с сертификатом на домен (acme.sh
ниже), flow пусто. Порт — из списка HTTPS-портов Cloudflare: 443, 2053, 2083, 2087, 2096,
8443. Настройки CDN-режима (`xPaddingBytes`, параметры обфускации под CDN) upstream называет
ещё не устоявшимися — начинать с дефолтов.

---

## VLESS + WebSocket + TLS

> ⚠️ **WebSocket помечен в xray-core как deprecated** (работает, но не рекомендуется).
> Для работы через CDN — XHTTP + TLS на том же домене (раздел выше). WS+TLS оставляй только
> для клиентов, которые не поддерживают XHTTP.
>
> **Миграция WS → XHTTP:** создай XHTTP+TLS inbound на том же домене и сертификате (Flow
> пусто), раздай клиентам новый конфиг, затем удали WS inbound. XHTTP+Reality заменой WS
> не является, если WS шёл через CDN.

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
  - "443:443"      # RAW Reality
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
| RAW + Reality | `xtls-rprx-vision` (обязательно) |
| XHTTP + Reality | **пусто** |
| WebSocket + TLS | **пусто** |

**Flow используется ТОЛЬКО с RAW-транспортом** (иначе ошибка `XTLS only supports TLS and
REALITY directly`). Для XHTTP и WebSocket — пусто. Исключение — VLESS Encryption.

### VLESS Encryption (опционально)

С v25.9.5 VLESS умеет собственное шифрование (ML-KEM-768 + X25519, пост-квантовое): поле
`decryption` на сервере и `encryption` на клиенте вместо `none`, ключи — `xray vlessenc`.
Upstream советует включать вместе с Vision; с ней flow допустим и на XHTTP/WS. Несовместима
с fallbacks. Для обычной связки Reality достаточно `"decryption": "none"` — включать, только
если все клиенты её поддерживают.

### Sniffing

Всегда включать `http` + `tls` на всех inbound'ах. Без sniffing невозможна маршрутизация по доменам.

### Reality ключи

Для каждого Reality-inbound'а — **отдельная пара ключей**. Не переиспользовать между TCP и XHTTP.

### uTLS

`chrome` — дефолт и самый распространённый fingerprint. `unsafe` для Reality запрещён.
Для WS+TLS менее критичен (TLS свой, не Reality).

---

## Установка xray в Docker (без 3x-ui)

Для ручного управления конфигом (без веб-панели).

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:<VERSION>
    container_name: xray
    # entrypoint образа — сам xray с `-confdir /usr/local/etc/xray/`: конфиг монтировать
    # именно туда. С другим путём контейнер стартует БЕЗ конфига и ничего не слушает
    volumes:
      - ./config:/usr/local/etc/xray:ro
      - ./certs:/usr/local/etc/xray-certs:ro
    ports:
      - "443:443"
      - "8443:8443"
    restart: unless-stopped
```

### Генерация ключей

Entrypoint образа — уже `xray`, поэтому подкоманда идёт сразу после имени образа
(`… xray-core xray uuid` падает с `unknown command`):

```bash
docker run --rm ghcr.io/xtls/xray-core uuid
docker run --rm ghcr.io/xtls/xray-core x25519
openssl rand -hex 4   # Short ID
```

Вывод `x25519` в новых версиях: `PrivateKey:` — в `privateKey` сервера, `Password (PublicKey):` —
публичный ключ для клиента (в клиентах и 3x-ui поле может называться `password` или
`publicKey`), `Hash32:` — не нужен.

### Проверка конфига

```bash
docker run --rm -v ./config:/usr/local/etc/xray:ro ghcr.io/xtls/xray-core \
  run -test -config /usr/local/etc/xray/config.json     # ожидаемо: Configuration OK.
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

**"VLESS (with no Flow) is deprecated"** — было в pre-release января–марта 2026, убрано
в v26.3.27 (PR #5671). Если видишь — xray старый или pre-release той поры; обнови.

**Предупреждение про Reality не на 443 или про target (`microsoft`/`apple`/…)** — с v26.3.27.
Не ошибка, но совет по делу: см. «Выбор Target» и таблицу транспортов.

**"The feature WebSocket transport … is deprecated … Please migrate to XHTTP H2 & H3"** —
печатается при каждом старте с WS-inbound'ом. Работает, но это сигнал переходить на XHTTP:
порядок миграции — в разделе WebSocket (XHTTP+TLS на том же домене, если WS шёл через CDN).

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
