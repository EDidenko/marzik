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
# Для A/B — переопределения одного параметра за раз, поверх того, что отдала панель:
#   SID_OVERRIDE=<hex>   SNI_OVERRIDE=<домен>   PORT_OVERRIDE=<порт>
# Например, проверить порт 443 с заведомо верным sid, когда панель отдаёт пустой:
#   sudo SID_OVERRIDE=d2f4... bash 08-selftest.sh iPhone
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

fetch_link(){
  curl -sf "${API}/api/user/${USERNAME}" -H "Authorization: Bearer ${TOKEN}" \
    | jq -r ".links[${LINK_INDEX}] // empty"
}
LINK="$(fetch_link)"
[[ -n "$LINK" ]] || { echo "!! Нет ссылки #${LINK_INDEX} у ${USERNAME}"; exit 1; }

# Сразу после `marzban restart` панель какое-то время отдаёт ссылку БЕЗ sid, хотя в
# конфиге он есть. Это гонка перечитывания конфига, а не поломка: без ожидания тест
# померит заведомо нерабочую ссылку и обвинит сервер.
CFG_SID="$(jq -r '[.inbounds[]?.streamSettings?.realitySettings?.shortIds[0]? // empty][0] // empty' \
  "${SHARED}/xray_config.json" 2>/dev/null || true)"
if [[ -n "$CFG_SID" ]]; then
  for _ in 1 2 3 4 5; do
    grep -q "sid=${CFG_SID}" <<<"$LINK" && break
    echo "    панель ещё отдаёт ссылку без sid (бывает сразу после restart) — жду 3с"
    sleep 3
    LINK="$(fetch_link)"
  done
fi

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

# Переопределения для A/B: позволяют менять ОДНУ переменную за раз, когда панель
# отдаёт битую ссылку. Форма ${VAR-...} (без двоеточия) намеренная — так можно
# задать заведомо пустое значение, например SID_OVERRIDE= для проверки без sid.
OVR=""
[[ -n "${SNI_OVERRIDE:-}"  ]] && { SNI="$SNI_OVERRIDE";   OVR+=" sni"; }
[[ -n "${PORT_OVERRIDE:-}" ]] && { RPORT="$PORT_OVERRIDE"; OVR+=" port"; }
if [[ -n "${SID_OVERRIDE+x}" ]]; then SID="$SID_OVERRIDE"; OVR+=" sid"; fi
[[ -z "$OVR" ]] || echo "    (переопределено:${OVR})"

echo "==> Тестирую ровно то, что отдаётся клиенту"
printf '    %s:%s  sni=%s  fp=%s  flow=%s  sid=%s\n' \
  "$RHOST" "$RPORT" "$SNI" "$FP" "${FLOW:-<нет>}" "${SID:-<ПУСТО>}"
[[ -n "$PBK" && -n "$SNI" ]] || { echo "!! В ссылке нет pbk/sni — сначала чини панель"; exit 1; }
if [[ -z "$SID" ]]; then
  echo "!! В ссылке пустой sid, а в конфиге shortIds непустой -> сервер такого клиента отвергнет."
  echo "!! Сверь:  jq '.inbounds[].streamSettings.realitySettings.shortIds' ${SHARED}/xray_config.json"
fi

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
  echo
  echo "--- лог клиента (${TESTC}) — здесь видно, на чём именно оборвалось ---"
  docker logs "$TESTC" 2>&1 | tail -30
  echo
  echo "--- лог сервера (хвост Marzban/Xray) ---"
  marzban logs -n 2>/dev/null | grep -viE 'GET /api/(system|admin)' | tail -30
  echo
  echo "Пусто с обеих сторон -> подключение до Xray вообще не доходит."
  echo "Есть 'REALITY' / 'invalid' -> клиент не опознан (sid/pbk/sni)."
  echo "Подробный лог ядра:  sudo bash $(dirname "$0")/07-debug-log.sh on"
  exit 1
fi
echo "РЕЗУЛЬТАТ: туннель РАБОТАЕТ. Внешний IP через туннель: ${OUT}"
[[ "$OUT" == "$DIRECT" ]] && echo "  (совпадает с IP сервера ${DIRECT} — так и должно быть)"
echo
echo "Значит сервер исправен целиком: Reality, ключи, flow, исходящая связность."
echo "Остаётся клиент — переимпортируй ссылку в приложении и проверь, что оно"
echo "не режет трафик своими правилами роутинга."
