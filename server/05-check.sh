#!/usr/bin/env bash
# Шаг 6: диагностика. Запуск:  bash 05-check.sh
set -uo pipefail
VLESS_PORT="${VLESS_PORT:-443}"
VLESS_PORT_ALT="${VLESS_PORT_ALT:-8443}"
PANEL_PORT="${PANEL_PORT:-8000}"

hr(){ printf '\n--- %s ---\n' "$1"; }

hr "Контейнеры"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

hr "Слушающие порты"
# Сравниваем именно последнее поле адреса, иначе grep по '443' ловит и 8443, и наоборот.
ss -lntpH | awk -v re="^(${VLESS_PORT}|${VLESS_PORT_ALT}|${PANEL_PORT})$" \
  '{n=split($4,a,":"); if (a[n] ~ re) {print; found=1}} END{if(!found) print "порты НЕ слушаются — смотри логи"}'

hr "UFW"
ufw status verbose

hr "Последние 40 строк логов Marzban/Xray"
# -n обязателен: без него `marzban logs` следует за выводом и скрипт зависает.
marzban logs -n 2>/dev/null | tail -40 \
  || docker logs --tail 40 "$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"

hr "Версия ядра Xray"
CNAME0="$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"
XV="$(docker exec "$CNAME0" xray version 2>/dev/null | awk 'NR==1{print $2}')"
echo "  ${XV:-неизвестна}"
case "$XV" in
  1.*|2[0-4].*)
    echo "  !! Ядро старое. Клиенты 2025+ с fp=chrome предлагают в ClientHello постквантовый"
    echo "  !! X25519MLKEM768, которого это ядро не понимает: Reality-хендшейк падает, хотя"
    echo "  !! сервер полностью исправен и self-test старым клиентом проходит."
    echo "  !! Лечится:  sudo marzban core-update && sudo marzban restart -n" ;;
esac

hr "Валидность xray_config.json"
jq -e . /var/lib/marzban/xray_config.json >/dev/null && echo "JSON ok" || echo "JSON СЛОМАН"

hr "Reality dest доступен с сервера (TLS1.3 + H2)?"
DEST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /var/lib/marzban/xray_config.json)
curl -sI --tlsv1.3 --tls-max 1.3 --http2 --connect-timeout 5 -m 10 "https://${DEST}/" | head -1 \
  || echo "dest ${DEST} НЕДОСТУПЕН по TLS1.3/H2 — смени SNI"

hr "Порт ${VLESS_PORT} снаружи (маскировка под ${DEST})"
IP=$(curl -s -4 --connect-timeout 5 -m 10 https://ifconfig.me)
echo "IP сервера: ${IP}"
timeout 10 openssl s_client -connect "${IP}:${VLESS_PORT}" -servername "${DEST}" </dev/null 2>/dev/null \
  | grep -E 'subject=|TLSv1.3|Verify return code' | head -5
echo "^ должен показать сертификат ${DEST} — значит Reality корректно маскируется"

hr "Исходящая связность (то, чем xray ходит в интернет)"
# Если хендшейк проходит, а трафика нет, ломается обычно здесь. Два классических случая:
# на VPS есть адрес IPv6 без рабочего маршрута, и не резолвится DNS внутри контейнера —
# при sniffing + destOverride это убивает вообще весь пользовательский трафик.
printf 'хост IPv4  : '; curl -s -4 --connect-timeout 5 -m 8 -o /dev/null -w '%{http_code}\n' \
  https://www.google.com || echo "FAIL — у сервера нет исхода в интернет"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  printf 'хост IPv6  : '; curl -s -6 --connect-timeout 5 -m 8 -o /dev/null -w '%{http_code}\n' \
    https://www.google.com \
    || echo "адрес есть, но НЕ РАБОТАЕТ -> добавь freedom domainStrategy=UseIPv4"
else
  echo "хост IPv6  : адреса нет (нормально)"
fi
CNAME="$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"
# Спрашиваем A и AAAA по отдельности: `getent hosts` пробует AF_INET6 первым и при
# наличии AAAA печатает ТОЛЬКО их, из-за чего кажется, будто A-записей нет.
A4="$(docker exec "$CNAME" getent ahostsv4 www.google.com 2>/dev/null | awk 'NR==1{print $1}')"
A6="$(docker exec "$CNAME" getent ahostsv6 www.google.com 2>/dev/null | awk 'NR==1{print $1}')"
echo "DNS в контейнере: A=${A4:-НЕТ}  AAAA=${A6:-нет}"
[[ -n "$A4" ]] || echo "  !! A-записи не резолвятся — при sniffing+destOverride это ломает весь трафик"

STRAT="$(jq -r '[.outbounds[]? | select(.protocol=="freedom") | .settings.domainStrategy // "AsIs"][0] // "AsIs"' \
  /var/lib/marzban/xray_config.json 2>/dev/null)"
echo "freedom domainStrategy: ${STRAT}"
if [[ -z "${A6:-}" ]]; then :; elif ! ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  [[ "$STRAT" == UseIPv4 ]] \
    || echo "  !! У сервера нет IPv6, но домены резолвятся в AAAA, а strategy=${STRAT}." \
            "Перегони 02-install-marzban.sh — он выставит UseIPv4."
fi

hr "Параметры Reality"
find /root /home -maxdepth 3 -name reality.txt -path '*/marzban/*' 2>/dev/null \
  | head -1 | xargs -r cat || echo "reality.txt не найден"
