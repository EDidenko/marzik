#!/usr/bin/env bash
# Шаг: автообновление. Два режима — выбери один.
#   bash 04-autoupdate.sh cron        # рекомендуется: раз в неделю, штатной командой marzban update
#   bash 04-autoupdate.sh watchtower  # ежедневно в 05:00, обновляет только контейнер Marzban
set -euo pipefail
MODE="${1:-cron}"
[[ $EUID -eq 0 ]] || { echo "Запускать от root"; exit 1; }

case "$MODE" in
cron)
  cat >/etc/cron.d/marzban-update <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# воскресенье 05:00 по времени сервера
0 5 * * 0 root /usr/local/bin/marzban update -n >>/var/log/marzban-update.log 2>&1
EOF
  chmod 644 /etc/cron.d/marzban-update
  echo "Готово: /etc/cron.d/marzban-update (лог — /var/log/marzban-update.log)"
  ;;
watchtower)
  CNAME="$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"
  [[ -n "$CNAME" ]] || { echo "!! Контейнер Marzban не найден"; exit 1; }
  mkdir -p /opt/watchtower
  cat >/opt/watchtower/docker-compose.yml <<EOF
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --include-restarting --schedule "0 0 5 * * *" ${CNAME}
EOF
  docker compose -f /opt/watchtower/docker-compose.yml up -d
  echo "Готово: Watchtower следит только за ${CNAME}, проверка в 05:00 UTC."
  echo "Логи: docker logs -f watchtower"
  ;;
*) echo "Использование: $0 [cron|watchtower]"; exit 1;;
esac
