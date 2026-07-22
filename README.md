# vps-setup

Интерактивная настройка VPS с нуля через Claude Code: SSH hardening, AmneziaWG VPN, xray (VLESS+Reality), автобэкапы.

## Что нужно подготовить ДО запуска

**1. IP сервера и root-пароль** — получи у провайдера при создании сервера.

**2. SSH-ключ на локальной машине:**
```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "your@email.com"
```

**3. Свои IP-адреса** — понадобятся для вайтлиста доступа к панелям:
```bash
curl ifconfig.me
```

**4. Домен** (опционально) — нужен только для VLESS+WS+TLS и HTTPS-панели 3x-ui.
   Если нет домена — VLESS+Reality работает без него.

## Как запустить

```bash
# Склонируй этот репозиторий и перейди в него
cd vps-setup

# 1. Создай локальную копию параметров и заполни все поля:
cp SETUP_INFO.example.md SETUP_INFO.md
# (SETUP_INFO.md в .gitignore — реальные IP и пароли не попадут в git)

# 2. Запусти Claude Code:
claude
# 3. Вставь содержимое KICKSTART.md как первое сообщение
```

## Что будет установлено (по выбору в SETUP_INFO.md)

| Компонент | Для чего |
|-----------|----------|
| SSH hardening + fail2ban | Защита от брутфорса |
| UFW | Файрвол |
| Docker | Контейнеры для всех сервисов |
| AmneziaWG (wg-easy) | VPN с обфускацией против DPI, роутеры Keenetic |
| xray (3x-ui) | Обход DPI — VLESS+Reality, XHTTP, WebSocket |
| nginx | Reverse proxy для панелей |
| Автобэкапы | Ежедневный бэкап с ротацией 7 дней |

## Требования к серверу

- Ubuntu 24.04 LTS (26.04 пока не брать — DKMS-модуль AmneziaWG не собирается на её ядре)
- Минимум 1 GB RAM, 10 GB диск
- Чистая установка (или частично настроенная — Claude проверит)
