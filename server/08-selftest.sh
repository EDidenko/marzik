#!/usr/bin/env bash
# Сквозной self-test. Поднимает ВРЕМЕННЫЙ xray-клиент прямо на сервере и ходит через
# собственный Reality-инбаунд наружу — ровно по той ссылке, которую панель отдаёт юзеру.
#
# Это единственная проверка, которая отделяет сервер от клиентского устройства:
#   прошла  -> сервер исправен на всю глубину, чинить надо приложение на телефоне;
#   не прошла -> проблема на сервере, и в логе будет видно, на каком шаге.
#
#   sudo bash 08-selftest.sh [username]
# Переменные: ADMIN_USER, ADMIN_PASS, PANEL_PORT=8000, SOCKS_PORT=10808, LINK_INDEX=0
#
# Клиент запускается ВНУТРИ контейнера Marzban — тем же бинарником xray той же версии,
# что и сервер, поэтому расхождения версий тест не исказят и образ качать не нужно.
set -euo pipefail

USERNAME="${1:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
LINK_INDEX="${LINK_INDEX:-0}"
API="http://127.0.0.1:${PANEL_PORT}"
SHARED=/var/lib/marzban            # бинд-маунт: виден и хосту, и контейнеру
CFG="${SHARED}/selftest-client.json"

[[ $EUID -eq 0 ]] || { echo "Запускать от root (или через sudo)"; exit 1; }
[[ -n "$USERNAME" ]] || { echo "Использование: $0 <username>"; exit 1; }
command -v jq >/dev/null || apt-get -y -qq install jq

CNAME="$(docker ps --format '{{.Names}}' | grep -i marzban | head -1)"
[[ -n "$CNAME" ]] || { echo "!! Контейнер Marzban не найден"; exit 1; }
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CNAME")"
TESTC=marzik-selftest

cleanup(){ docker rm -f "$TESTC" >/dev/null 2>&1 || true; rm -f "$CFG"; }
trap cleanup EXIT
docker rm -f "$TESTC" >/dev/null 2>&1 || true

ADMIN_USER="${ADMIN_USER:-}"; ADMIN_PASS="${ADMIN_PASS:-}"
[[ -n "$ADMIN_USER" ]] || read -rp  "Admin login: "    ADMIN_USER
[[ -n "$ADMIN_PASS" ]] || { read -rsp "Admin password: " ADMIN_PASS; echo; }

TOKEN="$(curl -sf -X POST "${API}/api/admin/token" \
  -d "grant_type=password" -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" \
  | jq -r '.access_token' || true)"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "!! Не авторизовался в панели"; exit 1; }

LINK="$(curl -sf "${API}/api/user/${USERNAME}" -H "Authorization: Bearer ${TOKEN}" \
  | jq -r ".links[${LINK_INDEX}] // empty")"
[[ -n "$LINK" ]] || { echo "!! Нет ссылки #${LINK_INDEX} у ${USERNAME}"; exit 1; }

# --- разбор vless://UUID@HOST:PORT?params#remark ---------------------------------
BODY="${LINK#vless://}"; BODY="${BODY%%#*}"
UUID="${BODY%%@*}"
REST="${BODY#*@}"
HOSTPORT="${REST%%\?*}"
QUERY="${REST#*\?}"
RHOST="${HOSTPORT%%:*}"; RPORT="${HOSTPORT##*:}"
getp(){ tr '&' '\n' <<<"$QUERY" | sed -n "s/^$1=//p" | head -1; }
SNI="$(getp sni)"; PBK="$(getp pbk)"; SID="$(getp sid)"
FP="$(getp fp)"; FLOW="$(getp flow)"
: "${FP:=chrome}"

echo "==> Тестирую ровно то, что отдаётся клиенту"
printf '    %s:%s  sni=%s  fp=%s  flow=%s  sid=%s\n' "$RHOST" "$RPORT" "$SNI" "$FP" "${FLOW:-<нет>}" "$SID"
[[ -n "$PBK" && -n "$SNI" ]] || { echo "!! В ссылке нет pbk/sni — сначала чини панель"; exit 1; }

jq -n --arg uuid "$UUID" --arg host "$RHOST" --argjson port "$RPORT" \
      --arg sni "$SNI" --arg pbk "$PBK" --arg sid "$SID" --arg fp "$FP" \
      --arg flow "$FLOW" --argjson socks "$SOCKS_PORT" '
{ log: { loglevel: "warning" },
  inbounds: [ { tag:"socks", listen:"127.0.0.1", port:$socks,
                protocol:"socks", settings:{ udp:false } } ],
  outbounds: [ { tag:"proxy", protocol:"vless",
      settings: { vnext: [ { address:$host, port:$port, users: [
          ( { id:$uuid, encryption:"none" }
            + (if $flow == "" then {} else { flow:$flow } end) ) ] } ] },
      streamSettings: { network:"tcp", security:"reality",
        realitySettings: { serverName:$sni, fingerprint:$fp,
                           publicKey:$pbk, shortId:$sid } } } ] }' >"$CFG"
chmod 600 "$CFG"

echo "==> Запускаю временный xray-клиент (образ ${IMAGE}, socks 127.0.0.1:${SOCKS_PORT})"
# Отдельный контейнер, а не `docker exec -d` в Marzban: так процессом можно управлять
# снаружи (`docker rm -f`) и читать его лог, не полагаясь на pgrep/pkill — в образе
# Marzban пакета procps нет, и проверка «поднялся ли клиент» через pgrep всегда врёт.
docker run -d --name "$TESTC" --network host \
  -v "${SHARED}:${SHARED}:ro" --entrypoint sh \
  "$IMAGE" -c "exec xray -c ${CFG}" >/dev/null

# Контейнер в host-сети, поэтому socks-порт виден с хоста обычным ss.
for _ in $(seq 1 10); do
  ss -lntH "sport = :${SOCKS_PORT}" 2>/dev/null | grep -q . && break
  sleep 1
done
if ! ss -lntH "sport = :${SOCKS_PORT}" 2>/dev/null | grep -q .; then
  echo "!! Клиент не поднялся: порт ${SOCKS_PORT} не слушает. Лог контейнера:"
  docker logs "$TESTC" 2>&1 | tail -20
  exit 1
fi

echo "==> Иду наружу через туннель"
OUT="$(curl -s --socks5-hostname "127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 -m 20 \
        https://ifconfig.me || true)"
DIRECT="$(curl -s -4 --connect-timeout 5 -m 10 https://ifconfig.me || true)"

echo
if [[ -z "$OUT" ]]; then
  echo "РЕЗУЛЬТАТ: трафик через туннель НЕ ИДЁТ."
  echo "  Телефон ни при чём — проблема на сервере."
  echo "  Включи подробный лог и повтори этот же тест:"
  echo "    sudo bash 07-debug-log.sh on && sudo bash $0 ${USERNAME}"
  exit 1
fi
echo "РЕЗУЛЬТАТ: туннель РАБОТАЕТ. Внешний IP через туннель: ${OUT}"
[[ "$OUT" == "$DIRECT" ]] && echo "  (совпадает с IP сервера ${DIRECT} — так и должно быть)"
echo
echo "Значит сервер исправен целиком: Reality, ключи, flow, исходящая связность."
echo "Остаётся клиент — переимпортируй ссылку в приложении и проверь, что оно"
echo "не режет трафик своими правилами роутинга."
