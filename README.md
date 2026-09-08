# Marzban + VLESS/Reality для Вьетнама

Готовый комплект: Xray-core под панелью Marzban, протокол **VLESS + Reality на TCP/443**.
Reality не режется DPI Vinaphone/Viettel, потому что для наблюдателя соединение выглядит
как обычный TLS 1.3 к `www.apple.com` — включая настоящий сертификат Apple.
Домен и Let's Encrypt не нужны, работает по голому IP.

## Файлы

| Файл | Что делает |
|---|---|
| `server/00-deploy-user.sh` | создаёт пользователя `deploy` с sudo и твоим SSH-ключом |
| `server/01-bootstrap.sh` | apt upgrade, Docker, BBR, UFW, отключение пароля root по SSH |
| `server/02-install-marzban.sh` | ставит Marzban, генерит ключи Reality, пишет `xray_config.json` |
| `server/03-create-user.sh` | создаёт юзера через API, печатает `vless://` и QR |
| `server/04-autoupdate.sh` | автообновление: `cron` (рекомендуется) или `watchtower` |
| `server/05-check.sh` | диагностика сервера: порты, логи, проверка маскировки снаружи |
| `server/06-show-links.sh` | диагностика клиента: Hosts, теги, разобранная по параметрам `vless://` |
| `server/07-debug-log.sh` | `on`/`off`: подробный лог Xray, чтобы увидеть отказ Reality-хендшейка |
| `server/08-selftest.sh` | сквозной тест: ходит наружу через свой же инбаунд, отделяя сервер от клиента |
| `server/marzban.env.example` | что должно быть в `/opt/marzban/.env` |
| `server/xray_config.example.json` | эталон конфига Reality |
| `server/optional-ws-cdn.md` | запасной канал VLESS+WS через Cloudflare (нужен домен) |

## Шаг 0. Рабочий пользователь

Первый и единственный вход под root — чтобы завести `deploy` и больше root по SSH
не пускать:

```bash
scp server/00-deploy-user.sh root@<IP>:/root/
ssh root@<IP> 'bash /root/00-deploy-user.sh'
```

Клонировать репозиторий прямо на сервере на этом шаге нельзя: `deploy` ещё не создан,
а если репозиторий приватный — у сервера вообще нет доступа к GitHub. Поэтому
единственный файл, который доставляется через `scp`, — этот.

Если репозиторий публичный, шаг 0 сводится к одной строке:

```bash
ssh root@<IP>
curl -fsSL https://raw.githubusercontent.com/EDidenko/marzik/main/server/00-deploy-user.sh | bash
```

Скрипт создаёт `deploy`, кладёт ему тот же SSH-ключ, которым ты вошёл, даёт `sudo`
и группу `docker`. Пароля у учётки нет — только ключ, поэтому sudo идёт через
`NOPASSWD` (иначе беспарольный `deploy` не смог бы им пользоваться).

Отдельный ключ вместо унаследованного:

```bash
PUBKEY="ssh-ed25519 AAAA... me@laptop" bash 00-deploy-user.sh
```

**Не закрывая root-сессию**, проверь в новом окне: `ssh deploy@<IP>` и `sudo -n true`.
Работает — дальше всё под `deploy`:

```bash
ssh -A deploy@<IP>          # -A пробрасывает ssh-агент: приватный репо клонируется
cd ~ && git clone git@github.com:EDidenko/marzik.git
cd marzik/server
```

Публичный репозиторий — проще: `git clone https://github.com/EDidenko/marzik.git`,
`-A` не нужен.

Чтобы сервер мог делать `git pull` сам, без проброшенного агента, заведи **deploy key**
(read-only, отзывается отдельно от аккаунта):

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/gh_marzik -C "marzik@$(hostname)"
printf 'Host github.com\n  IdentityFile ~/.ssh/gh_marzik\n  IdentitiesOnly yes\n' >> ~/.ssh/config
cat ~/.ssh/gh_marzik.pub    # -> GitHub: репозиторий -> Settings -> Deploy keys -> Add
```

Клонируй в домашку `deploy`, а не в `/opt`: туда установщик положит `/opt/marzban`.

> Зачем это нужно, если `deploy` с sudo и в группе `docker` — тот же root?
> Изоляции здесь действительно нет. Смысл в другом: после шага 1 в sshd встанет
> `PermitRootLogin no`, а брутфорс-боты стучатся именно в `root`. Плюс `SUDO_USER`
> в логах и явное `sudo` вместо молчаливого выполнения от root.

---

## Шаг 1. Подготовка сервера

```bash
sudo bash 01-bootstrap.sh
```

Ставит Docker (если нет), включает BBR, настраивает UFW: открыты **22, 443, 8443, 8000**,
всё остальное закрыто. Marzban запускается с `network_mode: host`, поэтому правила UFW
на него действуют (при обычном `ports:` докер обошёл бы UFW через свои iptables-цепочки).

Хардненинг SSH — отдельным прогоном и **только после** того, как убедился, что
`ssh deploy@<IP>` работает:

```bash
sudo HARDEN_SSH=1 bash 01-bootstrap.sh
```

Скрипт сам решает, насколько закрутить: если `deploy` существует, имеет ключ и sudo —
ставит `PermitRootLogin no`; если нет — только `prohibit-password`, чтобы ты не остался
за дверью. При пустом `authorized_keys` он не тронет sshd вообще.

Держи текущую сессию открытой, пока не проверишь вход в новом окне. Не пустило —
откат прямо из неё:

```bash
sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl restart ssh
```

Если сессия всё-таки закрылась и доступа нет — спасает только веб-консоль (VNC/serial)
в панели хостера. Проверь заранее, что она у тебя есть.

---

## Шаг 2. Установка Marzban

```bash
sudo bash 02-install-marzban.sh
```

Что делает:
1. Проверяет, что 443 свободен (если там nginx — скрипт остановится; либо погаси nginx,
   либо запусти `sudo VLESS_PORT=8443 bash 02-install-marzban.sh`).
2. Проверяет, что `www.apple.com` доступен с сервера по TLS 1.3 + HTTP/2 — без этого
   Reality не заработает.
3. Ставит Marzban официальным скриптом Gozargah в `/opt/marzban` (compose + `.env`),
   данные в `/var/lib/marzban`.
4. Генерит пару x25519 и `shortId`, пишет `xray_config.json`, правит `.env`, перезапускает.

Другой SNI — переменной:

```bash
sudo REALITY_DEST=www.samsung.com bash 02-install-marzban.sh
```

Скрипт **идемпотентен**: повторный прогон переиспользует существующие ключи, `shortId`,
теги инбаундов и оба dest — голый `sudo bash 02-install-marzban.sh` ничего у клиентов не
ломает, его можно звать когда угодно. SNI меняется только при явном `REALITY_DEST=...`,
и тогда ссылку у клиента надо обновить. Занятый нашим же `xray` порт 443 не мешает.

Исходящую стратегию `freedom` скрипт выбирает сам: на сервере без глобального IPv6 ставит
`domainStrategy: "UseIPv4"`, иначе оставляет `AsIs`. Без этого на IPv4-only машине Xray
уходит по AAAA в несуществующий IPv6 — снаружи всё выглядит здорово (порт слушает,
хендшейк проходит), а трафика нет. Переопределить: `FREEDOM_STRATEGY=AsIs`.

Новая пара ключей — только явно, и это **обнулит все выданные ссылки**:

```bash
sudo REGEN_KEYS=1 bash 02-install-marzban.sh
```

Ключи и параметры остаются в `~/marzban/reality.txt` (режим 700, владелец — тот,
кто вызвал sudo, а не root).

### Создать админа панели

```bash
sudo marzban cli admin create --sudo
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
| dest / serverNames | `www.apple.com:443` | `www.apple.com:443` |
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

* `~/marzban/vn-phone-links.txt`
* `~/marzban/vn-phone-qr.png` → забрать: `scp deploy@<IP>:marzban/vn-phone-qr.png .`

Этот скрипт единственный, которому root не нужен: он работает через REST API панели.

Ссылка выглядит так:

```
vless://<uuid>@<IP>:443?security=reality&encryption=none&pbk=<publicKey>&fp=chrome
&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=<shortId>#vn-phone
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
`sni = www.apple.com`, `publicKey` и `shortId` непустые.

Лучше импортировать **ссылку подписки** (`subscription_url` из шага 4), а не отдельный
конфиг — тогда при смене SNI или порта клиент обновится сам. Для этого в
`/opt/marzban/.env` задай `XRAY_SUBSCRIPTION_URL_PREFIX = "http://<IP>:8000"`.

---

## Шаг 6. Проверка

На сервере:

```bash
sudo bash 05-check.sh     # всё сразу
sudo marzban logs         # живые логи Marzban + Xray (следует по умолчанию, Ctrl+C — выход)
sudo marzban logs -n      # разовый дамп без слежения
```

Ключевой тест маскировки — с любой машины:

```bash
openssl s_client -connect <IP>:443 -servername www.apple.com </dev/null 2>/dev/null | grep subject
```

Должен вернуться сертификат **Apple**. Значит для DPI сервер неотличим от
apple.com, и порт не палится сканером.

> Внимание: этот тест проверяет только **fallback**-путь Reality — то, что видит
> неопознанный клиент. Он проходит даже когда настоящий туннель не работает.
> Сквозная проверка — `08-selftest.sh`, см. «Если не работает».

На телефоне с включённым VPN:
1. `ifconfig.me` в браузере → должен показать IP сервера, не вьетнамский.
2. Открыть `claude.ai` — цель проверки.
3. В v2rayNG кнопка *Test connection* покажет реальный пинг до сервера.

---

## Если не работает

**Клиент подключается, но трафика нет / «handshake failure»**

Сначала раздели серверную и клиентскую стороны — это экономит часы:

```bash
sudo bash 05-check.sh          # сервер: порты, dest, маскировка снаружи
bash 06-show-links.sh <юзер>   # клиент: что панель реально отдаёт в ссылке
```

Если `05-check.sh` показал сертификат нужного домена и `Verify return code: 0`, серверная
часть Reality исправна — смотри итоговые ссылки в `06-show-links.sh`. Там должны быть
`sni=`, `fp=chrome`, `pbk=`, `sid=`, `flow=xtls-rprx-vision`; `pbk`/`sid` обязаны совпадать
с `~/marzban/reality.txt`. Пустые `sni`/`fp` в секции Hosts — не проблема: Marzban
наследует их из инбаунда, судить можно только по самой ссылке.

Ссылка верна, а трафика всё равно нет — убери клиентское устройство из уравнения:

```bash
sudo bash 08-selftest.sh <юзер>
```

Скрипт поднимает временный xray-клиент прямо на сервере и идёт наружу по той же самой
ссылке. Прошло — сервер исправен целиком, чинить надо приложение на телефоне. Не прошло —
проблема на сервере, и тогда включай подробный лог:

```bash
sudo bash 07-debug-log.sh on
sudo marzban logs            # и в этот момент подключайся с телефона
sudo bash 07-debug-log.sh off
```

`REALITY: processed invalid connection` — клиент не опознан (не сходятся `pbk`/`sid`/`sni`).
Хендшейк прошёл, но ответа нет — ищи проблему в исходящей связности сервера
(секция «Исходящая связность» в `05-check.sh`).

Если же сервер снаружи не отдаёт сертификат — SNI забанен или недоступен с сервера.
Перегони с другим dest: ключи, `shortId` и юзеры сохранятся, поменяется только SNI
(не забудь обновить ссылку у клиента):

```bash
sudo REALITY_DEST=www.samsung.com bash 02-install-marzban.sh
# альтернативы: www.apple.com, dl.google.com, www.icloud.com, www.amazon.com
```

Правило выбора dest: чужой домен, TLS 1.3 + HTTP/2, не заблокирован во Вьетнаме,
не CDN твоего же хостера и не популярный «палёный» вроде `www.google.com`.

> **`www.microsoft.com` не подошёл** и заменён дефолтом на `www.apple.com`.
> На одном и том же стенде, с одним ядром, ключами и `sid`: 443+microsoft — отказ,
> 443+samsung и 8443+apple — работает, то есть порт и прочее исключены.
> Важнее другое: **косвенные проверки такое не ловят** — порт слушает,
> `openssl s_client` снаружи отдаёт настоящий сертификат с `Verify return code: 0`,
> dest доступен по TLS1.3+H2, а туннель не работает. Меняя dest, подтверждай
> результат `08-selftest.sh`, а не сертификатом.

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

**Marzban падает в crash-loop после обновления ядра**

В логе `TypeError: 'NoneType' object is not subscriptable` в `app/xray/config.py`, строка
`settings['pbk'] = x25519['public_key']`. Marzban строит `pbk` для ссылки так: сначала
берёт `publicKey` из `realitySettings`, а если его там нет — вызывает `xray x25519 -i` и
разбирает вывод. У ядер 26.x формат вывода другой, разбор возвращает `None`, и падает
всё приложение целиком, а не только Xray.

Лечится тем, что `02-install-marzban.sh` пишет `publicKey` прямо в конфиг — тогда ветка
с вызовом `xray` не выполняется. Просто перегони скрипт. Аварийный откат на ядро из
docker-образа, если сервер нужен немедленно:

```bash
sudo sed -i '/XRAY_EXECUTABLE_PATH/d' /opt/marzban/.env && sudo marzban restart -n
```

**Сервер проходит `08-selftest.sh`, а телефон/ноутбук — нет**

Почти наверняка старое ядро Xray. Клиенты 2025+ с `fp=chrome` предлагают в ClientHello
постквантовый `X25519MLKEM768`; ядра до 25.x его не понимают, и Reality-хендшейк падает.
Коварство в том, что `08-selftest.sh` этого не видит: он поднимает клиент тем же старым
бинарником, что и сервер, — старый против старого работает.

```bash
sudo marzban core-update && sudo marzban restart -n
sudo bash 05-check.sh          # секция «Версия ядра Xray» не должна ругаться
```

Быстрая проверка гипотезы без обновления: в панели **Hosts** поставь Fingerprint
`safari` вместо `chrome` и переимпортируй ссылку. Заработало — дело точно в этом.

**Ссылка без `pbk=`**
Ядро Xray старое и не выводит публичный ключ. `marzban core-update`, затем
`marzban restart -n`. Публичный ключ на всякий случай лежит в `~/marzban/reality.txt`.

---

## Вариант: подселить на сервер, где уже есть nginx и сайты

Reality слушает свободные порты, nginx остаётся единственным владельцем 80 и 443.
Конфигурацию сайтов менять не нужно вообще.

> **Главное про фаервол.** `01-bootstrap.sh` настраивает UFW. Если UFW уже активен, правила
> он не сбрасывает (`UFW_RESET=auto`), но порты сайтов всё равно перечисли явно: на машине
> с выключенным UFW скрипт включит его — и без `EXTRA_PORTS` закроет 80, положив HTTP и
> обновление сертификатов Let's Encrypt.

```bash
# Шаг 0 пропусти, если рабочий пользователь на сервере уже есть.

# 1. Docker, BBR, UFW. Сайты остаются доступны.
sudo EXTRA_PORTS="80,443" VLESS_PORT=8443 VLESS_PORT_ALT=2053 bash 01-bootstrap.sh

# 2. Marzban + Reality на свободных портах. 443 не трогается: проверка занятости
#    смотрит только на VLESS_PORT.
sudo VLESS_PORT=8443 VLESS_PORT_ALT=2053 bash 02-install-marzban.sh

# 3. Свежее ядро. Docker-образ приносит старое, с ним современные клиенты не подключаются.
sudo marzban core-update          # выбрать самую свежую версию
sudo VLESS_PORT=8443 VLESS_PORT_ALT=2053 bash 02-install-marzban.sh   # пропишет путь к ядру

# 4. Админ, пользователь, проверка.
sudo marzban cli admin create --sudo
bash 03-create-user.sh phone
sudo VLESS_PORT=8443 VLESS_PORT_ALT=2053 bash 05-check.sh
sudo bash 08-selftest.sh phone
```

Второй прогон `02` на шаге 3 обязателен: он проставляет `XRAY_EXECUTABLE_PATH` на скачанное
ядро (без этого `core-update` молча не применяется) и кладёт `publicKey` в конфиг (без него
Marzban с ядром 26.x падает в crash-loop). Прогон идемпотентен — ключи и ссылки не меняются.

Почему 8443 и 2053: оба обычно не заблокированы и входят в список портов, которые проксирует
Cloudflare, — пригодится, если позже понадобится `optional-ws-cdn.md`.

После установки убедись, что nginx не задет:

```bash
sudo nginx -t
curl -sI https://твой-домен/ | head -1
sudo ss -lntp | grep -E ':(80|443|8443|2053)\b'
```

Порт 8000 наружу не нужен — Marzban без `UVICORN_SSL_*` слушает только 127.0.0.1.
Правило можно убрать: `sudo ufw delete allow 8000/tcp`, а в панель ходить туннелем
`ssh -N -L 8000:127.0.0.1:8000 <user>@<IP>`.

## Автообновление

```bash
sudo bash 04-autoupdate.sh cron          # рекомендуется
# или
sudo bash 04-autoupdate.sh watchtower
```

Cron раз в неделю дёргает `marzban update` — штатный путь, который корректно
мигрирует БД. Watchtower обновляет ежедневно и только контейнер Marzban, но
поднимает образ без миграций: если апдейт окажется битым, ты узнаешь об этом
из Вьетнама, когда VPN уже не работает. Для канала, от которого зависит доступ
в интернет, cron надёжнее.

## Обслуживание

```bash
sudo marzban status | restart | logs [-n] | update | core-update
sudo marzban cli admin create --sudo
sudo marzban backup                 # бэкап /var/lib/marzban
docker ps                           # без sudo: deploy в группе docker
```

> **`core-update` может отрапортовать об успехе, не применившись.** Он скачивает ядро
> в `/var/lib/marzban/xray-core/xray`, но не трогает `XRAY_EXECUTABLE_PATH` в `.env` —
> и если та не задана, Marzban продолжит запускать ядро из docker-образа. Проверяй
> секцией «Версия ядра Xray» в `05-check.sh`: она сравнивает запущенную версию с той,
> что лежит по этому пути. `02-install-marzban.sh` проставляет путь сам, если ядро есть.

Забэкапить руками — достаточно скопировать `/var/lib/marzban` и `/opt/marzban/.env`:

```bash
sudo tar czf marzban-backup.tar.gz /var/lib/marzban /opt/marzban/.env
```
