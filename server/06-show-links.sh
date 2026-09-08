#!/usr/bin/env bash
# Диагностика клиентской стороны: что панель РЕАЛЬНО отдаёт в ссылке.
# Сервер может быть настроен идеально, но если в Host не задан fingerprint или sni,
# клиент подключится «в никуда»: TLS встанет, трафик не пойдёт.
#
# Запуск:  bash 06-show-links.sh [username]
# Переменные: ADMIN_USER, ADMIN_PASS (спросит, если не заданы), PANEL_PORT=8000
#
# UUID в выводе маскируется — результат можно копировать в переписку как есть.
set -euo pipefail

USERNAME="${1:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
API="http://127.0.0.1:${PANEL_PORT}"

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
command -v jq >/dev/null || $SUDO apt-get -y -qq install jq

ADMIN_USER="${ADMIN_USER:-}"; ADMIN_PASS="${ADMIN_PASS:-}"
[[ -n "$ADMIN_USER" ]] || read -rp  "Admin login: "    ADMIN_USER
[[ -n "$ADMIN_PASS" ]] || { read -rsp "Admin password: " ADMIN_PASS; echo; }

TOKEN="$(curl -sf -X POST "${API}/api/admin/token" \
  -d "grant_type=password" -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" \
  | jq -r '.access_token' || true)"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "!! Не авторизовался в панели"; exit 1; }
auth=(-H "Authorization: Bearer ${TOKEN}")

hr(){ printf '\n--- %s ---\n' "$1"; }

hr "Инбаунды, которые видит панель"
curl -sf "${API}/api/inbounds" "${auth[@]}" | jq -r '.vless[]? | "\(.tag)  port=\(.port)  network=\(.network)  tls=\(.tls)"'

hr "Hosts (address / sni / fingerprint / alpn)"
# Пустое поле здесь НЕ означает «параметра не будет в ссылке»: Marzban наследует
# sni/fp из инбаунда. Судить можно только по итоговой ссылке в конце вывода.
HOSTS="$(curl -sf "${API}/api/hosts" "${auth[@]}")"
if [[ "$(jq -r 'to_entries | map(.value | length) | add // 0' <<<"$HOSTS")" == "0" ]]; then
  echo "Hosts не заданы ни для одного инбаунда."
  echo "-> Панель -> Hosts -> у инбаунда задай Address = IP сервера и Fingerprint = chrome"
else
  jq -r 'def val: if (. // "") == "" then "(наследуется из инбаунда)" else . end;
         to_entries[] | .key as $tag | .value[]
         | "\($tag):\n  remark : \(.remark)\n  address: \(.address)\n  port   : \(.port // "(из инбаунда)")\n  sni    : \(.sni | val)\n  host   : \(.host // "")\n  fp     : \(.fingerprint | val)\n  alpn   : \(.alpn // "")"' <<<"$HOSTS"
fi

hr "Пользователи"
if [[ -z "$USERNAME" ]]; then
  curl -sf "${API}/api/users" "${auth[@]}" | jq -r '.users[]? | "\(.username)  \(.status)"'
  echo
  echo "Ссылки конкретного юзера:  bash $0 <username>"
  exit 0
fi

USER_JSON="$(curl -sf "${API}/api/user/${USERNAME}" "${auth[@]}" || true)"
[[ -n "$USER_JSON" ]] || { echo "!! Пользователь ${USERNAME} не найден"; exit 1; }

echo "status : $(jq -r '.status' <<<"$USER_JSON")"
echo "flow   : $(jq -r '.proxies.vless.flow // "ПУСТО"' <<<"$USER_JSON")"
echo "inbound: $(jq -rc '.inbounds.vless // []' <<<"$USER_JSON")"

hr "Ссылки (UUID замаскирован)"
COUNT="$(jq -r '(.links // []) | length' <<<"$USER_JSON")"
if [[ "$COUNT" == "0" ]]; then
  echo "!! Ссылок нет. Обычно значит, что теги в inbounds юзера не совпадают"
  echo "!! с тегами в /var/lib/marzban/xray_config.json (см. секцию выше)."
  exit 1
fi

while IFS= read -r L; do
  MASKED="$(sed -E 's|(vless://)[0-9a-fA-F-]{36}|\1<UUID>|' <<<"$L")"
  echo
  echo "$MASKED"
  # разбираем query-параметры построчно: так сразу видно, чего не хватает
  Q="${L#*\?}"; Q="${Q%%#*}"
  tr '&' '\n' <<<"$Q" | sed 's/^/    /'
done < <(jq -r '.links[]' <<<"$USER_JSON")

echo
echo "Обязательно должны присутствовать: security=reality, pbk=, sid=, sni=,"
echo "fp=chrome, flow=xtls-rprx-vision, type=tcp. Сверь pbk/sid с ~/marzban/reality.txt."
