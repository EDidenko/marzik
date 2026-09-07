#!/usr/bin/env bash
# Шаг 1: подготовка сервера — обновление, Docker, BBR, UFW, (опц.) хардненинг SSH.
# Запуск:  bash 01-bootstrap.sh
# Переменные окружения (все опциональны):
#   SSH_PORT=22 PANEL_PORT=8000 VLESS_PORT=443 VLESS_PORT_ALT=8443
#   HARDEN_SSH=1 DEPLOY_USER=deploy
set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
PANEL_PORT="${PANEL_PORT:-8000}"
VLESS_PORT="${VLESS_PORT:-443}"
VLESS_PORT_ALT="${VLESS_PORT_ALT:-8443}"
HARDEN_SSH="${HARDEN_SSH:-0}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

[[ $EUID -eq 0 ]] || { echo "Запускать от root"; exit 1; }

echo "==> Обновление системы и базовые пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq upgrade
apt-get -y -qq install curl ca-certificates gnupg openssl socat git ufw jq qrencode

echo "==> Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
else
  echo "    Docker уже установлен: $(docker --version)"
fi
systemctl enable --now docker

echo "==> TCP BBR + сетевые лимиты"
cat >/etc/sysctl.d/99-marzban.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
fs.file-max = 1000000
EOF
sysctl --system >/dev/null
echo "    congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"

echo "==> UFW"
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}"/tcp        comment 'SSH'
ufw allow "${VLESS_PORT}"/tcp      comment 'VLESS Reality'
ufw allow "${VLESS_PORT_ALT}"/tcp  comment 'VLESS Reality backup'
ufw allow "${PANEL_PORT}"/tcp      comment 'Marzban panel'
ufw --force enable
ufw status numbered

if [[ "$HARDEN_SSH" == "1" ]]; then
  echo "==> Хардненинг SSH (только ключи)"

  # Есть ли рабочий не-root пользователь с sudo и своим ключом? Тогда root по SSH
  # закрываем полностью: боты брутфорсят именно root, а не выдуманное имя.
  DEPLOY_HOME=""
  if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  fi
  ROOT_LOGIN="prohibit-password"
  if [[ -n "$DEPLOY_HOME" && -s "${DEPLOY_HOME}/.ssh/authorized_keys" ]] \
     && id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx sudo; then
    ROOT_LOGIN="no"
    echo "    ${DEPLOY_USER} на месте (ключ + sudo) -> PermitRootLogin no"
  else
    echo "    Рабочего пользователя нет -> PermitRootLogin prohibit-password"
    echo "    (заведи его через 00-deploy-user.sh, чтобы закрыть root совсем)"
  fi

  if [[ "$ROOT_LOGIN" == "prohibit-password" && ! -s /root/.ssh/authorized_keys ]]; then
    echo "!! authorized_keys у root пуст и ${DEPLOY_USER} не готов —"
    echo "!! НЕ трогаю sshd, иначе потеряешь доступ к серверу."
    echo "!! Сначала: ssh-copy-id root@<IP>  или  bash 00-deploy-user.sh"
  else
    # Имя 00-* важно: sshd берёт ПЕРВОЕ найденное значение, а Include стоит в начале
    # sshd_config, поэтому файл должен идти раньше 50-cloud-init.conf.
    cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PermitRootLogin ${ROOT_LOGIN}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF
    if sshd -t; then
      systemctl restart ssh 2>/dev/null || systemctl restart sshd
      echo "    Готово: PermitRootLogin ${ROOT_LOGIN}, пароли выключены."
      echo "    НЕ закрывай текущую сессию, пока не проверишь вход в новом окне:"
      echo "        ssh ${DEPLOY_USER}@<IP>"
      echo "    Не пустило — откат из этой же сессии:"
      echo "        rm /etc/ssh/sshd_config.d/00-hardening.conf && systemctl restart ssh"
    else
      echo "!! sshd -t не прошёл, откатываю"
      rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    fi
  fi
fi

echo
echo "Шаг 1 завершён. Порт ${VLESS_PORT} занят кем-то? Проверка:"
ss -lntp | grep -E "[:.](${VLESS_PORT}|${PANEL_PORT})\b" || echo "  свободны"
