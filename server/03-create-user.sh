#!/usr/bin/env bash
# Шаг 4: создание пользователя через REST API Marzban + vless:// ссылка + QR в терминале.
# Запуск:  bash 03-create-user.sh <username>
# Переменные: ADMIN_USER, ADMIN_PASS (спросит, если не заданы), PANEL_PORT=8000
set -euo pipefail

USERNAME="${1:-vn-phone}"
PANEL_PORT="${PANEL_PORT:-8000}"
API="http://127.0.0.1:${PANEL_PORT}"


# Секреты кладём в домашку того, кто вызвал sudo, а не в /root — иначе под deploy
# их не прочитать без sudo. Переопределить: OUT_DIR=/path bash <скрипт>
if [[ -z "${OUT_DIR:-}" ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    OUT_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/marzban"
    OUT_OWNER="$SUDO_USER"
  else
    OUT_DIR="/root/marzban"
    OUT_OWNER="root"
  fi
fi
OUT_OWNER="${OUT_OWNER:-root}"
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
if [[ $EUID -eq 0 ]]; then chown "$OUT_OWNER":"$(id -gn "$OUT_OWNER")" "$OUT_DIR"; fi

# Скрипту root не нужен — он ходит в API. Но доставить пакеты можно только через sudo.
SUDO=""; if [[ $EUID -ne 0 ]]; then SUDO="sudo"; fi
command -v jq       >/dev/null || $SUDO apt-get -y -qq install jq
command -v qrencode >/dev/null || $SUDO apt-get -y -qq install qrencode

ADMIN_USER="${ADMIN_USER:-}"; ADMIN_PASS="${ADMIN_PASS:-}"
[[ -n "$ADMIN_USER" ]] || read -rp  "Admin login: "    ADMIN_USER
[[ -n "$ADMIN_PASS" ]] || { read -rsp "Admin password: " ADMIN_PASS; echo; }

echo "==> Получаю токен"
TOKEN="$(curl -sf -X POST "${API}/api/admin/token" \
  -d "grant_type=password" -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" \
  | jq -r '.access_token' || true)"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "!! Не авторизовался. Создай админа: marzban cli admin create --sudo"; exit 1; }

echo "==> Доступные inbound-теги"
curl -sf "${API}/api/inbounds" -H "Authorization: Bearer ${TOKEN}" | jq -r '.vless[]?.tag' || true

echo "==> Создаю пользователя ${USERNAME}"
PAYLOAD=$(jq -n --arg u "$USERNAME" '{
  username: $u,
  status: "active",
  expire: 0,
  data_limit: 0,
  data_limit_reset_strategy: "no_reset",
  proxies: { vless: { flow: "xtls-rprx-vision" } },
  inbounds: { vless: ["VLESS TCP REALITY", "VLESS TCP REALITY BACKUP"] },
  note: "created by 03-create-user.sh"
}')

RESP="$(curl -s -X POST "${API}/api/user" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$PAYLOAD")"

if echo "$RESP" | jq -e '.detail' >/dev/null 2>&1; then
  echo "   Ответ API: $(echo "$RESP" | jq -c '.detail')"
  echo "   Пробую забрать существующего пользователя..."
  RESP="$(curl -sf "${API}/api/user/${USERNAME}" -H "Authorization: Bearer ${TOKEN}" || true)"
fi

SUB="$(echo "$RESP" | jq -r '.subscription_url // empty')"
mapfile -t LINKS < <(echo "$RESP" | jq -r '.links[]?')

[[ ${#LINKS[@]} -gt 0 ]] || { echo "!! Ссылок нет. Проверь inbound-теги в xray_config.json:"; echo "$RESP" | jq .; exit 1; }

echo
echo "=================== ССЫЛКИ ==================="
for L in "${LINKS[@]}"; do echo; echo "$L"; done
echo
echo "Подписка (обновляется автоматически): ${API}${SUB}"
echo "  Снаружи замени 127.0.0.1 на IP сервера и укажи его в XRAY_SUBSCRIPTION_URL_PREFIX."
echo "=============================================="
echo
echo "QR основной ссылки (сканируй камерой из v2rayNG / Streisand):"
qrencode -t ANSIUTF8 -m 1 "${LINKS[0]}"

printf '%s\n' "${LINKS[@]}" >"${OUT_DIR}/${USERNAME}-links.txt"
qrencode -o "${OUT_DIR}/${USERNAME}-qr.png" -s 8 "${LINKS[0]}"
chmod 600 "${OUT_DIR}/${USERNAME}-links.txt" "${OUT_DIR}/${USERNAME}-qr.png"
if [[ $EUID -eq 0 ]]; then chown "$OUT_OWNER" "${OUT_DIR}/${USERNAME}-links.txt" "${OUT_DIR}/${USERNAME}-qr.png"; fi
echo
echo "Сохранено: ${OUT_DIR}/${USERNAME}-links.txt и ${OUT_DIR}/${USERNAME}-qr.png"
echo "Забрать PNG на ноут:  scp <user>@<IP>:${OUT_DIR}/${USERNAME}-qr.png ."
