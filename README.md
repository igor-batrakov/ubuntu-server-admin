# ubuntu-server-admin

Скилл для Claude Code и совместимых агентов по продвинутому администрированию Ubuntu-серверов:
VPN для обхода DPI (AmneziaWG, xray), Docker за файрволом, смена порта SSH без риска
запереться, апгрейд LTS → LTS, автообновление образов с откатом, аудит безопасности.
Тот же текст читается как справочник без агента.

Для кого: у вас уже есть сервер с базовой защитой, и нужно поднять на нём VPN или сделать то,
что выходит за рамки чеклиста. Сервер: Ubuntu 24.04 или 26.04 LTS.

> **Это третий уровень.** Если сервер настраивается впервые, начинайте с
> [new-vps-setup](https://github.com/igor-batrakov/new-vps-setup): уровень 1 «сервер можно
> оставить включённым», уровень 2 «это прод» — с гейтом от «я заперся», диагностикой с
> вердиктами, бэкапами и алертами. Сюда — когда тот чеклист пройден.

## Что внутри

| Тема | Где | Коротко |
|------|-----|---------|
| AmneziaWG + wg-easy | `SKILL.md`, раздел 4 | Версии протокола 1.0–3.1 и кто что поддерживает, kernel-модуль из PPA или исходников, wg-easy v15, nginx перед панелью |
| AmneziaWG без kernel-модуля | `references/amneziawg-userspace.md` | Сервер на `amneziawg-go`, CPS-мимикрия (I1), диагностика «клиент не подключается» |
| xray через 3x-ui | `references/xray.md` | VLESS + Reality / XHTTP / TLS через CDN, выбор target, клиенты, 3x-ui 3.x |
| Роутеры | `SKILL.md`, раздел 7 | Keenetic: пороги прошивки по версии AWG, скрытые параметры обфускации |
| Docker и UFW | `SKILL.md`, разделы 2–3 | Docker обходит UFW — цепочка DOCKER-USER, лог-ротация |
| SSH | `SKILL.md`, раздел 1 | `00-hardening.conf`, смена порта под `ssh.socket`, dead-man switch на `--on-calendar`, миграция ключей |
| Апгрейд LTS → LTS | `references/release-upgrade.md` | Обход «нет доступного апгрейда» без `-d`, tmux, резервный sshd, что проверить после |
| Автообновление образов | `references/image-updates.md` | Скрипт с различающим гейтом и откатом, четыре ловушки, стенд для проверки отката |
| Аудит | `references/audit.md` | Lynis, ssh-audit, Trivy: ложные срабатывания, вредные части hardening-гайдов, триаж CVE |
| Грабли | `SKILL.md`, раздел 10 | Что ломает сервер молча |

Проверено вживую на Ubuntu 26.04.1: kernel-модуль AmneziaWG 3.1 из PPA ставится и грузится
на ядре 7.0; конфиги xray из справочника проходят `xray run -test` на актуальном xray-core.

## Установка

```bash
# Claude Code
git clone https://github.com/igor-batrakov/ubuntu-server-admin.git ~/.claude/skills/ubuntu-server-admin

# Codex, Copilot CLI, Gemini CLI
git clone https://github.com/igor-batrakov/ubuntu-server-admin.git ~/.agents/skills/ubuntu-server-admin
```

После перезапуска сессии скилл включается сам по смыслу запроса («подними AmneziaWG»,
«почему Docker-порт открыт при включённом UFW», «обнови сервер до 26.04»). Обновление —
`git pull` в этом каталоге.

## Сценарий: сервер с VPN с нуля

В каталоге `scenario/` — пошаговый сценарий, который проводит агента от чистого сервера до
работающих AmneziaWG и xray:

```bash
git clone https://github.com/igor-batrakov/ubuntu-server-admin.git && cd ubuntu-server-admin
cp scenario/SETUP_INFO.example.md SETUP_INFO.md   # заполнить: IP, ключ, что ставить, порты
claude                                            # и вставить scenario/KICKSTART.md первым сообщением
```

`SETUP_INFO.md` в `.gitignore`: реальные IP в git не попадут. Пароли в файл не пишутся —
пароль хостера и sudo вы вводите сами в отдельном окне терминала (у агента нет TTY).
`CLAUDE.md` в корне — инструкции агенту для этого сценария.

Что понадобится: IP сервера и доступ от хостера, SSH-ключ ed25519, свои постоянные IP для
доступа к панелям (`curl ifconfig.me`), домен — только для XHTTP/WS через CDN и HTTPS-панели.
Сервер: от 1 ГБ RAM и 10 ГБ диска.

## Структура репозитория

```
ubuntu-server-admin/
├── SKILL.md                      # основной текст скилла, разделы 0–10
├── references/
│   ├── amneziawg-userspace.md    # AmneziaWG на amneziawg-go, диагностика хендшейка
│   ├── xray.md                   # транспорты xray, 3x-ui, клиенты
│   ├── release-upgrade.md        # апгрейд LTS → LTS
│   ├── image-updates.md          # автообновление Docker-образов с откатом
│   └── audit.md                  # Lynis, ssh-audit, Trivy
├── scenario/
│   ├── KICKSTART.md              # первое сообщение агенту
│   └── SETUP_INFO.example.md     # шаблон параметров сервера
├── CLAUDE.md                     # инструкции агенту для сценария
└── CHANGELOG.md
```

## Актуальность

AmneziaWG, wg-easy, xray и 3x-ui меняются каждые несколько недель. Разделы про них помечены
«состояние на …» и ссылаются на релизы — перед установкой сверяйтесь. Нашли устаревшее —
issue с версией и выводом команды.

## Вклад

Полезнее всего прогоны на живых серверах: что не сработало, на какой версии Ubuntu и
компонента, с выводом команды. Неточность или более безопасный вариант — issue или pull request.

## Лицензия

[MIT](LICENSE).
