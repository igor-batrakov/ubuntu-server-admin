# Сквозная проверка VPN с рабочей машины

`docker ps` = healthy, `awg show` с `jc:` и открытый порт не доказывают, что туннель работает:
они не могут показать «плохо». Доказательство — клиент, который реально ходит через сервер,
плюс снимок провода. Всё ниже запускается на рабочей машине с Docker (macOS/Linux), на сервере
ничего клиентского не ставится.

Критерии «работает»:
1. внешний IP через туннель = IP сервера;
2. на сервере у пира есть свежий хендшейк;
3. для AmneziaWG с I1 — на проводе видны пакеты с сигнатурой;
4. для Reality — TLS без ключа получает настоящий сертификат target'а;
5. панели открываются с доверенного адреса и закрыты с любого другого.

Тестовых клиентов после проверки удалить (в панели), их ключи с рабочей машины — тоже.

## AmneziaWG: клиент в контейнере

Образ wg-easy уже содержит `awg-quick` и `amneziawg-go` — это готовый клиент. Kernel-модуля
в VM Docker Desktop нет, поэтому `awg-quick` сам поднимет userspace-реализацию.

Конфиг клиента (`.conf` из панели) подготовить:
- убрать строку `DNS` — в контейнере нет `resolvconf`, `awg-quick up` упадёт;
- оставить в `Address` только IPv4 и `AllowedIPs = 0.0.0.0/0` — в Docker Desktop нет IPv6.

```bash
docker run --rm --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --dns 1.1.1.1 \
  -v "$PWD/awg0.conf:/etc/amnezia/amneziawg/awg0.conf:ro" \
  --entrypoint sh ghcr.io/wg-easy/wg-easy:15 -c '
    awg-quick up awg0 && sleep 2
    wget -qO- -T 10 http://ifconfig.me/ip; echo
    awg show awg0 | grep -E "latest handshake|transfer"'
```

- `--sysctl …src_valid_mark=1` обязателен: `awg-quick` ставит его сам, а в контейнере
  `/proc/sys` только для чтения — `Read-only file system`.
- `--dns 1.1.1.1` обязателен: с `AllowedIPs = 0.0.0.0/0` запросы к внутреннему DNS Docker
  уходят в туннель и теряются — хендшейк есть, а «внешний IP» пустой.
- В образе нет `curl` — `wget` из busybox.

### Клиент для AmneziaWG 3.x

В образе wg-easy v15.4 — `amneziawg-go`/`amneziawg-tools` **3.0**: ключей 3.1 (`RandomTrailers`,
`DisableCookies`) они не знают. Для проверки inbound'а 3.1 (например, встроенного в 3x-ui)
собрать свой клиентский образ из тех же тегов, что в Dockerfile wg-easy master:

```dockerfile
FROM alpine:3 AS build
RUN apk add --no-cache linux-headers build-base go git bash && \
    git clone --depth 1 --branch v3.1.20260812 https://github.com/amnezia-vpn/amneziawg-tools.git && \
    git clone --depth 1 --branch v3.1.20260828 https://github.com/amnezia-vpn/amneziawg-go && \
    cd amneziawg-go && make && cd ../amneziawg-tools/src && make
FROM alpine:3
RUN apk add --no-cache bash iproute2 iptables ip6tables wget
COPY --from=build /amneziawg-go/amneziawg-go /usr/bin/amneziawg-go
COPY --from=build /amneziawg-tools/src/wg /usr/bin/awg
COPY --from=build /amneziawg-tools/src/wg-quick/linux.bash /usr/bin/awg-quick
ENTRYPOINT ["sh"]
```
Запуск — как выше (`--cap-add NET_ADMIN --device /dev/net/tun --sysctl …src_valid_mark=1 --dns 1.1.1.1`).
Теги сверять с актуальными релизами.

### Снимок провода: видна ли сигнатура I1

На сервере, **до** запуска клиента:
```bash
sudo systemd-run --unit=awgcap --collect timeout 60 \
  tcpdump -ni any -c 200 'udp dst port <WG_PORT>' -Z root -w /root/awgtest.pcap
```
После клиента:
```bash
sudo systemctl stop awgcap
sudo tcpdump -nr /root/awgtest.pcap | wc -l                                  # все входящие
sudo tcpdump -nr /root/awgtest.pcap 'udp[8:4]=0xc7000000 and udp[12]=0x01' | wc -l   # с I1
```
Фильтр — для I1 вида `<b 0xc700000001>…` (первые 5 байт полезной нагрузки); под свою сигнатуру
подставить свои байты.

- `tcpdump … &` в `ssh '…'` умирает вместе с сессией (SIGHUP) — отсюда `systemd-run`.
- `-Z root` и файл в `/root`: tcpdump сбрасывает права до пользователя `tcpdump` и не может
  перезаписать файл в sticky-каталоге `/var/tmp` (`Permission denied` в `journalctl -u awgcap`).
- `pkill -f 'tcpdump …'` в той же ssh-команде убивает саму ssh-команду: шаблон совпадает с её
  собственной командной строкой.

## xray: клиент в контейнере

Клиент — официальный `ghcr.io/xtls/xray-core:latest` с SOCKS-входом. Версия клиента должна быть
не ниже минимальной версии Reality сервера (по умолчанию 26.3.27).

`raw.json` (для XHTTP: `"network": "xhttp"`, `xhttpSettings.path`, без `flow`):
```json
{
  "inbounds": [{"listen": "0.0.0.0", "port": 10808, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{"protocol": "vless",
    "settings": {"vnext": [{"address": "<SERVER_IP>", "port": 443,
      "users": [{"id": "<UUID>", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"serverName": "<TARGET>", "fingerprint": "chrome",
        "password": "<PUBLIC_KEY>", "shortId": "<SHORT_ID>", "spiderX": "/"}}}]
}
```
```bash
docker run -d --name xt -p 127.0.0.1:18081:10808 -v "$PWD/raw.json:/etc/xray/c.json:ro" \
  ghcr.io/xtls/xray-core:latest run -config /etc/xray/c.json
curl -s -m 15 --socks5-hostname 127.0.0.1:18081 https://ifconfig.me/ip    # = IP сервера
docker rm -f xt
```

Маскировка — обычный TLS без ключа Reality должен получить сертификат target'а:
```bash
openssl s_client -connect <SERVER_IP>:443 -servername <TARGET> </dev/null 2>/dev/null | grep ^subject=
```

## Панели: закрыты для чужих

С доверенного адреса — `curl` на порт панели отвечает. С любого другого сервера (не из списка):
```bash
for p in 443 2083 <PANEL_PORT> <UI_PORT>; do
  timeout 5 bash -c "echo > /dev/tcp/<SERVER_IP>/$p" 2>/dev/null && echo "$p открыт" || echo "$p закрыт"
done
```
VPN-порты должны быть открыты, панели — закрыты. Если с чужого сервера закрыто всё — проверка
ничего не доказывает (сервер недоступен целиком), нужен другой источник.

## После перезагрузки

Повторить всё выше после `reboot`: модуль AmneziaWG грузится сам (`/etc/modules-load.d`),
контейнеры поднимаются, правила DOCKER-USER восстанавливаются юнитом, параметры обфускации
на месте. Упавшие юниты — `systemctl --failed`.
