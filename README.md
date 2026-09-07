# Marzban + VLESS/Reality для Вьетнама

Готовый комплект: Xray-core под панелью Marzban, протокол **VLESS + Reality на TCP/443**.
Reality не режется DPI Vinaphone/Viettel, потому что для наблюдателя соединение выглядит
как обычный TLS 1.3 к `www.microsoft.com` — включая настоящий сертификат Microsoft.
Домен и Let's Encrypt не нужны, работает по голому IP.

## Файлы

| Файл | Что делает |
|---|---|
| `server/01-bootstrap.sh` | apt upgrade, Docker, BBR, UFW, отключение пароля root по SSH |
| `server/02-install-marzban.sh` | ставит Marzban, генерит ключи Reality, пишет `xray_config.json` |
| `server/03-create-user.sh` | создаёт юзера через API, печатает `vless://` и QR |
| `server/04-autoupdate.sh` | автообновление: `cron` (рекомендуется) или `watchtower` |
| `server/05-check.sh` | диагностика: порты, логи, проверка маскировки снаружи |
| `server/marzban.env.example` | что должно быть в `/opt/marzban/.env` |
| `server/xray_config.example.json` | эталон конфига Reality |
| `server/optional-ws-cdn.md` | запасной канал VLESS+WS через Cloudflare (нужен домен) |

## Залить на сервер

```bash
scp -r server root@<IP>:/root/marzban-setup
ssh root@<IP>
cd /root/marzban-setup
```

---

## Шаг 1. Подготовка сервера

```bash
bash 01-bootstrap.sh
```

Ставит Docker (если нет), включает BBR, настраивает UFW: открыты **22, 443, 8443, 8000**,
всё остальное закрыто. Marzban запускается с `network_mode: host`, поэтому правила UFW
на него действуют (при обычном `ports:` докер обошёл бы UFW через свои iptables-цепочки).

Хардненинг SSH — отдельно и **только после** того, как проверил вход по ключу:

```bash
ssh-copy-id root@<IP>        # с ноутбука, если ключа ещё нет
HARDEN_SSH=1 bash 01-bootstrap.sh
```

Скрипт откажется отключать пароль, если `authorized_keys` пуст. Не закрывай текущую
SSH-сессию, пока не убедился, что вход по ключу работает в новом окне.

---

## Шаг 2. Установка Marzban

```bash
bash 02-install-marzban.sh
```

Что делает:
1. Проверяет, что 443 свободен (если там nginx — скрипт остановится; либо погаси nginx,
   либо запусти `VLESS_PORT=8443 bash 02-install-marzban.sh`).
2. Проверяет, что `www.microsoft.com` доступен с сервера по TLS 1.3 + HTTP/2 — без этого
   Reality не заработает.
3. Ставит Marzban официальным скриптом Gozargah в `/opt/marzban` (compose + `.env`),
   данные в `/var/lib/marzban`.
4. Генерит пару x25519 и `shortId`, пишет `xray_config.json`, правит `.env`, перезапускает.

Другой SNI — переменной:

```bash
REALITY_DEST=www.apple.com bash 02-install-marzban.sh
```

Ключи и параметры остаются в `/root/marzban-reality.txt` (chmod 600).

### Создать админа панели

```bash
marzban cli admin create --sudo
```

Панель: `http://<IP>:8000/dashboard/`

> Панель по умолчанию идёт по **HTTP** — пароль летит открытым текстом. Для личного
> сервера безопаснее закрыть её и ходить через SSH-туннель: поставь
> `UVICORN_HOST = "127.0.0.1"` в `/opt/marzban/.env`, убери `ufw allow 8000`, и
> подключайся `ssh -N -L 8000:127.0.0.1:8000 root@<IP>`, открывая
> `http://127.0.0.1:8000/dashboard/`.

---

## Шаг 3. Что именно настроено в Reality

`/var/lib/marzban/xray_config.json` — два инбаунда с одной парой ключей:

| | основной | резервный |
|---|---|---|
| порт | 443 | 8443 |
| dest / serverNames | `www.microsoft.com:443` | `www.apple.com:443` |
| network | tcp | tcp |
| security | reality | reality |
| flow | `xtls-rprx-vision` (задаётся у пользователя) | то же |

`privateKey` лежит в конфиге сервера, клиенту нужен `publicKey` (`pbk`) — Marzban
подставляет его в ссылку сам. `shortIds` — один случайный 8-байтовый hex.
Пустая строка в `shortIds` намеренно не добавлена: она разрешала бы коннект без sid.

### После первого входа в панель — обязательный штрих

Панель → **Hosts** → для инбаунда `VLESS TCP REALITY`:
* **Address** — IP сервера (или оставь `{SERVER_IP}`),
* **Fingerprint** — `chrome`.

Без `fp=chrome` часть клиентов (особенно iOS) не подключается: TLS-отпечаток Xray
по умолчанию не похож на браузерный, и DPI это видит.

---

## Шаг 4. Пользователь, ссылка, QR

```bash
bash 03-create-user.sh vn-phone
```

Спросит логин/пароль админа, создаст юзера без лимитов и срока, выведет `vless://…`,
нарисует QR прямо в терминале и сохранит:

* `/root/vn-phone-links.txt`
* `/root/vn-phone-qr.png` → забрать: `scp root@<IP>:/root/vn-phone-qr.png .`

Ссылка выглядит так:

```
vless://<uuid>@<IP>:443?security=reality&encryption=none&pbk=<publicKey>&fp=chrome
&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com&sid=<shortId>#vn-phone
```

Через UI то же самое: **Create User** → Proxies: `VLESS` → flow `xtls-rprx-vision` →
отметить оба инбаунда → у карточки юзера кнопки «QR» и «Copy link».

Для нескольких устройств делай **отдельного пользователя на каждое** — так видно,
кто сколько ест, и можно отозвать одно устройство, не трогая остальные.

---

## Шаг 5. Клиенты

| Платформа | Приложение |
|---|---|
| Android | **v2rayNG** (GitHub 2dust/v2rayNG) или **NekoBox** |
| iOS | **Streisand**, **Shadowrocket** (платный), **v2box** |
| macOS | **V2RayXS**, **Furious**, **Nekoray** |
| Windows | **v2rayN**, **Nekoray** |

**v2rayNG:** `+` справа сверху → *Импорт из буфера обмена* (ссылка) или
*Импорт из QR-кода* → нажать конфиг → кнопка «V» внизу.

**Streisand:** `+` → *Добавить из буфера обмена* / *Сканировать QR* → переключатель вверху.

Проверь в клиенте, что подтянулись: `flow = xtls-rprx-vision`, `fingerprint = chrome`,
`sni = www.microsoft.com`, `publicKey` и `shortId` непустые.

Лучше импортировать **ссылку подписки** (`subscription_url` из шага 4), а не отдельный
конфиг — тогда при смене SNI или порта клиент обновится сам. Для этого в
`/opt/marzban/.env` задай `XRAY_SUBSCRIPTION_URL_PREFIX = "http://<IP>:8000"`.

---

## Шаг 6. Проверка

На сервере:

```bash
bash 05-check.sh          # всё сразу
marzban logs -f           # живые логи Marzban + Xray
```

Ключевой тест маскировки — с любой машины:

```bash
openssl s_client -connect <IP>:443 -servername www.microsoft.com </dev/null 2>/dev/null | grep subject
```

Должен вернуться сертификат **Microsoft**. Значит для DPI сервер неотличим от
microsoft.com, и порт не палится сканером.

На телефоне с включённым VPN:
1. `ifconfig.me` в браузере → должен показать IP сервера, не вьетнамский.
2. Открыть `claude.ai` — цель проверки.
3. В v2rayNG кнопка *Test connection* покажет реальный пинг до сервера.

---

## Если не работает

**Клиент подключается, но трафика нет / «handshake failure»**
SNI забанен или недоступен с сервера. Перегенерируй с другим dest — ключи и юзеры
сохранятся, поменяется только SNI (не забудь обновить ссылку у клиента):

```bash
REALITY_DEST=www.yahoo.com bash 02-install-marzban.sh
# альтернативы: www.amazon.com, www.bing.com, www.samsung.com, dl.google.com, www.icloud.com
```

Правило выбора dest: чужой домен, TLS 1.3 + HTTP/2, не заблокирован во Вьетнаме,
не CDN твоего же хостера и не популярный «палёный» вроде `www.google.com`.

**Совсем нет коннекта на 443**
Провайдер режет 443 к твоему IP или хостер фильтрует. Переключись на резервный инбаунд
`8443` (он уже поднят, отдельная ссылка есть в выводе шага 4). Если и там глухо —
проверь, что IP сервера вообще пингуется из Вьетнама: возможно, забанен весь IP,
тогда нужен новый IP у хостера или вариант с CDN (`server/optional-ws-cdn.md`).

**Мобильный интернет Vinaphone работает хуже Wi-Fi**
Reality идёт по TCP, и MTU там обычно ни при чём — фрагментацию разруливает MSS.
Сначала включи на сервере клампинг MSS, это чинит большинство таких случаев:

```bash
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
apt-get -y install iptables-persistent && netfilter-persistent save
```

Если не помогло — в v2rayNG *Settings → MTU* поставь `1400`, затем `1300`
(это MTU tun-интерфейса, влияет только в режиме VPN).

**Панель не открывается**
`ss -lntp | grep 8000` — слушает ли; `ufw status` — открыт ли порт;
`marzban logs | tail -50` — не упал ли контейнер.

**Ссылка без `pbk=`**
Ядро Xray старое и не выводит публичный ключ. `marzban core-update`, затем
`marzban restart -n`. Публичный ключ на всякий случай лежит в `/root/marzban-reality.txt`.

---

## Автообновление

```bash
bash 04-autoupdate.sh cron          # рекомендуется
# или
bash 04-autoupdate.sh watchtower
```

Cron раз в неделю дёргает `marzban update` — штатный путь, который корректно
мигрирует БД. Watchtower обновляет ежедневно и только контейнер Marzban, но
поднимает образ без миграций: если апдейт окажется битым, ты узнаешь об этом
из Вьетнама, когда VPN уже не работает. Для канала, от которого зависит доступ
в интернет, cron надёжнее.

## Обслуживание

```bash
marzban status | restart | logs -f | update | core-update
marzban cli admin create --sudo
marzban backup                      # бэкап /var/lib/marzban
docker ps
```

Забэкапить руками — достаточно скопировать `/var/lib/marzban` и `/opt/marzban/.env`:

```bash
tar czf marzban-backup.tar.gz /var/lib/marzban /opt/marzban/.env
```
