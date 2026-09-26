#!/bin/bash
# diagnose.sh — read-only диагностика уровня 3: VPN, Docker за UFW, SSH под ssh.socket.
# Ничего не меняет: только читает конфиги и статусы. Запуск: sudo bash diagnose.sh
# Вывод: [OK] в порядке, [!!] проблема (с номером раздела SKILL.md), [..] справочно.
# Базовая защита (hardening, бэкапы, алерты) — diagnose.sh из new-vps-setup, здесь не дублируется.
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужны права root (sshd -T, ufw, iptables, docker). Запусти: sudo bash $0"
  exit 1
fi

TODO=()
ok()   { printf '  [OK] %s\n' "$1"; }
bad()  { printf '  [!!] %s  -> %s\n' "$1" "$2"; TODO+=("$2|$1"); }
info() { printf '  [..] %s\n' "$1"; }
h()    { printf '\n=== %s ===\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

UFW_ACTIVE=0
UFW_RULES=""
if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  UFW_ACTIVE=1
  UFW_RULES=$(ufw status 2>/dev/null)
fi
# Разрешён ли порт/протокол в UFW для всех (строка "PORT[/proto] ALLOW Anywhere")
ufw_allows() {
  echo "$UFW_RULES" | grep -E "^$1(/$2)?[[:space:]]+ALLOW[[:space:]]+(IN[[:space:]]+)?Anywhere" >/dev/null
}

# ---------------------------------------------------------------- система
h "Система"
info "$(lsb_release -ds 2>/dev/null || head -1 /etc/os-release), ядро $(uname -r)"
info "CPU: $(nproc), RAM: $(free -h | awk '/Mem/{print $2}'), диск /: $(df -h / | awk 'END{print $4 " свободно из " $2}')"
if [ -f /var/run/reboot-required ]; then
  bad "ждёт перезагрузки: новое ядро установлено, DKMS-модули собраны под него, но работает старое" "раздел 1"
fi

# ---------------------------------------------------------------- ssh
h "SSH"
SSHT=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1,lport=22 2>/dev/null)
if [ -z "$SSHT" ]; then
  bad "sshd -T не сработал — конфиг сломан? (sshd -t; journalctl -u ssh)" "раздел 1"
else
  PORTS=$(echo "$SSHT" | awk '$1=="port"{print $2}' | sort -u)
  info "порт(ы) по конфигу: $(echo "$PORTS" | paste -sd ' ')"
  for p in $PORTS; do
    if ss -Htln "sport = :$p" 2>/dev/null | grep -q .; then
      ok "порт $p слушается"
    else
      bad "Port $p задан в конфиге, но не слушается — под ssh.socket нужен daemon-reload + restart ssh.socket" "раздел 1, SSH hardening"
    fi
    if [ "$UFW_ACTIVE" = 1 ]; then
      if ufw_allows "$p" tcp || { [ "$p" = 22 ] && ufw_allows OpenSSH ""; }; then
        ok "порт SSH $p разрешён в UFW для всех"
      elif echo "$UFW_RULES" | grep -qE "^$p(/tcp)?[[:space:]]+ALLOW"; then
        info "порт SSH $p открыт в UFW только для части адресов — убедись, что это не только VPN-подсеть (раздел 10, п. 11)"
      else
        bad "порт SSH $p не разрешён в UFW" "раздел 2"
      fi
    fi
  done
  for k in passwordauthentication permitrootlogin; do
    v=$(echo "$SSHT" | awk -v k="$k" '$1==k{print $2}')
    case "$k:$v" in
      passwordauthentication:no|permitrootlogin:no) ok "$k $v" ;;
      *) bad "$k $v (эффективное значение)" "раздел 1, SSH hardening" ;;
    esac
  done
fi
info "активация: ssh.socket=$(systemctl is-active ssh.socket 2>/dev/null) ssh.service=$(systemctl is-active ssh.service 2>/dev/null)"
DROPINS=$(ls /etc/ssh/sshd_config.d/ 2>/dev/null | paste -sd ' ')
info "sshd_config.d: ${DROPINS:-пусто}"
for f in /etc/ssh/sshd_config.d/*; do
  [ -e "$f" ] || continue
  case "$f" in
    *.bak*.conf|*.orig*.conf|*.old*.conf|*.bak.conf)
      bad "$(basename "$f") в sshd_config.d — это бэкап, но оканчивается на .conf и читается как конфиг" "раздел «Базовые принципы»" ;;
    *.conf) ;;
    *) info "$(basename "$f") в sshd_config.d — sshd его не читает (не *.conf), но бэкапам место в /root/config-bak" ;;
  esac
done

# ---------------------------------------------------------------- таймеры отката
h "Таймеры отката и временный sudo"
# без --all: только ожидающие срабатывания; отработавшие транзитные таймеры не в счёт
TIMERS=$(systemctl list-timers --no-legend --no-pager 2>/dev/null | grep -E 'ssh-rollback|ufw-rollback|sudo-temp-expire')
if [ -n "$TIMERS" ]; then
  while IFS= read -r t; do
    bad "взведён таймер: $(echo "$t" | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/) print $i}') — если проверка закончена, останови его, иначе он откатит изменения" "раздел 1, dead-man switch"
  done <<< "$TIMERS"
else
  ok "висящих таймеров отката нет"
fi
if [ -f /etc/sudoers.d/90-setup-temp ] && [ -z "$(echo "$TIMERS" | grep sudo-temp-expire)" ]; then
  bad "временный NOPASSWD (/etc/sudoers.d/90-setup-temp) остался без таймера снятия — снять руками" "раздел 1, NOPASSWD sudo"
fi

# ---------------------------------------------------------------- ufw и forwarding
h "UFW и forwarding"
if [ "$UFW_ACTIVE" = 1 ]; then
  ok "UFW активен"
  info "политики: $(ufw status verbose 2>/dev/null | awk -F': ' '/^Default:/{print $2}')"
else
  bad "UFW не активен (или не установлен)" "раздел 2"
fi
info "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"

# ---------------------------------------------------------------- docker
h "Docker"
if have docker && docker info >/dev/null 2>&1; then
  info "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), контейнеров запущено: $(docker ps -q | wc -l)"
  if grep -qs '"max-size"' /etc/docker/daemon.json; then
    ok "лог-ротация в daemon.json задана"
  else
    bad "нет лог-ротации в /etc/docker/daemon.json — json-логи растут без предела" "раздел 3"
  fi
  RESTARTING=$(docker ps --filter status=restarting --format '{{.Names}}' | paste -sd ' ')
  [ -n "$RESTARTING" ] && bad "контейнеры в Restarting-цикле: $RESTARTING (заброшенный образ после обновления Docker? см. watchtower)" "раздел 6"
  # Опубликованные на все адреса порты: Docker обходит UFW, поэтому «не разрешён в UFW» ≠ «закрыт»
  DU=$(iptables -S DOCKER-USER 2>/dev/null)
  PUB=$(docker ps --format '{{.Names}}|{{.Ports}}' | while IFS='|' read -r n ports; do
          echo "$ports" | tr ',' '\n' | grep -oE '(0\.0\.0\.0|\[::\]|::):[0-9]+(-[0-9]+)?->[0-9]+/(tcp|udp)' \
            | sed -E 's/^(0\.0\.0\.0|\[::\]|::)://' | awk -v n="$n" -F'->' '{split($2,a,"/"); print n"|"$1"|"a[2]}'
        done | sort -u)
  if [ -z "$PUB" ]; then
    ok "контейнеры не публикуют порты на все адреса"
  else
    # Порты, которые не должны торчать наружу без ограничения: панели и базы данных
    SENSITIVE=' 2053 51821 5432 3306 6379 27017 9000 9090 3000 8080 '
    while IFS='|' read -r n p proto; do
      if echo "$DU" | grep -qE -- "--(dport|ctorigdstport) $p( |$)"; then
        info "$n: $p/$proto — доступ ограничен правилами DOCKER-USER"
      elif ufw_allows "$p" "$proto"; then
        ok "$n: $p/$proto открыт всем и разрешён в UFW (осознанно)"
      elif [[ "$SENSITIVE" == *" $p "* ]]; then
        bad "$n: $p/$proto (панель/БД) доступен из интернета В ОБХОД UFW — в UFW не разрешён, в DOCKER-USER правил нет" "раздел 2, DOCKER-USER"
      else
        info "$n: $p/$proto открыт всем через Docker, UFW тут не участвует — для VPN-порта это нормально; если это не VPN, закрой через DOCKER-USER"
      fi
    done <<< "$PUB"
  fi
else
  info "Docker не установлен или не запущен"
fi

# ---------------------------------------------------------------- amneziawg: хост
h "AmneziaWG на хосте"
if lsmod | grep -q '^amneziawg'; then
  ok "kernel-модуль загружен, версия $(modinfo -F version amneziawg 2>/dev/null)"
elif modinfo amneziawg >/dev/null 2>&1; then
  info "kernel-модуль установлен ($(modinfo -F version amneziawg)), но не загружен"
else
  info "kernel-модуля amneziawg нет"
fi
if have dkms && dkms status 2>/dev/null | grep -qi amneziawg; then
  if dkms status 2>/dev/null | grep -i amneziawg | grep -q "$(uname -r).*installed"; then
    ok "DKMS: модуль собран под текущее ядро $(uname -r)"
  else
    bad "DKMS: модуля нет под текущее ядро $(uname -r) — после обновления ядра не пересобрался (заголовки?)" "раздел 4"
  fi
  dpkg-query -W -f='${Status}' "linux-headers-$(uname -r)" 2>/dev/null | grep -q 'install ok installed' \
    || bad "нет linux-headers-$(uname -r): DKMS не сможет пересобрать модуль" "раздел 4"
fi
if pgrep -x amneziawg-go >/dev/null; then
  info "работает userspace amneziawg-go (references/amneziawg-userspace.md)"
fi
if have awg; then
  AWGOUT=$(awg show all 2>&1)
  if echo "$AWGOUT" | grep -q 'invalid length'; then
    bad "awg show: «invalid length» — tools и модуль AmneziaWG разных поколений" "раздел 10, п. 16"
  fi
  for i in $(awg show interfaces 2>/dev/null); do
    D=$(awg show "$i" 2>/dev/null)
    PORT=$(echo "$D" | awk '/listening port:/{print $3}')
    PEERS=$(echo "$D" | grep -c '^peer:')
    if echo "$D" | grep -qE '^[[:space:]]*jc:'; then
      LVL="обфускация есть"
      echo "$D" | grep -qE '^[[:space:]]*i1:' && LVL="$LVL, I1 (1.5+)"
      ok "$i: порт $PORT, пиров $PEERS, $LVL"
    else
      bad "$i: нет jc/jmin — это обычный WireGuard без обфускации" "раздел 4"
    fi
    if [ -n "$PORT" ] && [ "$UFW_ACTIVE" = 1 ] && ! ufw_allows "$PORT" udp; then
      bad "$i: UDP $PORT не разрешён в UFW" "раздел 2"
    fi
  done
fi

# ---------------------------------------------------------------- wg-easy
h "wg-easy"
WGE=$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -i 'wg-easy' | head -1)
if [ -n "$WGE" ]; then
  N=${WGE%%|*}; IMG=${WGE#*|}
  VER=$(docker inspect "$N" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)
  info "контейнер $N, образ $IMG${VER:+, версия $VER}"
  ENV=$(docker inspect "$N" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
  if echo "$ENV" | grep -qE '^(PASSWORD_HASH|WG_HOST)='; then
    bad "это wg-easy v14 (PASSWORD_HASH/WG_HOST): образ v15 с этими переменными не стартует — обновление только миграцией, не pull" "раздел 4"
    UIPORT=$(echo "$ENV" | awk -F= '$1=="PORT"{print $2}')
  else
    UIPORT=51821
  fi
  echo "$ENV" | grep -q '^INIT_PASSWORD=' && bad "INIT_PASSWORD всё ещё в окружении контейнера — после первого старта убрать из compose" "раздел 4"
  WSHOW=$(docker exec "$N" awg show 2>/dev/null || docker exec "$N" wg show 2>/dev/null)
  if echo "$ENV" | grep -q '^EXPERIMENTAL_AWG=true'; then
    if echo "$WSHOW" | grep -qE '^[[:space:]]*jc:'; then
      ok "AmneziaWG активен (jc/jmin в awg show)"
    elif [ -n "$WSHOW" ]; then
      bad "EXPERIMENTAL_AWG=true, но в awg show нет jc — wg-easy откатился на обычный WireGuard (нет kernel-модуля?)" "раздел 4"
    else
      bad "awg/wg show внутри $N ничего не вернул — интерфейс не поднят?" "раздел 8"
    fi
  else
    info "EXPERIMENTAL_AWG не включён — это обычный WireGuard без обфускации"
  fi
  UIPUB=$(docker port "$N" 2>/dev/null | grep -E "^${UIPORT:-51821}/tcp" | grep -vE '127\.0\.0\.1' | awk '{print $3}' | head -1)
  if [ -n "$UIPUB" ]; then
    HP=${UIPUB##*:}
    if echo "$DU" | grep -qE -- "--(dport|ctorigdstport) $HP( |$)"; then
      info "веб-панель wg-easy на $UIPUB, доступ ограничен DOCKER-USER"
    else
      bad "веб-панель wg-easy опубликована на $UIPUB без ограничения DOCKER-USER — должна быть на 127.0.0.1 за nginx" "раздел 4, nginx"
    fi
  fi
else
  info "wg-easy не запущен"
fi

# ---------------------------------------------------------------- xray / 3x-ui
h "xray / 3x-ui"
FOUND=0
while IFS='|' read -r n img; do
  [ -n "$n" ] || continue
  FOUND=1
  info "контейнер $n, образ $img"
  if echo "$img" | grep -qi '3x-ui'; then
    if docker port "$n" 2>/dev/null | grep -qE '^2053/tcp'; then
      bad "$n: панель на дефолтном порту 2053 (в Docker-образе ещё и admin/admin по умолчанию)" "references/xray.md, 3x-ui"
    fi
  else
    MNT=$(docker inspect "$n" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null)
    CMD=$(docker inspect "$n" --format '{{join .Config.Cmd " "}}' 2>/dev/null)
    if echo "$MNT" | grep -qx '/etc/xray' && ! echo "$MNT" | grep -q '^/usr/local/etc/xray' && ! echo "$CMD" | grep -q '/etc/xray'; then
      bad "$n: конфиг смонтирован в /etc/xray, а образ читает /usr/local/etc/xray — xray работает без твоего конфига" "references/xray.md, Docker"
    fi
  fi
  WARN=$(docker logs --tail 500 "$n" 2>&1 | grep -iE 'deprecated|warning.*(reality|serverName|target|port)' \
         | sed -E 's/^[0-9/]+ [0-9:.]+ //' | sort -u | head -3)
  [ -n "$WARN" ] && echo "$WARN" | while IFS= read -r w; do info "лог $n: ${w:0:160}"; done
done < <(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -iE '3x-ui|xray')
[ "$FOUND" = 0 ] && info "xray / 3x-ui не запущены"

# ---------------------------------------------------------------- базовое (кратко)
h "База (подробно — diagnose.sh из new-vps-setup)"
UU_PKG=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)
UU_T=$(systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer 2>/dev/null | paste -sd ' ')
UU_C=$(grep -hs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades)
if [ "$UU_PKG" = "install ok installed" ] && [ "$UU_T" = "enabled enabled" ] && [ -n "$UU_C" ]; then
  ok "автообновления безопасности: пакет, таймеры и конфиг в порядке"
else
  bad "автообновления неполные: пакет='${UU_PKG:-нет}', таймеры='${UU_T}', конфиг='${UU_C:-нет}'" "раздел 1, Обновление"
fi
if have fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban: jail sshd активен"
else
  bad "fail2ban: jail sshd не активен" "раздел 1, fail2ban"
fi
if have nginx; then
  if nginx -t >/dev/null 2>&1; then ok "nginx -t: конфиг корректен"; else bad "nginx -t: ошибка в конфиге" "раздел 3"; fi
fi

# ---------------------------------------------------------------- итог
h "Итог"
if [ "${#TODO[@]}" -eq 0 ]; then
  echo "  Проблем не найдено."
else
  printf '%s\n' "${TODO[@]}" | sort | awk -F'|' '{printf "  %-34s %s\n", $1, $2}'
fi
printf '\nГотово. Скрипт ничего не менял.\n'
