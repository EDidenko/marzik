# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A set of ordered bash scripts that provision a single VPS with the **Marzban** panel running
**Xray-core**, configured for **VLESS + Reality over TCP/443**. The target audience is one
person setting up a personal VPN for use inside Vietnam (DPI evasion via Reality masquerading
as `www.microsoft.com`). No domain or TLS certificate required — it works on a bare IP.

There is no application code, build, or test suite. The deliverable is the scripts in `server/`
plus `README.md` (written in Russian — it is the authoritative operator manual; keep it in sync
with any script change).

## Working on the scripts

- **Everything in `server/` runs on the target Ubuntu/Debian VPS, not locally.** You cannot
  execute these end-to-end here; validate with `bash -n` and `shellcheck`.
- Scripts are numbered and strictly sequential: `00` → `01` → `02` → `03`, then `04`/`05` as
  needed. Each assumes the previous one succeeded.
- All scripts use `set -euo pipefail` (except `05-check.sh`, which is diagnostic and must not
  abort on a failed check).
- Configuration is entirely via environment variables with `${VAR:-default}` defaults — there
  are no config files or flags. Preserve this pattern. Common vars: `REALITY_DEST`,
  `VLESS_PORT` (443), `VLESS_PORT_ALT` (8443), `PANEL_PORT` (8000), `DEPLOY_USER` (deploy),
  `HARDEN_SSH`, `ADMIN_USER`/`ADMIN_PASS`, `OUT_DIR`.
- **Secrets (`reality.txt`, `*-links.txt`, `*-qr.png`) are written to the invoking user's home
  (`$SUDO_USER`'s `~/marzban/`), mode 600/700, chowned back to that user — never to `/root`.**
  This is deliberate so the passwordless `deploy` user can read them without sudo. Keep it.
- Scripts that touch sshd (`01-bootstrap.sh` with `HARDEN_SSH=1`) must stay fail-safe: verify a
  working key-based non-root login exists before locking `PermitRootLogin`, run `sshd -t` before
  restart, and always print the rollback command. Do not weaken these guards.
- The `00-*` filename prefix on `/etc/ssh/sshd_config.d/00-hardening.conf` matters — sshd takes
  the *first* value seen, so it must sort before `50-cloud-init.conf`.

## Architecture / big picture

| Script | Runs as | Role |
|---|---|---|
| `00-deploy-user.sh` | root (first login) | create `deploy` user: SSH key from `/root/.ssh/authorized_keys` or `$PUBKEY`, `sudo` + `docker` groups, `NOPASSWD` sudoers |
| `01-bootstrap.sh` | root | apt upgrade, Docker, BBR (`sysctl`), UFW (allow 22/443/8443/8000, deny rest), optional SSH hardening |
| `02-install-marzban.sh` | root | install Marzban via Gozargah's upstream script into `/opt/marzban`; generate x25519 keypair + `shortId`; write `/var/lib/marzban/xray_config.json`; patch `/opt/marzban/.env`; restart |
| `03-create-user.sh` | any user (uses REST API) | POST `/api/admin/token` then `/api/user`; print `vless://` links + subscription URL + terminal QR |
| `04-autoupdate.sh` | root | `cron` mode (weekly `marzban update`, recommended) or `watchtower` mode |
| `05-check.sh` | root | server-side diagnostics: containers, listening ports, UFW, logs, JSON validity, Reality masquerade probe |
| `06-show-links.sh` | any user (REST API) | client-side diagnostics: panel Hosts (address/sni/fingerprint), inbound tags, and each `vless://` link broken out param-by-param with the UUID masked |
| `07-debug-log.sh` | root | `on`/`off` toggle for `log.loglevel=debug` + `realitySettings.show=true`, backing the config up to `.predebug` and restoring it on `off` |

Key facts that span files:

- **UFW works because Marzban runs `network_mode: host`.** With normal Docker `ports:` mapping,
  container traffic would bypass UFW via Docker's iptables chains.
- **The generated `xray_config.json` has two inbounds sharing one keypair**: primary on 443
  (`serverNames: www.microsoft.com`) and backup on 8443 (`www.apple.com`).
- **`02-install-marzban.sh` is idempotent by design.** Re-running it (the documented way to
  change `REALITY_DEST`) must not break issued links, so it reuses the existing `privateKey`,
  `shortId`, and **inbound tags** read out of the current `xray_config.json`. Only `REGEN_KEYS=1`
  mints a new pair. Its "is port 443 free" guard deliberately tolerates a listener named `xray`
  (our own) and rejects anything else. Keep all of this when editing.
- Inbound tags are therefore **not fixed strings** — deployed servers vary (`VLESS TCP REALITY`
  vs `VLESS_TCP_REALITY`). `03-create-user.sh` reads them from `GET /api/inbounds` rather than
  hardcoding; never reintroduce a literal tag list.
- `shortIds` intentionally never contains an empty string (that would allow connecting without
  a `sid`).
- The x25519 parser in `02-install-marzban.sh` handles both Xray output formats
  (`Private key`/`Public key` for <25.x, `PrivateKey`/`Password` for >=25.x).
- `xray_config.example.json` and `marzban.env.example` are reference documents, not consumed by
  any script; update them when the generator logic changes.
- After first panel login the operator must set Fingerprint=`chrome` in **Hosts** — without
  `fp=chrome` many clients (iOS especially) fail. This is manual and documented in README §3.
- **Debugging "client says connected but no traffic" has a fixed order**: `05-check.sh` proves
  the server (a valid dest certificate on the VLESS port with `Verify return code: 0` means
  Reality's server side is fine), `06-show-links.sh` proves what the panel hands the client,
  then `07-debug-log.sh on` makes the handshake itself visible. Empty `sni`/`fingerprint` in
  Hosts is **not** a fault — Marzban inherits them from the inbound; only the generated
  `vless://` is authoritative.
- **The `freedom` outbound's `domainStrategy` is auto-selected from the host**: `UseIPv4` when
  there is no global IPv6 address, `AsIs` otherwise (`FREEDOM_STRATEGY` overrides). Xray's
  default `AsIs` on an IPv4-only VPS follows AAAA records into unreachable IPv6 and hangs,
  which looks identical to a healthy server from every external test.
- **`getent hosts` is not a valid DNS check** — glibc tries `AF_INET6` first and prints only
  AAAA when they exist, so it looks like A records are missing. Use `getent ahostsv4` /
  `ahostsv6` separately, as `05-check.sh` does.
- **Reality failures are silent by default.** At `loglevel: warning` with `show: false`, a
  rejected handshake logs nothing at all, so `marzban logs` shows only panel API lines and
  looks healthy. Anything that raises `realitySettings.show` must use a
  `select(.streamSettings.realitySettings)` guard, or jq will graft `realitySettings` onto
  non-Reality inbounds and corrupt the config.
- `optional-ws-cdn.md` is an unautomated fallback (VLESS+WS behind Cloudflare, needs a domain).

## State on the server (not in this repo)

- `/opt/marzban/` — docker-compose + `.env`
- `/var/lib/marzban/` — `xray_config.json`, `db.sqlite3`, backups (`marzban backup`)
- `~/marzban/` (invoking user) — generated secrets
- `/etc/cron.d/marzban-update`, `/opt/watchtower/` — autoupdate
