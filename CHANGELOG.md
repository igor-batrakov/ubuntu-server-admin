# Изменения

## 2026-09-26 — публичный релиз

Репозиторий открыт. Структура приведена к виду «корень = скилл», как у
[new-vps-setup](https://github.com/igor-batrakov/new-vps-setup).

- Скилл в корне: установка одной командой `git clone … ~/.claude/skills/ubuntu-server-admin`.
  Сценарий первичной настройки (`KICKSTART.md`, `SETUP_INFO.example.md`) — в `scenario/`.
- Редко нужные разделы вынесены из `SKILL.md` в `references/`: апгрейд LTS
  (`release-upgrade.md`), автообновление Docker-образов (`image-updates.md`), аудит
  (`audit.md`). `SKILL.md` загружается целиком при каждой активации — стал на треть короче.
- Описание в frontmatter переписано с перечня ключевых слов на круг задач с границей
  относительно new-vps-setup.

### xray (`references/xray.md`)

- Исправлено: XHTTP + Reality через CDN не работает (CDN завершает TLS, Reality требует
  прямого соединения). Добавлен вариант XHTTP + TLS на своём домене через CDN, совет по
  миграции с WebSocket исправлен.
- Исправлено: в Docker-образе xray конфиг читается из `/usr/local/etc/xray`; прежний пример
  монтировал в `/etc/xray`, и контейнер стартовал без конфига. Подкоманды `uuid`/`x25519`
  вызываются без лишнего `xray`.
- Reality: `target` вместо `dest`, `raw` вместо `tcp`, `password` вместо `publicKey`; выбор
  target (та же ASN, RealiTLScanner; не microsoft/apple/сайты за Cloudflare).
- 3x-ui 3.x: переезд API в 3.3.0, автомиграции БД, `admin`/`admin` в Docker-образе.
- Клиенты: AmneziaVPN 5.x умеет xray, NekoRay заменён на Throne.

### AmneziaWG

- Ubuntu 26.04 поддерживается: kernel-модуль из PPA ставится и грузится на ядре 7.0
  (проверено на 26.04.1).
- Исправлено: установка модуля из исходников клонировала репозиторий в `/usr/src` целиком и
  падала на `dkms add` (`Could not locate dkms.conf`) — теперь через `make dkms-install`.
- Раздел о версиях переписан: протокол 1.0–3.1, кто что поддерживает (модуль, amneziawg-go,
  wg-easy v15.4, клиент AmneziaVPN, Keenetic), совместимость поколений tools и модуля.

### Базовые шаги под Ubuntu 26.04

- Drop-in sshd — `00-hardening.conf` (first match wins над `50-cloud-init.conf`).
- Таймеры отката — `--on-calendar` вместо `--on-active` (тот перевзводится каждым
  `daemon-reload`).
- fail2ban: полный `jail.d` с `backend = systemd` для sshd, проверка через `fail2ban-regex`.
- unattended-upgrades: проверка пакета, таймеров и конфига сразу, включение без TTY.
- sudo для агента: режимы A (пользователь запускает скрипт сам) и B (временный NOPASSWD
  с таймером); пароли — только в отдельном окне терминала.
- sudo-rs, `/tmp` в tmpfs, `ufw --force enable`, бэкапы конфигов вне `*.d`, `sshd -T -C`
  при блоках `Match`.
