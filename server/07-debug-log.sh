#!/usr/bin/env bash
# Временно включает подробный лог Xray. Нужен, когда клиент пишет «подключено»,
# а трафика нет: при loglevel=warning и show=false отказ Reality не логируется
# ВООБЩЕ, и в выводе `marzban logs` видны только строки API панели.
#
#   sudo bash 07-debug-log.sh on    # loglevel=debug + realitySettings.show=true, рестарт
#   sudo bash 07-debug-log.sh off   # вернуть как было, рестарт
#
# Не оставляй debug включённым надолго: лог пишет адреса всех соединений.
set -euo pipefail

MODE="${1:-}"
XRAYJSON=/var/lib/marzban/xray_config.json
BAK="${XRAYJSON}.predebug"

[[ $EUID -eq 0 ]] || { echo "Запускать от root (или через sudo)"; exit 1; }
[[ -f "$XRAYJSON" ]] || { echo "!! Нет ${XRAYJSON}"; exit 1; }

apply(){ # jq-программа
  local tmp; tmp="$(mktemp)"
  jq "$1" "$XRAYJSON" >"$tmp"
  jq -e . "$tmp" >/dev/null || { echo "!! jq выдал невалидный JSON, не применяю"; rm -f "$tmp"; exit 1; }
  cat "$tmp" >"$XRAYJSON"    # не mv: сохраняем владельца и права исходного файла
  rm -f "$tmp"
}

# select(...) обязателен: без него jq создаст realitySettings у инбаундов,
# где его нет (например VLESS+WS), и сломает конфиг.
SET_SHOW='(.inbounds[] | select(.streamSettings.realitySettings) | .streamSettings.realitySettings.show)'

case "$MODE" in
on)
  [[ -f "$BAK" ]] || cp -p "$XRAYJSON" "$BAK"
  apply ".log.loglevel = \"debug\" | ${SET_SHOW} = true"
  marzban restart -n
  echo
  echo "Debug включён. Теперь:"
  echo "  1. открой лог:        sudo marzban logs"
  echo "  2. жми подключение на телефоне"
  echo "  3. смотри, что появится:"
  echo "     'REALITY: processed invalid connection' -> клиент не опознан (pbk/sid/sni/fp)"
  echo "     'accepted tcp:...' без ответа           -> хендшейк ок, не работает исходящая связность"
  echo "  4. верни обратно:     sudo bash $0 off"
  ;;
off)
  if [[ -f "$BAK" ]]; then
    cat "$BAK" >"$XRAYJSON"; rm -f "$BAK"
    echo "Конфиг восстановлен из ${BAK##*/}"
  else
    apply ".log.loglevel = \"warning\" | ${SET_SHOW} = false"
    echo "Бэкапа не было — просто вернул loglevel=warning, show=false"
  fi
  marzban restart -n
  echo "Debug выключен."
  ;;
*)
  echo "Использование: $0 [on|off]"
  CUR="$(jq -r '.log.loglevel // "?"' "$XRAYJSON")"
  echo "Сейчас: loglevel=${CUR}$( [[ -f "$BAK" ]] && echo ' (бэкап есть -> debug включён)' )"
  exit 1;;
esac
