# Запасной канал: VLESS + WebSocket через Cloudflare CDN

Нужен **домен** на Cloudflare. Без домена этот раздел пропусти — резервом уже служит
второй Reality-inbound на 8443 (см. `02-install-marzban.sh`).

Смысл: трафик идёт на IP Cloudflare, а не на твой VPS. Если провайдер во Вьетнаме
забанит IP сервера — этот канал переживёт бан.

## Почему не на 443

Порт 443 занят Reality. Cloudflare проксирует HTTPS только на определённые порты
origin: 443, 2053, 2083, 2087, 2096, 8443. Reality уже на 443, `8443` в этой схеме
тоже занят бэкапом — возьми **2053**.

## 1. DNS

В Cloudflare: `A`-запись `cdn.твой-домен.tld` → IP VPS, **проксирование включено**
(оранжевое облако). SSL/TLS mode: **Full**.

## 2. Сертификат для origin

Cloudflare → SSL/TLS → Origin Server → Create Certificate. Положи на сервер:

```bash
mkdir -p /var/lib/marzban/certs
nano /var/lib/marzban/certs/cf-origin.pem   # вставь certificate
nano /var/lib/marzban/certs/cf-origin.key   # вставь private key
chmod 600 /var/lib/marzban/certs/cf-origin.key
```

## 3. Inbound в `/var/lib/marzban/xray_config.json`

Добавь в массив `inbounds`:

```json
{
  "tag": "VLESS WS CDN",
  "listen": "0.0.0.0",
  "port": 2053,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "streamSettings": {
    "network": "ws",
    "wsSettings": { "path": "/cdn-ws" },
    "security": "tls",
    "tlsSettings": {
      "serverName": "cdn.твой-домен.tld",
      "certificates": [
        {
          "certificateFile": "/var/lib/marzban/certs/cf-origin.pem",
          "keyFile": "/var/lib/marzban/certs/cf-origin.key"
        }
      ]
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
}
```

Важно: у WS-инбаунда **не должно быть** `flow: xtls-rprx-vision` — vision работает
только с TCP+TLS/Reality. Пользователю в Marzban оставь flow пустым для этого inbound.

## 4. Открыть порт и применить

```bash
ufw allow 2053/tcp comment 'VLESS WS CDN'
marzban restart -n
```

## 5. Выдать пользователю

Панель → пользователь → добавь inbound `VLESS WS CDN`, в Hosts для него укажи
address `cdn.твой-домен.tld`, port `443` (клиент ходит на CF по 443), sni тот же домен.
