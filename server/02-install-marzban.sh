#!/usr/bin/env bash
# Шаг 2+3: установка Marzban (Docker Compose) и настройка VLESS + Reality.
# Запуск:  bash 02-install-marzban.sh
# Переменные:
#   REALITY_DEST=www.microsoft.com  VLESS_PORT=443  VLESS_PORT_ALT=8443  PANEL_PORT=8000
set -euo pipefail

REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
VLESS_PORT="${VLESS_PORT:-443}"
VLESS_PORT_ALT="${VLESS_PORT_ALT:-8443}"
PANEL_PORT="${PANEL_PORT:-8000}"
COMPOSE=/opt/marzban/docker-compose.yml
ENVFILE=/opt/marzban/.env
XRAYJSON=/var/lib/marzban/xray_config.json

[[ $EUID -eq 0 ]] || { echo "Запускать от root (или через sudo)"; exit 1; }

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
install -d -m 700 -o "$OUT_OWNER" -g "$(id -gn "$OUT_OWNER")" "$OUT_DIR"

echo "==> Проверка, что порт ${VLESS_PORT} свободен"
if ss -lntH "sport = :${VLESS_PORT}" | grep -q .; then
  echo "!! Порт ${VLESS_PORT} занят:"; ss -lntp "sport = :${VLESS_PORT}"
  echo "!! Останови сервис (nginx/apache/caddy) или запусти с VLESS_PORT=8443"; exit 1
fi

echo "==> Проверка dest: ${REALITY_DEST} должен отдавать TLS 1.3 + HTTP/2"
if ! curl -sI --tlsv1.3 --tls-max 1.3 --http2 -m 10 -o /dev/null "https://${REALITY_DEST}/"; then
  echo "!! ${REALITY_DEST} не отвечает по TLS1.3/H2 с этого сервера."
  echo "!! Возьми другой: www.apple.com, www.samsung.com, www.cloudflare.com, dl.google.com"; exit 1
fi

echo "==> Установка Marzban (официальный скрипт Gozargah)"
if [[ ! -f "$COMPOSE" ]]; then
  bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
else
  echo "    Marzban уже установлен в /opt/marzban"
fi

echo "==> Генерация ключей Reality (x25519) и shortId"
XRAY_BIN="docker compose -f ${COMPOSE} exec -T marzban xray"
KEYS="$($XRAY_BIN x25519 2>/dev/null || docker run --rm ghcr.io/xtls/xray-core:latest x25519)"
# Xray <25.x печатает 'Private key/Public key', >=25.x — 'PrivateKey/Password'.
PRIVATE_KEY="$(echo "$KEYS" | grep -iE '^ *private' | sed 's/.*: *//' | tr -d ' \r')"
PUBLIC_KEY="$(echo  "$KEYS" | grep -iE '^ *(public|password)' | sed 's/.*: *//' | tr -d ' \r')"
SHORT_ID="$(openssl rand -hex 8)"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { echo "!! Не смог разобрать вывод x25519:"; echo "$KEYS"; exit 1; }

echo "==> Запись ${XRAYJSON}"
mkdir -p /var/lib/marzban
[[ -f "$XRAYJSON" ]] && cp "$XRAYJSON" "${XRAYJSON}.bak.$(date +%s)"
cat >"$XRAYJSON" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}:443",
          "xver": 0,
          "serverNames": ["${REALITY_DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "VLESS TCP REALITY BACKUP",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT_ALT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.apple.com:443",
          "xver": 0,
          "serverNames": ["www.apple.com"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "DIRECT" },
    { "protocol": "blackhole", "tag": "BLOCK" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF
jq -e . "$XRAYJSON" >/dev/null || { echo "!! невалидный JSON"; exit 1; }

echo "==> Правка ${ENVFILE}"
set_env() { # key value
  if grep -qE "^\s*#?\s*$1\s*=" "$ENVFILE"; then
    sed -i -E "s|^\s*#?\s*$1\s*=.*|$1 = $2|" "$ENVFILE"
  else
    echo "$1 = $2" >>"$ENVFILE"
  fi
}
set_env UVICORN_HOST '"0.0.0.0"'
set_env UVICORN_PORT "${PANEL_PORT}"
set_env XRAY_JSON '"/var/lib/marzban/xray_config.json"'

echo "==> Перезапуск"
marzban restart -n || docker compose -f "$COMPOSE" up -d --force-recreate

sleep 5
cat >"${OUT_DIR}/reality.txt" <<EOF
dest / SNI        : ${REALITY_DEST}
port              : ${VLESS_PORT} (backup ${VLESS_PORT_ALT}, SNI www.apple.com)
privateKey (srv)  : ${PRIVATE_KEY}
publicKey  (pbk)  : ${PUBLIC_KEY}
shortId    (sid)  : ${SHORT_ID}
flow              : xtls-rprx-vision
fingerprint (fp)  : chrome
inbound tags      : "VLESS TCP REALITY", "VLESS TCP REALITY BACKUP"
EOF
chmod 600 "${OUT_DIR}/reality.txt"
chown "$OUT_OWNER" "${OUT_DIR}/reality.txt"

echo
echo "================ Reality готов ================"
cat "${OUT_DIR}/reality.txt"
echo "==============================================="
echo "Сохранено в ${OUT_DIR}/reality.txt"
echo
echo "Логи ядра:  marzban logs      (следует за выводом; Ctrl+C для выхода, -n — разовый дамп)"
echo "Далее: создай админа ->  marzban cli admin create --sudo"
