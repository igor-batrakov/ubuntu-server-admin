---
name: ubuntu-server-admin
description: >
  Системное администрирование Ubuntu Linux серверов: установка, настройка, hardening,
  VPN (AmneziaWG + wg-easy, xray через 3x-ui с VLESS + Reality/XHTTP для обхода DPI),
  файрвол UFW, Docker, nginx, автобэкапы, апгрейд LTS, аудит безопасности, диагностика.
  Используй при любых задачах: настройка Ubuntu сервера, VPN туннели, UFW, SSH hardening,
  AmneziaWG, WireGuard, wg-easy, xray, 3x-ui, Docker, обход DPI, split tunneling,
  диагностика сетевых проблем на Linux, подключение роутеров к VPN.
---

# Ubuntu Server Administration + VPN

> **Целевая ОС: Ubuntu 24.04 или 26.04 LTS.** Различия 26.04, которые ломают привычные
> команды: `sudo-rs` (другие тексты ошибок), `/tmp` в tmpfs, отказы SSH пишет `sshd-session`
> (см. fail2ban). DKMS-модуль AmneziaWG на ядре 26.04 (7.0) собирается: в PPA есть пакеты
> для 26.04 с сентября 2026, сборка из git master проверена. Старое «на 26.04 не собирается»
> ([issue #167](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/167))
> относилось к пакету 2025 года. Установка — раздел 4.
>
> **Уровень.** Этот скилл — продвинутый уровень: VPN, DOCKER-USER, смена порта SSH, апгрейд
> LTS, аудит, автообновление образов. Базовая настройка «для новичка» с гейтом от «я заперся»,
> режимами sudo и чеклистом — в [new-vps-setup](https://github.com/igor-batrakov/new-vps-setup);
> здесь базовые шаги даны кратко.

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
1. Сделай бекап **вне каталогов `*.d`**:
   `sudo mkdir -p /root/config-bak && sudo cp -a /etc/ssh /root/config-bak/ssh.$(date +%F-%H%M)`.
   Копия рядом с оригиналом в `*.d` опасна: `sshd_config.d/x.bak.conf` подхватится как конфиг,
   а на `.bak` в `apt.conf.d` apt ругается при каждом запуске
2. Проверь текущее состояние: `sudo systemctl status <service>` или `sudo docker ps`
3. После изменения — проверь результат по содержимому (`sshd -T`, `ufw status`, логи), а не по
   коду возврата
4. Если сломалось — восстанови бекап и перезапусти

**Никогда не закрывай SSH до проверки что UFW не заблокировал SSH порт.**

### Подключение к серверу

Первый вход (пароль): `ssh root@<SERVER_IP>` — пароль пользователь вводит сам, **в отдельном
окне терминала**. У инструмента Bash агента нет TTY, у префикса `!` в Claude Code CLI тоже:
приглашение пароля не появится, будет `Permission denied`. То же для sudo-пароля и passphrase.
После настройки ключа: `ssh <USERNAME>@<SERVER_IP>` или через alias в `~/.ssh/config`.

**sudo с паролем и агент.** Агент не может ввести sudo-пароль, поэтому режим выбирает
пользователь, один раз, в начале:
- **A (по умолчанию):** агент готовит скрипт, пользователь запускает его сам в отдельном окне:
  `ssh -t <alias> sudo bash /tmp/s.sh`.
- **B:** временный NOPASSWD отдельным файлом с таймером самоудаления (ниже, «NOPASSWD sudo»),
  снять в конце работ. Постоянный NOPASSWD «чтобы агенту было удобно» не предлагать.

Проверка, есть ли у агента sudo без пароля: `sudo -n true 2>&1 | head -1`. Пусто — есть.
Иначе `sudo: a password is required` (классический sudo) или
`sudo: interactive authentication is required` (sudo-rs, Ubuntu 26.04).

**Особенности 26.04:** `/tmp` — tmpfs, очищается при перезагрузке и живёт в RAM: логи
апгрейда, распаковку бэкапов и большие архивы — в `/var/tmp` или `/var/log`.

---

## 0. Диагностика текущего состояния

**Выполни ПЕРВОЙ перед любой настройкой.** Сервер скорее всего уже частично настроен.

```bash
# Система
lsb_release -a && uname -r
free -h && df -h && nproc

# SSH — эффективные значения, не файлы (в sshd_config.d действует «first match wins»).
# Если в конфиге есть блоки Match, sshd -T требует -C user=root,host=localhost,addr=127.0.0.1
sudo sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) '
ls /etc/ssh/sshd_config.d/
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null   # кому хостер дал sudo без пароля

# Автообновления безопасности — нужны все три условия, одного конфига мало
dpkg-query -W -f='${Status}\n' unattended-upgrades 2>/dev/null   # install ok installed
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer      # enabled, enabled
grep Unattended-Upgrade /etc/apt/apt.conf.d/20auto-upgrades       # "1"

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

### Что блокирует хостер (проверять ДО планирования портов)

Провайдеры режут порты молча, и это меняет план: какие транспорты поднимать, откуда
клонировать репозитории, чем слать алерты. Проверять фактом, а не по документации:

```bash
for p in 22 25 443 587 2083; do
  timeout 4 bash -c "cat < /dev/null > /dev/tcp/github.com/$p" 2>/dev/null \
    && echo "$p открыт" || echo "$p закрыт"
done
```

Реальный пример (AdminVPS, локация Польша, 08.2026): закрыт **исходящий TCP 22** —
`git clone git@github.com:…` не проходит, нужны HTTPS-клоны (важно для `amneziawg-tools`);
закрыт **исходящий SMTP** (25/465/587/2525) — почтовых алертов с сервера не будет,
только HTTPS-API. При этом заявленная в их же статье блокировка UDP 123 на исходящий
NTP не действовала — отсюда правило проверять, а не верить списку.

### Мусор в образе провайдера

Типовые находки на «чистом» VPS, которые стоит убрать до настройки:

- **`networking.service` / `ifup@eth0` в failed** — в образе остался ifupdown со статикой
  (`/etc/network/interfaces`, «Generated by SolusVM»), а интерфейс реально под
  netplan + systemd-networkd. `ifup` падает с `Address already assigned`.
  Лечение: оставить в `interfaces` только `lo` (бэкап оригинала), затем `apt purge ifupdown`.
- **Группы с несуществующим пользователем** (`grpck -r` → `no user <кто-то>`) — след
  удалённого юзера образа. Чистить правкой `/etc/group` и `/etc/gshadow`, потом `groupdel`.
- **Пустые строки в `/etc/shadow`** (`pwck -r` → `invalid shadow password file entry`).
- **`snapd` без единого snap'а** — удаление тянет метапакет `ubuntu-server-minimal`;
  это нормально, но после purge проверить `dpkg -l ubuntu-server ubuntu-minimal
  ubuntu-standard` и что нет пакетов в состоянии `rc`/`iU`.

После диагностики сообщи что найдено и **не начинай без подтверждения**.

---

## 1. Первичная настройка Ubuntu

> Проверь секцию 0 — возможно уже сделано.

### Обновление

```bash
sudo apt update && sudo apt upgrade -y
```

**Автообновления безопасности.** Образы хостеров бывают с удалённым пакетом
`unattended-upgrades` (`dpkg-query` показывает `deinstall ok config-files`) и выключенными
таймерами `apt-daily*` при лежащем «правильном» `20auto-upgrades` — сверяй три условия из
раздела 0. Включение без TTY (`dpkg-reconfigure` интерактивно не пройдёт):

```bash
sudo apt install unattended-upgrades -y
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -5
```

Автоперезагрузка (`Unattended-Upgrade::Automatic-Reboot`) — решение пользователя: на сервере
с VPN ночной reboot рвёт туннели на минуту-две.

### Ubuntu Pro / ESM (опционально)

Security-патчи для пакетов из `universe` (fail2ban, restic, certbot, часть nginx-модулей) на
LTS приходят только через ESM Apps, то есть с подпиской Ubuntu Pro. Личная подписка
бесплатна на несколько машин, токен — https://ubuntu.com/pro/dashboard. Условия и лимит
машин менялись, сверяй на сайте перед тем, как обещать «бесплатно».

```bash
sudo apt install ubuntu-pro-client -y     # в минимальных образах пакета может не быть
sudo pro attach <TOKEN>
pro status                                # esm-apps и esm-infra — enabled
```

Строки `ESMApps`/`ESM` в `/etc/apt/apt.conf.d/50unattended-upgrades` без подписки просто не
действуют, трогать их не нужно.

### Обновление релиза (LTS → LTS)

Штатный путь открывается только с выходом `.1` (для 26.04 — 26.04.1), поэтому сразу
после релиза `do-release-upgrade -c` отвечает «нет доступного апгрейда». Проверить,
вышел ли релиз вообще:

```bash
curl -s https://changelogs.ubuntu.com/meta-release | grep -E "^(Dist|Version|Supported):" | tail -6
```

`Supported: 1` в `meta-release` при `Supported: 0` в `meta-release-lts` = релиз стабилен,
закрыт именно LTS→LTS путь. Тогда обходить **не через `-d`** (это канал разработки),
а через временный `Prompt=normal` — он ведёт на тот же стабильный релиз:

```bash
sudo sed -i 's/^Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
sudo do-release-upgrade -c            # должно предложить новый релиз
tmux new-session -d -s upg "sudo DEBIAN_FRONTEND=noninteractive \
  do-release-upgrade -m server -f DistUpgradeViewNonInteractive > /var/log/upg.log 2>&1"
# лог не в /tmp: на 26.04 это tmpfs, и после ребута разбирать будет нечего
```

Обязательное вокруг:

- **tmux** (не голый ssh) — апгрейд идёт 20–40 минут и переживает обрыв;
- **открыть 1022/tcp** в UFW: апгрейдер поднимает резервный sshd на этом порту;
- перед стартом — `full-upgrade` + reboot, чтобы стартовать с актуального ядра;
- по окончании: вернуть `Prompt=lts`, закрыть 1022, **перезагрузиться вручную**
  (non-interactive режим может завершиться с `EXIT=0`, оставив старое ядро до ребута);
- **перепроверить sshd** после апгрейда — `sudo sshd -T | grep -iE 'permitroot|passwordauth'`.
  Пакет `openssh-server` обновляется, и вернувшийся `PasswordAuthentication yes` не заметен
  по одному лишь факту «вход по ключу работает»;
- `systemctl --failed` после ребута: юниты, сломанные апгрейдом, видны только там.

Свой sudo-пользователь и ключ должны существовать ДО апгрейда — иначе при проблеме
остаётся только VNC-консоль.

### Создание sudo пользователя

```bash
sudo adduser <USERNAME>
sudo usermod -aG sudo <USERNAME>
```

### SSH hardening

**Важно: Ubuntu 22.10+ (24.04, 26.04) запускает sshd через ssh.socket (socket activation).**
`Port` по-прежнему задаётся в `sshd_config`/`sshd_config.d/` — его читает генератор
`sshd-socket-generator` — но `restart ssh` порт не сменит. После правки:
`sudo systemctl daemon-reload && sudo systemctl restart ssh.socket`, проверка `ss -tlnp | grep sshd`.
Override с `ListenStream` был нужен только в 22.10–23.10.
Проверять через VNC-консоль провайдера на случай потери доступа!

Рекомендуемые параметры — в `/etc/ssh/sshd_config.d/00-hardening.conf`:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

**Почему `00-`, а не `99-`.** В `sshd_config.d/` файлы читаются по алфавиту и действует
«first match wins». `50-cloud-init.conf` хостера с `PasswordAuthentication yes` перебивает
любой `99-…`, а `00-…` идёт первым — чужой файл трогать не нужно, и откат сводится к удалению
одного своего файла. Сервер уже настроен по старой схеме (`99-hardening.conf` плюс правленный
`50-cloud-init.conf`)? Работает — не мигрируй. Если всё же меняешь, таймер отката должен
возвращать весь каталог из бэкапа, а не удалять один файл: иначе откат оставит
`50-cloud-init.conf` с `yes` без `99-…`.

Убедись что ключ добавлен ПЕРЕД отключением пароля:
```bash
cat /home/<USERNAME>/.ssh/authorized_keys
sudo sshd -t && sudo systemctl restart ssh
sudo sshd -T | grep -iE '^(permitrootlogin|passwordauthentication) '   # обе — no
# Проверь подключение в НОВОЙ сессии прежде чем закрывать текущую!
```

Проверяй РЕЗУЛЬТАТ через `sshd -T` (эффективные значения), а не содержимое файлов. При
блоках `Match` в конфиге `sshd -T` без контекста падает — добавь
`-C user=root,host=localhost,addr=127.0.0.1`.

#### Dead-man switch при рискованных правках sshd

Под socket-активацией (`systemctl is-active ssh.socket`) каждое подключение поднимает
свежий `sshd`, читающий конфиг заново — новый файл в `sshd_config.d/` применяется
к **следующему** подключению без reload. Плюс: reload не нужен. Минус: **плохой конфиг
ломает вход немедленно**.

Поэтому при рискованных правках (ограничение алгоритмов, смена аутентификации) порядок:

1. бэкап `/etc/ssh` в `/root/config-bak/` (не внутрь `sshd_config.d/`);
2. `sudo sshd -t -f /tmp/candidate.conf` — проверка синтаксиса БЕЗ применения;
3. **сначала взвести таймер авто-отката, только потом класть файл** — если положить файл
   первым, окно между «применилось» и «таймер взведён» уже может оказаться фатальным;
4. применить, проверить вход **новой** сессией;
5. отменить таймер.

```bash
# Абсолютное время (--on-calendar), НЕ --on-active: относительный таймер перевзводится
# каждым daemon-reload (любой apt install между «взвёл» и «проверил»), и откат молча уезжает
T=$(date -d '+5 min' '+%F %T')
sudo systemd-run --unit=ssh-rollback --on-calendar="$T" \
  /bin/sh -c 'rm -f /etc/ssh/sshd_config.d/<новый>.conf; systemctl daemon-reload; systemctl restart ssh.socket ssh.service'
# ... кладём файл, проверяем вход НОВОЙ сессией ...
sudo systemctl stop ssh-rollback.timer
```

Тот же приём для `ufw enable`: `sudo systemd-run --unit=ufw-rollback --on-calendar="$T" /usr/sbin/ufw disable`.
`Unit ssh-rollback.timer already exists` — прошлый таймер ещё висит: остановить и взвести
заново. Таймер транзитный и **не переживает reboot**: если сервер перезагрузился между
«взвёл» и «проверил», отката нет — иди в консоль провайдера.

`sshd -t` ловит синтаксис, но **НЕ ловит** «ни один клиент не сможет договориться»
об алгоритмах. Последний рубеж — VNC-консоль провайдера.

### SSH-ключи: ed25519 + безопасная миграция

**Политика ключей:** тип `ed25519` (не RSA); один ключ на сервер; имя `<сервер>_<устройство>` (тип в имени НЕ указывать — он уже внутри ключа); с passphrase + хранение в Keychain (macOS).

**NOPASSWD sudo — временно, на время настройки (режим B).** Файл проверяется `visudo` ДО того,
как попадёт в `sudoers.d` (файл с ошибкой ломает sudo целиком), и снимается сам через 4 часа:
```bash
#!/bin/bash
# sudo-temp-on.sh <USERNAME> — запускает пользователь: ssh -t <alias> sudo bash /tmp/sudo-temp-on.sh <USERNAME>
set -euo pipefail
U="${1:?пользователь}"
F=/etc/sudoers.d/90-setup-temp
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > /root/90-setup-temp
visudo -cf /root/90-setup-temp
install -m 440 -o root -g root /root/90-setup-temp "$F"
systemctl stop sudo-temp-expire.timer 2>/dev/null || true
EXP=$(date -d '+4 hours' '+%F %T')          # абсолютное время, см. dead-man switch
systemd-run --unit=sudo-temp-expire --on-calendar="$EXP" /bin/rm -f "$F"
echo "NOPASSWD для $U до $EXP"
```
Снять в конце работ: `sudo rm -f /etc/sudoers.d/90-setup-temp && sudo systemctl stop sudo-temp-expire.timer`,
затем `sudo -k && sudo -n true 2>&1 | head -1` должен снова просить пароль. После reboot
таймера нет, а файл остался — проверь `systemctl list-timers sudo-temp-expire.timer`.

**Безопасная миграция/добавление ключа — порядок «добавить новый → проверить → удалить старый» (НЕ запираясь):**
```bash
# 1. Локально: ed25519 с passphrase
ssh-keygen -t ed25519 -f ~/.ssh/<server>_<device> -C "<server>_<device>"
# 2. Добавить .pub РЯДОМ со старым (append, старый НЕ трогать)
ssh-copy-id -i ~/.ssh/<server>_<device>.pub <user>@<host>
# 3. Загрузить в agent+Keychain и проверить вход по НОВОМУ ключу в ОТДЕЛЬНОЙ сессии + sudo
ssh-add --apple-use-keychain ~/.ssh/<server>_<device>
ssh -i ~/.ssh/<server>_<device> -o IdentitiesOnly=yes <user>@<host> 'whoami; sudo whoami'
# 4. Обновить ~/.ssh/config: IdentityFile ~/.ssh/<server>_<device> + IdentitiesOnly yes
# 5. ТОЛЬКО ТЕПЕРЬ удалить старый ключ (с бэкапом)
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-$(date +%F)
sed -i '/<old-key-comment>/d' ~/.ssh/authorized_keys
```

**Перед сменой пользователя входа / закрытием root** проверь `sudo passwd -S <user>` = `P` (пароль есть) → VNC-консоль провайдера как fallback на случай потери SSH.

**Gotcha (macOS, passphrase-ключ неинтерактивно):** для `ssh-add` в скрипте без tty —
`SSH_ASKPASS=<script> SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh-add --apple-use-keychain ~/.ssh/key`, где `<script>` делает `cat` файла с passphrase.

**Gotcha (sudo + редирект):** `sudo cmd < /root/file` падает с `Permission denied` — редирект `<` открывает shell под обычным юзером, не под root. Используй `sudo cat /root/file | ...` или `sudo sh -c '... < /root/file'`.

### fail2ban

```bash
sudo apt install fail2ban -y
```

`/etc/fail2ban/jail.d/local.conf` (выложить файлом, не `echo | tee`):
```ini
[DEFAULT]
# свои постоянные адреса (дом, офис, VPN-выход) — спросить у пользователя
ignoreip = 127.0.0.1/8 ::1 <TRUSTED_IP>
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[sshd]
enabled = true
# Образ без rsyslog: /var/log/auth.log нет, и jail с файловым backend падает
# с «Have not found any log file for sshd jail». Пакет 26.04 ставит systemd сам
# (defaults-debian.conf), явная строка — страховка для образов и версий, где это не так
backend = systemd
# port = <SSH_PORT>   # если порт SSH сменён
bantime = 6h
findtime = 30m
maxretry = 4

[recidive]
# читает /var/log/fail2ban.log — backend systemd сюда НЕ ставить
enabled = true
bantime = 7d
findtime = 1d
maxretry = 3
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
# Фильтр реально видит отказы? На свежем сервере нули в status ничего не доказывают:
sudo fail2ban-regex systemd-journal[journalflags=1] 'sshd[mode=normal]' | tail -3
```

Ноль совпадений у сервера, который час висит в интернете, = фильтр не видит логи. На 26.04
отказы пишет процесс `sshd-session`, а не `sshd`; jail ловит их через `_SYSTEMD_UNIT=ssh.service`.

---

## 2. UFW

### Базовая настройка

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow <SSH_PORT>/tcp comment 'SSH'
# ВАЖНО: убедись что SSH порт добавлен ПЕРЕД enable!
sudo ufw status numbered   # проверь что SSH есть в списке
sudo ufw --force enable    # без --force и без TTY enable молча отменяется
sudo ufw status verbose    # Status: active и SSH в списке
```

Перед `enable` — таймер отката `ufw disable` (см. dead-man switch в разделе 1).

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

### AmneziaWG — версии протокола

Состояние на сентябрь 2026 — меняется быстро, перед установкой сверяй релизы
[модуля](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/tags),
[wg-easy](https://github.com/wg-easy/wg-easy/releases) и
[клиента](https://github.com/amnezia-vpn/amnezia-client/releases).

| Версия | Что добавляет (ключи в `[Interface]`) |
|---|---|
| 1.0 | `Jc/Jmin/Jmax` (junk-пакеты), `S1/S2`, статичные `H1–H4` |
| 1.5 | + `I1–I5` — сигнатурные пакеты (CPS), мимикрия под DNS/QUIC/SIP |
| 2.0 | + `S3/S4`, диапазоны `H1–H4` (`H1 = 100-200`) |
| 3.0 | + `HeaderProtectionKey` (генерируется `awg genkey`, требует `S1–S4 ≥ 12`), `ContentPaddingAddition`, таймеры диапазонами |
| 3.1 | + `RandomTrailers`, `DisableCookies` |

Версия конфига определяется по ключам: `HeaderProtectionKey` и другие ключи 3.x → 3.x;
`S3`+`S4` → 2.0; только `I1` → 1.5; ничего из этого → 1.0.

**Совместимость:**
- Новая реализация понимает старые конфиги: нулевое/пустое значение выключает механизм.
- Старый клиент конфиг с ключами 3.x **отвергает**, а несовпадение `HeaderProtectionKey`
  ломает хендшейк молча. Все параметры, кроме `Jc/Jmin/Jmax`, у сервера и клиента
  обязаны совпадать.
- **Поколения `amneziawg-tools` и модуля должны совпадать:** tools 1.0.x с модулем 3.x дают
  `attribute type 14 has an invalid length` ([wg-easy #2723](https://github.com/wg-easy/wg-easy/issues/2723)).
  Со свежим модулем из PPA бери wg-easy ≥ v15.4.0.

**Кто что поддерживает:**
- **Kernel-модуль** (PPA и git master) — 3.1. Номер пакета `amneziawg-dkms 1.0.0` не значит
  «протокол 1.0».
- **amneziawg-go** (userspace) — 3.1. Рецепт сервера без модуля —
  `references/amneziawg-userspace.md`.
- **wg-easy v15.4.0** — в UI до 2.0 (`I1–I5`, `S3/S4`, диапазоны `H`); ключи 3.x есть только в
  master/nightly. Нужен `EXPERIMENTAL_AWG=true`. Автодетект смотрит только на kernel-модуль:
  без него откат на обычный WireGuard.
- **Клиент AmneziaVPN** — 3.0 с 5.0.0.5, 3.1 с 5.0.1.5. Self-hosted мастер Amnezia ставит 3.1.
- **Keenetic** — до 2.0, см. раздел 7.

**Что выбирать:** для wg-easy — 2.0 (максимум, который даёт стабильный релиз), с `I1` для
мимикрии. 3.x — когда нужен и сервер, и все клиенты на 3.x-реализациях (роутеры Keenetic 3.x
не умеют).

### Установка kernel-модуля AmneziaWG

Выполнить на хосте (не внутри контейнера). Если включён Secure Boot
(`mokutil --sb-state` → `enabled`), неподписанный DKMS-модуль не загрузится; на VPS обычно
выключен.

**Вариант 1 — PPA (официальный путь, есть пакеты для 24.04 и 26.04):**

```bash
sudo apt install -y software-properties-common linux-headers-$(uname -r)
sudo add-apt-repository -y ppa:amnezia/ppa
sudo apt install -y amneziawg-dkms          # amneziawg-tools нужен, только если awg на хосте
dkms status                                 # amneziawg/1.0.0, <ядро>: installed
```

**Вариант 2 — из исходников** (PPA недоступен или нужен коммит новее пакета). `dkms.conf`
лежит в `src/`, поэтому клон репозитория целиком в `/usr/src/amneziawg-1.0.0` не работает
(`Could not locate dkms.conf`) — исходники кладёт `make dkms-install`:

```bash
sudo apt install -y dkms git build-essential linux-headers-$(uname -r)
git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module /opt/amneziawg-src
cd /opt/amneziawg-src/src && sudo make dkms-install
sudo dkms add -m amneziawg -v 1.0.0
sudo dkms build -m amneziawg -v 1.0.0
sudo dkms install -m amneziawg -v 1.0.0
```

Проверено сборкой на заголовках ядра Ubuntu 26.04 (`7.0.0-34-generic`, коммит `4569c4c`,
26.09.2026). Этот путь не обновляется сам: после `git pull` — `dkms remove` старой версии,
затем все шаги заново.

Дальше для обоих вариантов:

```bash
sudo modprobe amneziawg
echo "amneziawg" | sudo tee /etc/modules-load.d/amneziawg.conf
lsmod | grep amneziawg
```

Если `linux-headers-$(uname -r)` не найден — ядро обновилось без перезагрузки:
`sudo apt upgrade -y` и перезагрузись. DKMS пересобирает модуль при каждом новом ядре; после
обновления ядра проверь `dkms status`, что для него модуль `installed`.

### Настройка wg-easy v15+

**В v15 НЕТ переменных `PASSWORD_HASH`, `WG_HOST`, `WG_DEFAULT_DNS` и т.п.** (это API v14).
С `PASSWORD_HASH` в environment контейнер v15 вообще **откажется стартовать** — это защита
от случайного автообновления с v14. Настройка теперь двумя способами:

1. **Веб-визард** при первом заходе в UI (логин/пароль админа, host, порт, DNS)
2. **Unattended через `INIT_*`-переменные** — применяются только при ПЕРВОМ старте
   (потом всё меняется через Admin Panel в UI)

### docker-compose.yml (пример, v15+)

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      - INIT_ENABLED=true
      - INIT_USERNAME=admin
      - INIT_PASSWORD=<ADMIN_PASSWORD>        # пароль веб-панели
      - INIT_HOST=<SERVER_IP>                 # host в конфигах клиентов
      - INIT_PORT=<WG_PORT>                   # UDP-порт WireGuard/AWG
      - INIT_DNS=1.1.1.1,8.8.8.8
      - EXPERIMENTAL_AWG=true                 # AmneziaWG; автодетект модуля, fallback на WG
      # - OVERRIDE_AUTO_AWG=awg               # принудительно AWG (без fallback на WG)
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

`INIT_*`-переменные действуют группой: задал `INIT_PASSWORD` — задай и `INIT_USERNAME`,
`INIT_HOST`, `INIT_PORT`. После первого старта убери `INIT_PASSWORD` из compose
(секрет в файле не нужен — дальше всё через UI).

**Важно:** UI привязан к `127.0.0.1` — доступ только через nginx reverse proxy.

### Новое в wg-easy v15.3: Firewall

Появилась функция ограничения доступа клиентов к конкретным сетям/хостам (аналог per-peer allowedIPs, но через UI). Настраивается в карточке клиента в панели. Полезно когда один клиент должен видеть только часть сети через VPN.

### nginx reverse proxy для wg-easy UI

**Два варианта в зависимости от наличия домена:**

#### Вариант А: с доменом (DOMAIN задан)

Сертификат получить через acme.sh (см. секцию 5). Затем:

```nginx
server {
    listen <EXTERNAL_UI_PORT> ssl;
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
    listen <EXTERNAL_UI_PORT> ssl;

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

**Версия:** бери актуальный последний релиз с https://github.com/MHSanaei/3x-ui/releases
(подставь тег вместо `<VERSION>`). При **мажорном** переходе (например 2.x → 3.x) сначала
прочитай changelog на breaking changes и сделай бэкап `./db` перед обновлением.

```yaml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:<VERSION>  # актуальный тег с releases
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

Паттерн: **проверка нового образа → бэкап данных → pull → up → различающий гейт →
откат при провале → пауза**. Cron раз в неделю, лог в `/var/log/<service>-update.log`.

Ниже — четыре места, где такой скрипт годами делает вид, что работает.

#### Ловушка 1: сравнение «есть ли новый образ»

`docker images -q <tag>` отдаёт **короткий** ID (`0e7bc9d34e86`), а
`docker inspect <container> --format '{{.Image}}'` — **полный** (`sha256:0e7bc9d34e86…`).
Они не равны НИКОГДА → ветка «обновления нет» недостижима → контейнер пересоздаётся
каждый прогон, а лог каждый раз врёт «New image found».

```bash
# правильно — обе величины в полном формате
docker image inspect <tag>       --format '{{.Id}}'
docker inspect     <container>   --format '{{.Image}}'
```

**ID работающего контейнера снимать ДО `docker compose pull`** — после pull тег уже
указывает на новый образ, и цель отката потеряна.

#### Ловушка 2: сам откат

`docker compose down` + `docker compose up -d` по ТОМУ ЖЕ compose-файлу поднимает тот
же самый новый образ — отката не происходит. Правильный порядок:

```
down → распаковать pre-update бэкап в каталог тома → docker tag <старый полный ID> <тег из compose> → up -d
```

Почему `docker tag`: тег в compose обычно пиннут точно (`image: foo:1.2.3`), а новый
образ приезжает **под тем же тегом** — правкой compose назад не вернёшься. Локальное
переназначение тега на прежний ID решает это, не трогая файл.
Восстановление данных обязательно: **миграции БД односторонние**, старый образ на новой
схеме может не стартовать.

#### Ловушка 3: гейт, который не умеет показать «плохо»

Типовая ошибка — считать успехом «контейнер healthy». Реальный пример: healthcheck
`awg show | grep -q interface` проходит и на обычном WireGuard, то есть обфускация
AmneziaWG может молча отвалиться при всех зелёных сигналах. Счётчик пиров тоже не
помогает — он читается из БД, а не с провода. Различающий признак для AWG — строки
`jc:`/`jmin:` в выводе `awg show` (на обычном WireGuard их нет).
**Общее правило: гейт, который не может показать «плохо», бесполезен.**

#### Ловушка 4: молчаливая заморозка

После отката писать файл-флаг (`/var/lib/<service>-update.hold`) и на следующих прогонах
выходить — иначе тот же битый образ подтягивается каждую неделю, роняя сервис и
откатываясь по кругу. О паузе слать **уведомление на каждом прогоне**, а не писать в лог:
иначе заморозка обновлений становится тихой и о ней забывают.

#### Рабочий пример

```bash
#!/bin/bash
# /usr/local/bin/<service>-update.sh — cron раз в неделю
set -u
CD=/opt/<service>
TAG=ghcr.io/<vendor>/<service>:<version>   # тег как в compose
CT=<service>                                # имя контейнера
VOL=/var/lib/docker/volumes/<service>-data/_data
HOLD=/var/lib/<service>-update.hold
BK=/var/backups/<service>/pre-update-$(date +%F-%H%M).tar.gz

notify() { curl -fsS -m 10 --data-urlencode "text=$1" "<NOTIFY_URL>" >/dev/null; }

# Пауза после отката: ничего не делаем, но НАПОМИНАЕМ каждый прогон
[ -f "$HOLD" ] && { notify "<service>: обновления на паузе с $(cat "$HOLD")"; exit 0; }

# Гейт различающий, а не «healthy»: обфускация AWG жива, если есть jc:/jmin:
# для другого сервиса — свой различающий признак, не «healthy»
gate() { docker exec "$CT" awg show 2>/dev/null | grep -qE '(^|[[:space:]])(jc|jmin):'; }

cd "$CD" || { notify "<service>: нет каталога $CD"; exit 1; }
RUNNING=$(docker inspect "$CT" --format '{{.Image}}')   # ДО pull — это цель отката
docker compose pull -q
NEW=$(docker image inspect "$TAG" --format '{{.Id}}')
[ "$NEW" = "$RUNNING" ] && { echo "$(date +%F-%T) обновления нет"; exit 0; }

mkdir -p "$(dirname "$BK")"
tar -czf "$BK" -C "$VOL" . || { notify "<service>: pre-update бэкап не сделан, обновление отменено"; exit 1; }
docker compose up -d

for _ in $(seq 30); do gate && break; sleep 2; done
if gate; then
  echo "$(date +%F-%T) обновлён: $RUNNING -> $NEW"
  exit 0
fi

# ОТКАТ: down → данные → тег на прежний ID → up
docker compose down
# Целостность бэкапа проверяем ДО того, как что-то удалять: иначе битый архив
# оставит пустой том без единой копии данных. И строки не сцепляем в одну —
# в `find ... && tar ... || notify` ветка || относится только к find.
tar -tzf "$BK" >/dev/null \
  || { notify "<service>: pre-update бэкап битый — откат данных НЕ начат"; exit 1; }
find "$VOL" -mindepth 1 -delete
tar -xzf "$BK" -C "$VOL" \
  || { notify "<service>: ОТКАТ ДАННЫХ ПРОВАЛЕН, том ПУСТ, бэкап $BK"; exit 1; }
# старый образ мог быть вычищен docker system prune — тогда откат невозможен, и up -d
# поднял бы битый образ на восстановленных старых данных
docker tag "$RUNNING" "$TAG" \
  || { date +%F-%T > "$HOLD"; notify "<service>: образ $RUNNING отсутствует локально — откат НЕВОЗМОЖЕН"; exit 1; }
docker compose up -d
date +%F-%T > "$HOLD"
notify "<service>: обновление провалено, откат на $RUNNING; обновления на паузе"
```

#### Как тестировать откат, не рискуя продом

Изолированный стенд: копия тома bind-mount'ом, контейнер под **другим именем** и **БЕЗ
публикации портов** (снаружи недоступен, клиентов не перехватит), заглушка вместо
реального канала уведомлений. Заведомо битый образ строится на месте:

```bash
printf 'FROM <рабочий-образ>\nENTRYPOINT ["/bin/false"]\n' | docker build -q -t <тег>:broken -
```

Проверять три сценария:
1. **«обновления нет»** — контейнер не должен пересоздаваться;
2. **«битый образ»** — должен откатиться, данные восстановиться;
3. **«пауза»** — следующий прогон не должен делать ничего.

Доказательство восстановления данных — mtime файла становится «tar-овским» (без наносекунд).

Ещё одна деталь: `gate()` возвращает false и когда контейнер упал, и когда он ещё
поднимается — эти два случая для скрипта неразличимы, поэтому крэш-луп будет честно
ждать все 60 секунд. Если это мешает, добавь перед циклом проверку
`docker inspect <ct> --format '{{.State.Status}}'` и выходи из ожидания сразу,
если статус `exited` или `restarting`.

#### Ремарка: пиннутый тег ≠ автообновление

Если тег в compose пиннут на неизменяемую версию (версионные теги ghcr immutable), то
`docker compose pull` **никогда** не принесёт другой digest, и такой «автообновлятор»
превращается в применялку с гейтами для РУЧНОЙ смены тега. О новых релизах он не сообщит —
для этого нужна отдельная проверка релизов через GitHub API.

### Gotcha: watchtower

Оригинальный `containrrr/watchtower` заброшен (последний релиз 2023) и падает на новых
Docker-демонах с ошибкой `client version 1.25 is too old. Minimum supported API version is 1.44`.
Признак: контейнер watchtower в бесконечном Restarting-loop, автообновления молча не работают.
**Лечение:** заменить на поддерживаемый форк `nickfedor/watchtower` (drop-in совместим,
те же аргументы). Урок общего вида: заброшенный образ может тихо умереть при обновлении
Docker-демона — при диагностике проверяй `docker ps` на Restarting-контейнеры.

---

## 7. VPN-клиент на роутере (Keenetic и др.)

### AmneziaWG на Keenetic

KeeneticOS поддерживает AmneziaWG нативно, но **с порогом по версии протокола**
([инструкция Amnezia](https://docs.amnezia.org/documentation/instructions/keenetic-os-awg/)):
- **1.5 / 2.0** — с KeeneticOS **5.1** (сейчас стабильная ветка; впервые — 5.1 Alpha 3).
  Ниже импорт `.conf` падает с `invalid H1 value` — и это читается как «файл битый», хотя
  дело в прошивке.
- **1.0 (legacy)** — с 4.2 Alpha 2, но эта версия ловится блокировками.
- **3.x** — не поддерживается (на сентябрь 2026). Конфиги Amnezia Premium выдаются в 3.x
  и в 2.0 не конвертируются — для роутера нужен свой сервер с конфигом ≤ 2.0.

Версия определяется по самому `.conf` — таблица в разделе 4.

1. Создай клиента в wg-easy → скачай .conf
2. Keenetic → VPN → AmneziaWG → Add tunnel → импортируй .conf

Параметры обфускации (`Jc/Jmin/Jmax/S1–S4/H1–H4/I1`) в веб-панели Keenetic **не видны
и не редактируются** — они импортируются из файла и живут скрыто. Посмотреть или задать их
вручную можно через CLI/rci-API роутера (`interface WireguardN wireguard asc …`).

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

## 9. Аудит безопасности

Разделы выше — про настройку и починку. Этот — про «насколько сейчас плохо».

**Политика раздела:** все три инструмента запускать **по требованию** (перед работами
и после них), **НЕ в cron** — иначе десятки предупреждений превращаются в шум, который
перестают читать. И у всех трёх в репозиториях Ubuntu лежат устаревшие версии — ставить
из upstream.

### Lynis — аудит конфигурации ОС (GPL-3.0)

В apt Ubuntu 24.04 — 3.0.9, актуальная 3.1.8. Ставить git-клоном в `/opt/lynis`.
Запуск **обязательно из своего каталога**, иначе `Fatal error: can't find include directory`:

```bash
sudo sh -c 'cd /opt/lynis && ./lynis audit system'
```

Read-only. Проверить `upload=no` в `default.prf` — тогда данные наружу не уходят.
Отчёт: `/var/log/lynis-report.dat` (строки `warning[]=` / `suggestion[]=`).

**Типичные ложные срабатывания:**
- `TIME-3185` «время не синхронизировалось» при работающем NTP — сверять `timedatectl`.
- `PKGS-7392` «найдены уязвимые пакеты» при пустом security-репозитории. Вдобавок
  в режиме `--quick` в логе видно `Checking upgradeable packages [SKIPPED]` — то есть
  предупреждение выдаётся **без выполненной проверки**.
- `ACCT-9626` «sysstat disabled» при `ENABLED="false"` в `/etc/default/sysstat`, когда
  данные всё равно собираются systemd-таймером — проверять `sar` и свежесть
  `/var/log/sysstat/saNN`.

Пометки `[fail]` на NIST-кривых (`ecdh-sha2-nistp*`) — **мнение автора инструмента,
а не консенсус**.

**Не окупается на VPS с малым RAM:** auditd, AIDE, отдельные разделы `/tmp` `/var` `/home`,
легальные баннеры, отключение USB и `dccp`/`sctp`/`rds`/`tipc`.

**ВРЕДНО:** пароль на GRUB (`BOOT-5122`), если VNC-консоль провайдера — резервный способ
входа при потере SSH.

**Hardening index — не цель.** Он почти не двигается от закрытия мелких пунктов, потому
что вес лежит в тяжёлых категориях, которые сознательно отклонены.

### ssh-audit — аудит алгоритмов SSH (MIT)

В apt — 3.1.0 от 2023, актуальная 3.9.0. Git-клон в `/opt/ssh-audit`, чистый Python 3,
зависимостей нет.

```bash
sudo python3 /opt/ssh-audit/ssh-audit.py -p 22 <host>
sudo python3 /opt/ssh-audit/ssh-audit.py -l fail --skip-rate-test <host>   # только критичное
sudo python3 /opt/ssh-audit/ssh-audit.py --get-hardening-guide "Ubuntu 24.04 Server"
```

⚠️ **Встроенный hardening-гайд НЕЛЬЗЯ применять как есть**, две части вредны:

1. `rm /etc/ssh/ssh_host_*` с перегенерацией ключей — **сменит отпечатки хоста**, все
   клиенты получат предупреждение и потребуют чистки known_hosts. Не нужно: достаточно
   исключить ECDSA через `HostKeyAlgorithms` — файл ключа остаётся, но сервер его
   не предлагает, отпечатки ed25519/RSA не меняются. Перед этим проверить, что
   в known_hosts клиентов есть запись ed25519, и что RSA host key ≥ размера
   из `RequiredRSASize`.
2. Секция rate-limiting ставит `iptables-persistent` и пишет правила в цепочку `INPUT`
   рядом с цепочками UFW — конфликт. Использовать `PerSourceMaxStartups`.

⚠️ **`PerSourceMaxStartups`:** значение `1` из гайда ломает пакетные подключения с одного
адреса (актуально, когда автоматизация ходит через один VPN-выход). Значение ~10
безопасно, НО метрику DHEat не удовлетворяет — проверено: после установки 10 тест
показывал 87.5 conn/s при пороге 20. То есть DHEat (CVE-2002-20001) закрывается только
значением `1` либо внешним rate-limiting; компромисс надо принимать осознанно.

⚠️ Флаг `--skip-rate-test` **молча пропускает** проверку DHEat — если перепроверяешь
именно её, флаг убрать, иначе «стало чисто» окажется артефактом.

Порог совместимости набора алгоритмов из гайда — любой клиент от OpenSSH 6.5 (2014).
Перед применением проверить, с каких клиентов реально ходят:
`journalctl -u ssh | grep "Accepted publickey"` и типы ключей в `authorized_keys`.

**Уже закрытое, чтобы не пугаться:**
- Terrapin (CVE-2023-48795) — если сервер объявляет strict kex, он защищён; ремарка
  про chacha20 в отчёте относится к непропатченным **клиентам**.
- `!diffie-hellman-group-exchange-sha256 (increase modulus size)` — не недоработка:
  fallback на 2048-битный модуль для очень старых клиентов вшит в код OpenSSH
  и отключается только пересборкой.

Правки sshd после аудита — через dead-man switch из раздела 1.

### Trivy — уязвимости Docker-образов (Apache-2.0)

В apt Ubuntu 24.04 нет. Ставить бинарь с GitHub releases **обязательно со сверкой sha256
из `trivy_<ver>_checksums.txt` до первого запуска**.

```bash
trivy image --scanners vuln --severity HIGH,CRITICAL --no-progress <образ>
trivy image --scanners vuln --severity HIGH,CRITICAL -f json -o /tmp/out.json <образ>
```

Таблицы парсятся плохо — для разбора брать JSON.

**Главное — триаж, а не список.** Ключевой вопрос по каждой находке:
**исполняется ли этот файл в рантайме?** Проверять фактом: `docker exec <container> ps aux`.

Реальный результат такой проверки: из 78 CVE (4 CRITICAL) релевантными остались **8** —
уязвимые бинари в образах не запускались: userspace-реализация VPN при работающем
kernel-модуле, `gosu` (отрабатывает при старте и выходит), утилита-сканер, не являющаяся
службой. Отдельный класс: DoS в библиотеке распаковки архивов — недостижим, если сервис
не распаковывает недоверенные архивы.

**«Образ новее ≠ уязвимостей меньше».** Проверено: обновление двух образов (свежее
на 2.5 недели) дало «исчезло 0, появилось 0» — мейнтейнер пересобрал их на той же базе
Alpine. Правильный порядок при обновлении ради безопасности:

```
docker pull (контейнер продолжает работать на старом образе)
  → trivy image нового
  → сравнить МНОЖЕСТВА CVE
  → и только если что-то реально закрывается — docker compose up -d
```

Сканировать лучше **по digest работающего контейнера**
(`docker inspect <container> --format '{{.Image}}'`), а не по тегу — это исключает дрейф
тега между замерами.

---

## 10. Pitfalls — что НЕ делать

1. **Не используй `PASSWORD_HASH`/`WG_HOST` с wg-easy v15+** — это API v14, контейнер с `PASSWORD_HASH` не стартует. Только `INIT_*` или веб-визард
2. **Не закрывай SSH** до проверки что UFW не заблокировал SSH порт
3. **Не используй `ufw reset`** — сбросит все правила включая SSH
4. **Не правь конфиги WireGuard вручную** пока wg-easy запущен — перезапишет
5. **Не забывай добавлять порты** в docker-compose.yml при создании inbound'ов в 3x-ui
6. **Не используй порт 443 одновременно** для xray и nginx без SNI-роутинга
7. **ssh.socket (24.04/26.04)** — после смены Port в sshd_config нужен `daemon-reload` + `restart ssh.socket`, простой `restart ssh` порт не сменит
8. **Docker обходит UFW** — для ограничения Docker-портов используй DOCKER-USER iptables
9. **Не называй drop-in sshd `99-…`** — `50-cloud-init.conf` с `PasswordAuthentication yes` его
   перебьёт (first match wins). Свой файл — `00-hardening.conf`, итог — по `sshd -T`
10. **wg-easy v15 IPv6** — не трогай ipv6_address/ipv6_cidr в DB, отключай через allowed_ips
11. **Не запускай длинные операции в foreground SSH, если SSH идёт через VPN этого же
    сервера.** Обновление `docker-ce` перезапускает демон → перезапускается VPN-контейнер →
    рвётся туннель → умирает SSH-сессия, а `apt-get` как её дочерний процесс может получить
    SIGHUP посреди распаковки. Проверять `echo $SSH_CONNECTION` (адрес из `172.16.0.0/12`
    или `10.8.0.0/24` = идёшь через туннель) и запускать detached:
    ```bash
    sudo systemd-run --unit=maint-apt --collect sh -c '... > /var/log/maint.log 2>&1'
    ```
    Отдельно **ДО** операции убедиться, что SSH-порт открыт не только для VPN-адресов,
    иначе падение туннеля запирает дверь.
12. **Не сравнивай digest образов «на глаз»** — две разные ловушки:
    (а) короткий ID из `docker images -q` против полного `sha256:` из `.Image`;
    (б) `RepoDigests[0]` локального образа — это digest манифест-**листа**, а
    `docker manifest inspect -v` отдаёт digest **платформенного** манифеста; сравнение этих
    двух даёт «есть новее» всегда, для любого образа. Правильно:
    `docker buildx imagetools inspect <img> --format '{{.Manifest.Digest}}'`.
    Признак, что сравнение сломано: «новее» показывают ВСЕ образы подряд, включая пиннутые
    версионные теги (на ghcr они неизменяемы).
13. **Не считай гейтом проверку, которая не может показать «плохо»** — healthcheck,
    проходящий и на деградировавшей конфигурации; счётчик сущностей, читаемый из БД вместо
    реального состояния.
14. **Не проверяй живость сервиса счётчиком соединений к БД и кодом 200 от фронта.**
    У пулов (напр. NestJS/TypeORM) подключение ленивое: в простое `pg_stat_activity`
    показывает ноль, и это НЕ означает потерю связи. А HTTP 200 от фронта может отдавать
    статика, за которой backend мёртв. Проверять запросом, который обязан сходить в БД
    (напр. логин с заведомо неверными данными → в ответе должна быть логика приложения,
    а не ошибка соединения).
15. **Не взводи таймер отката через `--on-active`** — каждый `daemon-reload` (любой `apt install`)
    перевзводит его заново, и откат молча уезжает. Только `--on-calendar` с абсолютным временем.
16. **Не бери tools и модуль AmneziaWG разных поколений** — `awg`/wg-easy с tools 1.0.x против
    модуля 3.x дают `attribute type 14 has an invalid length`. Со свежим модулем — wg-easy ≥ v15.4.0.
