# Kickstart — скопируй это сообщение в Claude Code

---

Привет! Начинаем настройку VPS сервера с нуля.

**Сначала прочитай файл `SETUP_INFO.md`** — там все параметры: IP сервера, SSH ключ,
что устанавливать. Не спрашивай о том, что там уже указано.

Затем приступай к настройке строго в следующем порядке:

---

### Шаг 1 — SSH доступ по ключу (САМЫЙ ВАЖНЫЙ шаг)

1. Скажи мне IP сервера и какую команду выполнить для первого подключения по паролю —
   я введу пароль сам в терминале
2. После подключения: создай пользователя `USERNAME` из SETUP_INFO.md, добавь SSH ключ из `SSH_PUBLIC_KEY_FILE`
3. Проверь вход по ключу — открой новое соединение и убедись что работает
4. **Только после успешной проверки** — отключи парольный доступ (PasswordAuthentication no)
5. Исправь `/etc/ssh/sshd_config.d/50-cloud-init.conf` если там `PasswordAuthentication yes`

### Шаг 2 — SSH hardening + fail2ban

- Параметры hardening в `/etc/ssh/sshd_config.d/99-hardening.conf`
- fail2ban: jails sshd + recidive, ignoreip из TRUSTED_IP в SETUP_INFO.md

### Шаг 3 — Система

- `apt update && apt upgrade -y`
- Временная зона из SETUP_INFO.md
- sysctl: ip_forward, rp_filter

### Шаг 4 — Docker + UFW

- Docker с лог-ротацией (`/etc/docker/daemon.json`)
- UFW: default deny incoming, SSH открыт, VPN порты по выбранным компонентам
- Панели (wg-easy UI, 3x-ui) — только доверенные IP из SETUP_INFO.md

### Шаг 5 — Компоненты (по SETUP_INFO.md)

- Если `INSTALL_AWG=yes` → wg-easy + AmneziaWG DKMS модуль
- Если `INSTALL_XRAY=yes` → 3x-ui с транспортами из XRAY_* переменных
- Если нужен домен (XRAY_WS=yes или DOMAIN задан) → сертификат через acme.sh

### Шаг 6 — Автобэкапы

- Cron + скрипты для каждого установленного компонента, ротация 7 дней

---

**По каждому шагу:**
- Сделай → проверь результат → сообщи что готово
- Спрашивай только при реальной развилке
- Перед изменением конфигов — делай бекап

Поехали!
