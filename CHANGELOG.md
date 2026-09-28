# Изменения

## 2026-09-28 — wg-easy в режиме AWG вечно unhealthy

- Встроенный healthcheck образа wg-easy:15 зовёт `wg show`, а интерфейс с
  `OVERRIDE_AUTO_AWG=awg` имеет тип `amneziawg` и виден только `awg show`. Контейнер
  всегда `unhealthy`. В compose-пример добавлен свой `healthcheck` на `awg show`
  (проверено на стенде vdsina-ned-2: `healthy`), в диагностике `wg show` заменён на `awg show`.
- Раздел 0: `sudo wg show` на хосте ничего не показывал — `wg0` у wg-easy живёт в сети
  контейнера. Заменён на `docker exec wg-easy awg show`.

## 2026-09-26 — живой прогон VPN на Ubuntu 26.04 (1 vCPU, 1 ГБ)

Поднят AmneziaWG + xray на чистом после new-vps-setup сервере строго по скиллу; всё, что
не сработало или сработало не так, внесено.

- **wg-easy генерирует AWG 1.0.** Новый подраздел «Поднять обфускацию до 2.0»: S3/S4 с расчётом
  по MTU, непересекающиеся диапазоны H, I1; I1 с интерфейса к клиентам не копируется — задавать
  в `userconfig.defaultI1` и у существующих клиентов (API wg-easy).
- Compose wg-easy по официальному v15 (IPv6-сеть, `/lib/modules`), `OVERRIDE_AUTO_AWG=awg`,
  `INIT_*` через `env_file` с удалением после первого старта.
- Заголовки ядра — метапакетом `linux-headers-generic`: с `linux-headers-$(uname -r)` после
  обновления ядра DKMS не соберёт модуль.
- nginx: объявление `limit_req_zone` (без него `nginx -t` падает), убрать default-сайт,
  `X-Forwarded-*`.
- DOCKER-USER: проверенный скрипт со своей цепочкой и юнитом `PartOf=docker.service`;
  `--ctdir ORIGINAL` обязателен — без него режутся ответы контейнера.
- xray: `dl.google.com` отвечает редиректом — убран из рекомендаций; в скане подсети VPS
  половина «соседей» — чужие Reality-серверы, фильтр по A-записи; 3x-ui 3.8: `XUI_PORT`,
  `XUI_INIT_WEB_BASE_PATH`, смена логина из контейнера, API с Bearer-токеном, `tgId` — число.
- Новый `references/vpn-testing.md`: клиенты AmneziaWG и xray в Docker, снимок I1 на проводе,
  проверка панелей снаружи, повтор после перезагрузки.
- `diagnose.sh`: уровень обфускации AWG (1.0 / 1.5 / 2.0 + I1), правила во вложенных цепочках
  DOCKER-USER, ловушка без `--ctdir`.
- Примеры портов в SETUP_INFO — выше `ip_local_port_range`.

## 2026-09-26 — scripts/diagnose.sh

- Read-only диагностика уровня 3 с вердиктами `[OK]`/`[!!]`/`[..]` и номером раздела: порт SSH
  vs `ssh.socket`, таймеры отката и временный NOPASSWD, Docker-порты в обход UFW (с учётом
  DOCKER-USER, включая `--ctorigdstport`; громко — только панели и БД), лог-ротация Docker,
  kernel-модуль / DKMS / заголовки / amneziawg-go, обфускация на интерфейсах (`jc`, `i1`),
  несовпадение поколений tools и модуля, wg-easy (v14, `INIT_PASSWORD`, откат на обычный
  WireGuard, открытая панель), xray в Docker без своего конфига, 3x-ui на 2053,
  предупреждения xray из логов, кратко — автообновления, fail2ban, nginx.
- Обкатан на шести серверах с разными связками (wg-easy v14/v15, kernel-модуль,
  amneziawg-go, 3x-ui 3.7/3.8, Ubuntu 22.04/24.04/26.04); ложные срабатывания исправлены.
- `references/xray.md`: минимальная версия клиента Reality по умолчанию — v26.3.27.
- Шаблон issue «Устарело или не сработало».

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
