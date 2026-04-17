---
name: ubuntu-server-admin
description: >
  Системное администрирование Ubuntu Linux серверов: установка, настройка, hardening,
  VPN (AmneziaWG + wg-easy, xray через 3x-ui с VLESS + Reality/WebSocket/XHTTP для обхода DPI),
  файрвол UFW, Docker, nginx, автобэкапы, диагностика.
  Используй при любых задачах: настройка Ubuntu сервера, VPN туннели, UFW, SSH hardening,
  AmneziaWG, WireGuard, wg-easy, xray, 3x-ui, Docker, обход DPI, split tunneling,
  диагностика сетевых проблем на Linux, подключение роутеров к VPN.
---

# Ubuntu Server Administration + VPN

## Архитектура: несколько VPN на одном сервере

```
┌──────────────────────────────────────────────────────────────┐
│                      Ubuntu Server                           │
│                                                              │
│  ┌──────────────────┐   ┌─────────────────────────────────┐ │
│  │   wg-easy        │   │   3x-ui (xray-core внутри)      │ │
│  │   (Docker)       │   │   (Docker)                      │ │
│  │                  │   │                                 │ │
│  │ UDP :WG_PORT     │   │ TCP :443  (VLESS+TCP+Reality)   │ │
│  │ (AmneziaWG)      │   │ TCP :8443 (VLESS+WS+TLS)       │ │
│  │                  │   │ TCP :2083 (VLESS+XHTTP+Reality) │ │
│  │ TCP :UI_PORT     │   │ TCP :PANEL (веб-панель)         │ │
│  │ (внутренний)     │   │                                 │ │
│  └──────────────────┘   └─────────────────────────────────┘ │
│                                                              │
│  nginx: reverse proxy для wg-easy UI (HTTPS + IP restrict)  │
│  UFW: deny incoming, allow routed, порты по необходимости    │
└──────────────────────────────────────────────────────────────┘
```

**Когда что использовать:**
- **AmneziaWG (wg-easy)** — основной VPN, обфускация против DPI (РКН), роутеры Keenetic
- **VLESS + TCP + Reality** — обход DPI без домена, маскировка под TLS крупных сайтов
- **VLESS + XHTTP + Reality** — CDN-совместимый, новый транспорт xray 25+
- **VLESS + WS + TLS** — fallback с доменом, через nginx или напрямую

---

## Базовые принципы

Перед ЛЮБЫМ изменением конфига:
1. Сделай бекап: `sudo cp /path/to/config /path/to/config.bak.$(date +%F-%H%M)`
2. Проверь текущее состояние: `sudo systemctl status <service>` или `sudo docker ps`
3. После изменения — проверь результат: `sudo docker logs <container> --tail 50`
4. Если сломалось — восстанови бекап и перезапусти

**Никогда не закрывай SSH до проверки что UFW не заблокировал SSH порт.**

### Подключение к серверу

Первый вход (пароль): `ssh root@<SERVER_IP>`
После настройки ключа: `ssh <USERNAME>@<SERVER_IP>` или через alias в `~/.ssh/config`.
Если MCP SSH доступен — можно использовать его, но `ssh` через bash тоже работает.

---

## 0. Диагностика текущего состояния

**Выполни ПЕРВОЙ перед любой настройкой.** Сервер скорее всего уже частично настроен.

```bash
# Система
lsb_release -a && uname -r
free -h && df -h && nproc

# SSH
grep -rE 'PermitRootLogin|PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/

# Файрвол
sudo ufw status verbose

# Docker и контейнеры
sudo docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"

# WireGuard / wg-easy
sudo docker ps | grep wg-easy
sudo wg show 2>/dev/null || echo "Нет WG интерфейсов"

# xray / 3x-ui
sudo docker ps | grep -E 'xray|3x-ui'

# fail2ban
sudo fail2ban-client status 2>/dev/null

# Занятые порты
sudo ss -tlnp | head -30
sudo ss -ulnp | head -30
```

После диагностики сообщи что найдено и **не начинай без подтверждения**.

---

## 1. Первичная настройка Ubuntu

> Проверь секцию 0 — возможно уже сделано.

### Обновление

```bash
sudo apt update && sudo apt upgrade -y
```

### Создание sudo пользователя

```bash
sudo adduser <USERNAME>
sudo usermod -aG sudo <USERNAME>
```

### SSH hardening

**Важно: Ubuntu 24.04 использует ssh.socket (socket activation).**
Порт в `sshd_config` игнорируется — нужно менять в `ssh.socket` override.
Для смены порта: `sudo systemctl edit ssh.socket` → добавить ListenStream.
Проверять через VNC-консоль провайдера на случай потери доступа!

Рекомендуемые параметры (в `/etc/ssh/sshd_config.d/99-hardening.conf`):
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Убедись что ключ добавлен ПЕРЕД отключением пароля:
```bash
cat /home/<USERNAME>/.ssh/authorized_keys
sudo sshd -t && sudo systemctl restart ssh
# Проверь подключение в НОВОЙ сессии прежде чем закрывать текущую!
```

**Gotcha:** файл `/etc/ssh/sshd_config.d/50-cloud-init.conf` может содержать `PasswordAuthentication yes`, перезаписывая hardening. Проверяй и исправляй!

### fail2ban

```bash
sudo apt install fail2ban -y
```

Рекомендуемая конфигурация:
- **sshd jail**: bantime 6ч, findtime 30мин, maxretry 4
- **recidive jail**: бан на неделю после 3 повторных банов
- **bantime.increment**: прогрессивный рост (factor=2, max 7 дней)
- **ignoreip**: добавь свои доверенные IP

```bash
sudo systemctl enable fail2ban && sudo systemctl start fail2ban
sudo fail2ban-client status sshd
```

---

## 2. UFW

### Базовая настройка

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow <SSH_PORT>/tcp comment 'SSH'
# ВАЖНО: убедись что SSH порт добавлен ПЕРЕД enable!
sudo ufw status numbered   # проверь что SSH есть в списке
sudo ufw enable
```

### Порты VPN — открыты для всех

```bash
sudo ufw allow <WG_PORT>/udp comment 'AmneziaWG'
sudo ufw allow 443/tcp comment 'xray Reality'
sudo ufw allow 8443/tcp comment 'xray WS+TLS'
sudo ufw allow 2083/tcp comment 'xray XHTTP Reality'
```

### Админ-панели — только доверенные IP!

```bash
# Для каждого доверенного IP:
sudo ufw allow from <TRUSTED_IP> to any port <PANEL_PORT> proto tcp comment 'panel'

# Для VPN-клиентов (доступ из туннеля):
sudo ufw allow from 10.8.0.0/24 to any port <PANEL_PORT> proto tcp comment 'panel VPN'

# Для Docker bridge (если 3x-ui в Docker):
sudo ufw allow from 172.17.0.0/16 to any port <PANEL_PORT> proto tcp comment 'panel docker'
```

### NAT и forwarding

В `/etc/ufw/before.rules` ПЕРЕД `*filter`:
```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o <MAIN_INTERFACE> -j MASQUERADE
COMMIT
```

В `/etc/sysctl.conf`:
```
net.ipv4.ip_forward=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.send_redirects=0
```

### DOCKER-USER iptables (ограничение Docker-портов)

Docker обходит UFW! Для ограничения доступа к Docker-портам нужны правила в цепочке DOCKER-USER.

Скрипт `/usr/local/bin/docker-user-rules.sh`:
```bash
#!/bin/bash
iptables -I DOCKER-USER -p tcp --dport <PORT> -s <TRUSTED_IP> -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport <PORT> -j REJECT
# IPv6:
ip6tables -I DOCKER-USER -p tcp --dport <PORT> -j REJECT
```

Персистентность через systemd сервис (After=docker.service).

---

## 3. Docker + nginx

### Установка Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker <USERNAME>
sudo systemctl enable docker && sudo systemctl start docker
```

### Установка nginx

```bash
sudo apt install -y nginx
sudo systemctl enable nginx
```

### Лог-ротация (обязательно!)

`/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

```bash
sudo systemctl restart docker
```

---

## 4. wg-easy + AmneziaWG

### AmneziaWG — обфускация WireGuard

AmneziaWG добавляет junk-пакеты поверх WireGuard, скрывая трафик от DPI.
Требуется DKMS модуль `amneziawg` на хосте + `EXPERIMENTAL_AWG=true` в wg-easy.

Клиенты подключаются через приложение **AmneziaVPN** (не стандартный WireGuard).
**Keenetic Ultra** поддерживает AmneziaWG нативно (KeeneticOS 4.1+).

### Установка AmneziaWG DKMS модуля

Выполнить на хосте (не внутри контейнера):

```bash
# Зависимости
sudo apt install -y dkms git linux-headers-$(uname -r) build-essential

# Скачать исходники
sudo git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module \
  /usr/src/amneziawg-1.0.0

# Установить через DKMS (автоматически пересобирается при обновлении ядра)
sudo dkms add amneziawg/1.0.0
sudo dkms build amneziawg/1.0.0
sudo dkms install amneziawg/1.0.0

# Загрузить модуль и сделать постоянным
sudo modprobe amneziawg
echo "amneziawg" | sudo tee /etc/modules-load.d/amneziawg.conf

# Проверка
lsmod | grep amneziawg
```

Если `linux-headers-$(uname -r)` не найден — обнови ядро: `apt upgrade -y` и перезагрузись.

### docker-compose.yml (пример)

### Генерация PASSWORD_HASH для wg-easy

```bash
# Генерирует bcrypt-хэш пароля (заменить YOUR_PASSWORD своим):
docker run --rm -it ghcr.io/wg-easy/wg-easy wgpw 'YOUR_PASSWORD'
# Вывод: PASSWORD_HASH='$2b$12$...'
# Каждый символ $ нужно удвоить в docker-compose.yml: $2b → $$2b
```

### docker-compose.yml (пример)

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    environment:
      - LANG=en
      - WG_HOST=<SERVER_IP>
      - PASSWORD_HASH=<BCRYPT_HASH>   # каждый $ → $$
      - WG_PORT=<WG_PORT>
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_ALLOWED_IPS=0.0.0.0/0
      - UI_TRAFFIC_STATS=true
    volumes:
      - wg-easy-data:/etc/wireguard
    ports:
      - "<WG_PORT>:<WG_PORT>/udp"
      - "127.0.0.1:<INTERNAL_UI_PORT>:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped

volumes:
  wg-easy-data:
```

**Важно:** UI привязан к `127.0.0.1` — доступ только через nginx reverse proxy.

### nginx reverse proxy для wg-easy UI

**Два варианта в зависимости от наличия домена:**

#### Вариант А: с доменом (DOMAIN задан в SETUP_INFO.md)

Сертификат получить через acme.sh (см. секцию 5). Затем:

```nginx
server {
    listen <WG_UI_PORT> ssl;
    server_name <DOMAIN>;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    limit_req zone=panel burst=20;

    location / {
        proxy_pass http://127.0.0.1:<INTERNAL_UI_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

#### Вариант Б: без домена (DOMAIN пустой)

Использовать самоподписанный сертификат:

```bash
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/wg-easy.key \
  -out /etc/ssl/certs/wg-easy.crt \
  -subj "/CN=<SERVER_IP>"
```

```nginx
server {
    listen <WG_UI_PORT> ssl;

    ssl_certificate /etc/ssl/certs/wg-easy.crt;
    ssl_certificate_key /etc/ssl/private/wg-easy.key;

    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    limit_req zone=panel burst=20;

    location / {
        proxy_pass http://127.0.0.1:<INTERNAL_UI_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> Браузер покажет предупреждение о самоподписанном сертификате — это нормально.
> Трафик всё равно шифруется, а панель доступна только с доверенных IP.

### Ограничения wg-easy v15

- НЕЛЬЗЯ очищать `clients_table.ipv6_address` → невалидный wg0.conf
- НЕЛЬЗЯ очищать `interfaces_table.ipv6_cidr` → краш wg-easy
- Для отключения IPv6 в клиентах: через DB — `default_allowed_ips=["0.0.0.0/0"]`, убрать ip6tables из hooks_table

---

## 5. xray через 3x-ui

> **Читай references/xray.md** для полных инструкций по транспортам и настройке.

### Управление через 3x-ui

3x-ui — веб-панель для xray со встроенным xray-core. Все inbound'ы создаются через UI.

### Актуальная версия 3x-ui

Смотреть на https://github.com/MHSanaei/3x-ui/releases — взять последний тег, например `v2.8.11`.
Всегда пинить конкретную версию (не `latest`) — это защитит от неожиданных breaking changes.

```yaml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:<VERSION>  # Пинить версию! Например: v2.8.11
    container_name: 3x-ui
    volumes:
      - ./db:/etc/x-ui
      - ./certs:/root/certs:ro
    ports:
      - "<PANEL_PORT>:<PANEL_PORT>"
      - "443:443"
      - "8443:8443"
      # Каждый новый inbound — ДОБАВИТЬ ПОРТ СЮДА!
    restart: unless-stopped
    network_mode: bridge
```

**КРИТИЧНО: при создании нового inbound в 3x-ui — добавь порт в docker-compose.yml `ports` и перезапусти контейнер!** Без этого xray слушает внутри контейнера, но порт недоступен снаружи.

### Сертификаты

Для WS+TLS inbound'ов нужен Let's Encrypt сертификат. Рекомендуется `acme.sh` с reloadcmd:
```bash
--reloadcmd "/usr/local/bin/cert-reload.sh"
```
Скрипт: `systemctl reload nginx && docker restart 3x-ui`

### Краткая навигация по xray.md

- **Выбор транспорта** — когда что использовать
- **VLESS + TCP + Reality** — основной, без домена
- **VLESS + XHTTP + Reality** — CDN-совместимый, новый
- **VLESS + WebSocket + TLS** — fallback с доменом
- **Оптимальные настройки** — ALPN, flow, sniffing
- **Диагностика** — логи, порты, типичные ошибки

---

## 6. Автобэкапы

### Паттерн: cron + скрипт + ротация

Для каждого сервиса — отдельный скрипт и cron-задача:

```bash
# /usr/local/bin/<service>-backup.sh
#!/bin/bash
BACKUP_DIR=/var/backups/<service>
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/backup-$(date +%F).tar.gz" /path/to/data
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete
```

```bash
# /etc/cron.d/<service>-backup
30 2 * * * root /usr/local/bin/<service>-backup.sh >/dev/null 2>&1
```

### Автообновление Docker-образов (с rollback)

Паттерн: бэкап → pull → up → healthcheck → rollback при ошибке.
Запуск по cron (раз в неделю). Логировать в `/var/log/<service>-update.log`.

---

## 7. VPN-клиент на роутере (Keenetic и др.)

### AmneziaWG на Keenetic

Keenetic Ultra поддерживает AmneziaWG нативно (KeeneticOS 4.1+).
1. Создай клиента в wg-easy → скачай .conf
2. Keenetic → VPN → AmneziaWG → Add tunnel → импортируй .conf

### Gotcha: админ-панели недоступны через VPN

Когда роутер маршрутизирует весь трафик (0.0.0.0/0) через VPN, WireGuard добавляет
host-route для IP сервера в обход туннеля. Трафик к панелям (тот же IP, другие порты)
идёт напрямую через ISP, а не через туннель → IP не в allowed-листе → блокируется UFW.

**Решение:** при подключении через VPN обращаться к панелям по внутреннему WG-адресу
(например `https://10.8.0.1:<PORT>`). Будет cert warning (сертификат на домен) — ОК.

---

## 8. Диагностика и отладка

### Контейнер не стартует

```bash
sudo docker logs <container> --tail 100
sudo ss -tlnp | grep <PORT>        # порт занят?
sudo docker ps --format "table {{.Names}}\t{{.Ports}}"
```

### VPN поднялся но трафик не идёт

```bash
sysctl net.ipv4.ip_forward              # = 1?
sudo iptables -t nat -L POSTROUTING -v -n
sudo docker exec wg-easy wg show        # peers
sudo ufw status
```

### Порт недоступен снаружи

```bash
sudo ss -tlnp | grep <PORT>     # слушается?
sudo ufw status | grep <PORT>   # UFW разрешает?
sudo docker ps | grep <PORT>    # проброшен в docker-compose?
# Если всё ОК — проверь облачный файрвол провайдера
```

### Системные ресурсы

```bash
free -h && df -h
sudo docker stats --no-stream
```

---

## 9. Pitfalls — что НЕ делать

1. **Не забывай удвоить `$` в PASSWORD_HASH** — `$` → `$$` в docker-compose.yml
2. **Не закрывай SSH** до проверки что UFW не заблокировал SSH порт
3. **Не используй `ufw reset`** — сбросит все правила включая SSH
4. **Не правь конфиги WireGuard вручную** пока wg-easy запущен — перезапишет
5. **Не забывай добавлять порты** в docker-compose.yml при создании inbound'ов в 3x-ui
6. **Не используй порт 443 одновременно** для xray и nginx без SNI-роутинга
7. **Ubuntu 24.04 ssh.socket** — Port в sshd_config игнорируется, менять через socket override
8. **Docker обходит UFW** — для ограничения Docker-портов используй DOCKER-USER iptables
9. **50-cloud-init.conf** может перезаписать SSH hardening — проверяй sshd_config.d/
10. **wg-easy v15 IPv6** — не трогай ipv6_address/ipv6_cidr в DB, отключай через allowed_ips
