# Обновление релиза Ubuntu (LTS → LTS)

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
