#!/usr/bin/env bash
# Шаг 0: рабочий пользователь deploy. Запускать ОДИН РАЗ, от root, при первом входе.
#
#   ssh root@<IP>
#   bash 00-deploy-user.sh
#
# Переменные:
#   DEPLOY_USER=deploy                 имя пользователя
#   PUBKEY="ssh-ed25519 AAAA... me"    публичный ключ; если не задан — берётся из
#                                      /root/.ssh/authorized_keys (тот, которым ты вошёл)
#
# Пользователь создаётся БЕЗ пароля (вход только по ключу) и с NOPASSWD-sudo:
# иначе sudo у беспарольной учётки просто не сработает. Это не ослабление —
# членство в группе docker и так эквивалентно root.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
PUBKEY="${PUBKEY:-}"

[[ $EUID -eq 0 ]] || { echo "Запускать от root"; exit 1; }

if [[ -z "$PUBKEY" ]]; then
  if [[ -s /root/.ssh/authorized_keys ]]; then
    echo "==> Беру ключи из /root/.ssh/authorized_keys"
    PUBKEY="$(grep -vE '^\s*(#|$)' /root/.ssh/authorized_keys)"
  else
    echo "!! Нет ни PUBKEY, ни /root/.ssh/authorized_keys."
    echo "!! Сначала с ноутбука:  ssh-copy-id root@<IP>"
    echo "!! Либо запусти:        PUBKEY='ssh-ed25519 AAAA...' bash $0"
    exit 1
  fi
fi

echo "==> Пользователь ${DEPLOY_USER}"
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "    уже существует"
else
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi

echo "==> Группы: sudo + docker"
usermod -aG sudo "$DEPLOY_USER"
getent group docker >/dev/null && usermod -aG docker "$DEPLOY_USER" \
  || echo "    группы docker пока нет — 01-bootstrap.sh создаст её вместе с Docker"

echo "==> SSH-ключ"
HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "${HOME_DIR}/.ssh"
touch "${HOME_DIR}/.ssh/authorized_keys"
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  grep -qxF "$k" "${HOME_DIR}/.ssh/authorized_keys" || echo "$k" >>"${HOME_DIR}/.ssh/authorized_keys"
done <<<"$PUBKEY"
chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "${HOME_DIR}/.ssh"

echo "==> sudo без пароля"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"
visudo -c -q || { rm -f "/etc/sudoers.d/90-${DEPLOY_USER}"; echo "!! sudoers сломан, откатил"; exit 1; }

echo
echo "================================================================"
echo "Готово. ТЕПЕРЬ, НЕ ЗАКРЫВАЯ ЭТУ СЕССИЮ, проверь в новом окне:"
echo
echo "    ssh ${DEPLOY_USER}@$(curl -s -4 -m 5 https://ifconfig.me || echo '<IP>')"
echo "    sudo -n true && echo 'sudo ok'"
echo
echo "Работает — продолжай под ${DEPLOY_USER}:"
echo "    git clone https://github.com/EDidenko/marzik.git"
echo "    cd marzik/server && sudo bash 01-bootstrap.sh"
echo
echo "Вход root по SSH закроет 01-bootstrap.sh с HARDEN_SSH=1 (см. README)."
echo "================================================================"
