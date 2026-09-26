# ubuntu-server-admin

Скилл `ubuntu-server-admin` для Claude Code и интерактивный сценарий настройки VPS вокруг него:
SSH hardening, AmneziaWG VPN, xray (VLESS+Reality), Docker, nginx, автобэкапы, диагностика,
аудит, апгрейд LTS → LTS.

> **Это третий, продвинутый уровень.** Если сервер настраивается впервые или нужен безопасный
> минимум и «прод без усложнений» — начинай с [`new-vps-setup`](https://github.com/igor-batrakov/new-vps-setup):
> уровень 1 «сервер можно оставить включённым», уровень 2 «это прод», с гейтом от «я заперся»,
> диагностикой с вердиктами и runbook'ами. Сюда переходи, когда тот чеклист пройден, а нужны
> VPN, DOCKER-USER, смена порта SSH с dead-man switch, аудит Lynis/ssh-audit, автообновление
> образов с откатом.

**Сам скилл** — [`skills/ubuntu-server-admin/`](skills/ubuntu-server-admin/): `SKILL.md` плюс
`references/xray.md` и `references/amneziawg-userspace.md`. Подключается симлинком в
`~/.claude/skills/ubuntu-server-admin` (не копией: копии расходятся). Ниже — сценарий
интерактивной настройки, который этот скилл использует.

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
git clone https://github.com/igor-batrakov/ubuntu-server-admin.git && cd ubuntu-server-admin

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

- Ubuntu 24.04 или 26.04 LTS
- Минимум 1 GB RAM, 10 GB диск
- Чистая установка (или частично настроенная — Claude проверит)
