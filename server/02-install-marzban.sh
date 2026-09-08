#!/usr/bin/env bash
# Шаг 2+3: установка Marzban (Docker Compose) и настройка VLESS + Reality.
# Запуск:  bash 02-install-marzban.sh
# Переменные:
#   REALITY_DEST=www.microsoft.com  VLESS_PORT=443  VLESS_PORT_ALT=8443  PANEL_PORT=8000
#   REGEN_KEYS=1        сгенерировать НОВУЮ пару x25519 и shortId (ломает все выданные ссылки)
#   TAG_MAIN / TAG_ALT  теги инбаундов; по умолчанию берутся из существующего конфига
#
# Скрипт идемпотентен: повторный прогон (например, чтобы сменить REALITY_DEST) сохраняет
# ключи, shortId и теги инбаундов, поэтому ссылки и привязки юзеров в панели переживают его.
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
# Повторный прогон — штатный сценарий (смена dest/SNI). Наш собственный xray на этом порту
# помехой не является: он всё равно будет перезапущен в конце. Ругаемся только на чужой процесс.
PORT_HOLDER=""
PORT_LINE="$(ss -lntpH "sport = :${VLESS_PORT}" 2>/dev/null || true)"
if [[ -n "$PORT_LINE" ]]; then
  # users:(("xray",pid=123,fd=6)) -> первый токен в кавычках это имя процесса
  PORT_HOLDER="$(printf '%s\n' "$PORT_LINE" | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
  PORT_HOLDER="${PORT_HOLDER:-unknown}"
fi
if [[ -n "$PORT_HOLDER" ]]; then
  if [[ "$PORT_HOLDER" == "xray" ]]; then
    echo "    порт держит наш xray — повторный прогон, продолжаю"
  else
    echo "!! Порт ${VLESS_PORT} занят процессом ${PORT_HOLDER}:"
    ss -lntp "sport = :${VLESS_PORT}"
    echo "!! Останови сервис (nginx/apache/caddy) или запусти с VLESS_PORT=8443"; exit 1
  fi
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

XRAY_BIN="docker compose -f ${COMPOSE} exec -T marzban xray"
# Xray <25.x печатает 'Private key/Public key', >=25.x — 'PrivateKey/Password'.
parse_priv(){ grep -iE '^ *private' | sed 's/.*: *//' | tr -d ' \r' | head -1; }
parse_pub(){  grep -iE '^ *(public|password)' | sed 's/.*: *//' | tr -d ' \r' | head -1; }
xray_x25519(){ # аргументы прокидываются в команду x25519
  $XRAY_BIN x25519 "$@" 2>/dev/null \
    || docker run --rm ghcr.io/xtls/xray-core:latest x25519 "$@"
}

# Теги инбаундов: если конфиг уже есть — оставляем его теги, иначе юзеры в панели,
# привязанные к старым тегам, потеряют все ссылки.
if [[ -z "${TAG_MAIN:-}" && -f "$XRAYJSON" ]]; then
  TAG_MAIN="$(jq -r '.inbounds[0].tag // empty' "$XRAYJSON" 2>/dev/null || true)"
  TAG_ALT="${TAG_ALT:-$(jq -r '.inbounds[1].tag // empty' "$XRAYJSON" 2>/dev/null || true)}"
fi
TAG_MAIN="${TAG_MAIN:-VLESS TCP REALITY}"
TAG_ALT="${TAG_ALT:-${TAG_MAIN} BACKUP}"

# На IPv4-only сервере дефолтный freedom (domainStrategy: AsIs) отдаёт имя системному
# диалеру, тот видит AAAA и уходит в IPv6, которого нет, — соединения виснут, а внешне
# всё здорово: порт слушает, хендшейк проходит, трафика нет. UseIPv4 это снимает.
if [[ -z "${FREEDOM_STRATEGY:-}" ]]; then
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    FREEDOM_STRATEGY="AsIs"
  else
    FREEDOM_STRATEGY="UseIPv4"
  fi
fi
echo "==> Исходящая стратегия freedom: ${FREEDOM_STRATEGY} (переопределить: FREEDOM_STRATEGY=...)"

echo "==> Ключи Reality (x25519) и shortId"
OLD_PRIV=""; OLD_SID=""
if [[ -f "$XRAYJSON" ]]; then
  OLD_PRIV="$(jq -r '[.inbounds[]?.streamSettings?.realitySettings?.privateKey // empty][0] // empty' "$XRAYJSON" 2>/dev/null || true)"
  OLD_SID="$( jq -r '[.inbounds[]?.streamSettings?.realitySettings?.shortIds[0]? // empty][0] // empty' "$XRAYJSON" 2>/dev/null || true)"
fi

if [[ -n "$OLD_PRIV" && "${REGEN_KEYS:-0}" != "1" ]]; then
  echo "    переиспользую существующую пару — выданные ссылки останутся рабочими"
  echo "    (принудительно новая пара:  REGEN_KEYS=1 bash $0)"
  PRIVATE_KEY="$OLD_PRIV"
  SHORT_ID="${OLD_SID:-$(openssl rand -hex 8)}"
  PUBLIC_KEY="$(xray_x25519 -i "$PRIVATE_KEY" | parse_pub)"
  [[ -n "$PUBLIC_KEY" ]] || {
    echo "!! Не смог вывести publicKey из существующего privateKey (старая версия xray?)."
    echo "!! Либо возьми pbk из прошлого reality.txt, либо перегенерируй: REGEN_KEYS=1 bash $0"; exit 1; }
else
  echo "    генерирую новую пару"
  KEYS="$(xray_x25519)"
  PRIVATE_KEY="$(printf '%s\n' "$KEYS" | parse_priv)"
  PUBLIC_KEY="$( printf '%s\n' "$KEYS" | parse_pub)"
  SHORT_ID="$(openssl rand -hex 8)"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { echo "!! Не смог разобрать вывод x25519:"; echo "$KEYS"; exit 1; }
fi

echo "==> Запись ${XRAYJSON}"
mkdir -p /var/lib/marzban
[[ -f "$XRAYJSON" ]] && cp "$XRAYJSON" "${XRAYJSON}.bak.$(date +%s)"
cat >"$XRAYJSON" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "${TAG_MAIN}",
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
      "tag": "${TAG_ALT}",
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
    { "protocol": "freedom", "tag": "DIRECT", "settings": { "domainStrategy": "${FREEDOM_STRATEGY}" } },
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
# Значение, которое оператор мог выставить осознанно, повторный прогон затирать не должен:
# UVICORN_HOST = "127.0.0.1" прячет панель за SSH-туннель, и вернуть её на 0.0.0.0 молча —
# значит выставить логин/пароль в интернет по голому HTTP.
set_env_default() { # key value
  if grep -qE "^\s*$1\s*=" "$ENVFILE"; then
    echo "    $1 уже задан в ${ENVFILE} — не трогаю"
  else
    set_env "$1" "$2"
  fi
}
set_env_default UVICORN_HOST '"0.0.0.0"'
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
inbound tags      : "${TAG_MAIN}", "${TAG_ALT}"
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
