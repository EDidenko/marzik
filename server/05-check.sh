#!/usr/bin/env bash
# Шаг 6: диагностика. Запуск:  bash 05-check.sh
set -uo pipefail
VLESS_PORT="${VLESS_PORT:-443}"
PANEL_PORT="${PANEL_PORT:-8000}"

hr(){ printf '\n--- %s ---\n' "$1"; }

hr "Контейнеры"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

hr "Слушающие порты"
ss -lntp | grep -E "[:.](${VLESS_PORT}|${PANEL_PORT})\b" || echo "порты НЕ слушаются — смотри логи"

hr "UFW"
ufw status verbose

hr "Последние 40 строк логов Marzban/Xray"
marzban logs 2>/dev/null | tail -40 || docker logs --tail 40 "$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"

hr "Валидность xray_config.json"
jq -e . /var/lib/marzban/xray_config.json >/dev/null && echo "JSON ok" || echo "JSON СЛОМАН"

hr "Reality dest доступен с сервера (TLS1.3 + H2)?"
DEST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /var/lib/marzban/xray_config.json)
curl -sI --tlsv1.3 --tls-max 1.3 --http2 -m 10 "https://${DEST}/" | head -1 || echo "dest ${DEST} НЕДОСТУПЕН — смени SNI"

hr "Порт ${VLESS_PORT} снаружи (маскировка под ${DEST})"
IP=$(curl -s -4 https://ifconfig.me)
echo "IP сервера: ${IP}"
timeout 10 openssl s_client -connect "${IP}:${VLESS_PORT}" -servername "${DEST}" </dev/null 2>/dev/null \
  | grep -E 'subject=|TLSv1.3|Verify return code' | head -5
echo "^ должен показать сертификат ${DEST} — значит Reality корректно маскируется"

hr "Параметры Reality"
find /root /home -maxdepth 3 -name reality.txt -path '*/marzban/*' 2>/dev/null \
  | head -1 | xargs -r cat || echo "reality.txt не найден"
