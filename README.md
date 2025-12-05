# WireGuard Admin (Django 5 + Tailwind 4)

Admin UI for managing WireGuard peers directly from `/etc/wireguard/wg0.conf`. Clients are parsed from the config file; the database only stores temporary download tokens and audit logs.

## Quickstart

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cd wgadmin_project
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver 0.0.0.0:8000
```

Login at `/login/` with a staff/admin account.

## Environment variables

- `WG_CONFIG_PATH` (default `/etc/wireguard/wg0.conf`)
- `WG_INTERFACE` (default `wg0`)
- `WG_SCRIPTS_DIR` (default `<repo>/scripts`)
- `WG_CLIENT_CONFIG_DIR` (default `/etc/wireguard/client`)
- `WG_PUBLIC_CONF_DIR` (default `/var/www/wireguard/conf`)
- `WG_QR_DIR` (default `/var/www/wireguard/qr`)
- `WG_ENDPOINT_PORT` (default `51830`)
- `WG_DNS` (default `1.1.1.1`)

## Tailwind CSS 4

Install Node deps and build CSS:

```bash
npm install -D tailwindcss@next
npx tailwindcss -i wgadmin/static/wgadmin/css/input.css -o wgadmin/static/wgadmin/css/tailwind.css --watch
```

Update the `content` globs in `tailwind.config.js/ts` to include `wgadmin/templates/**/*.html`.

## Management commands

- Deactivate expired tokens: `python manage.py cleanup_tokens`

Schedule via cron (runs every 15 min):

```
*/15 * * * * cd /path/to/repo/wgadmin_project && /path/to/venv/bin/python manage.py cleanup_tokens
```

## Scripts (JSON output)

Located in `scripts/` and wrapped by the legacy filenames:

- `wg_create_peer.sh --name <client> [--allowed-ips 0.0.0.0/0]`
- `wg_delete_peer.sh --id <name|public-key>`
- `wg_toggle_peer.sh (--enable|--disable) --id <name|public-key>`
- `wg_generate_qr.sh --id <name|public-key>`

All scripts read `WG_CONFIG_PATH`, `WG_CLIENT_CONFIG_DIR`, `WG_PUBLIC_CONF_DIR`, and `WG_QR_DIR` env vars, modify `wg0.conf`, restart `wg-quick@wg0`, and print JSON.

## Database usage

Only `ConfigDownloadToken` and `AuditLog` are persisted. Peers are parsed from `WG_CONFIG_PATH` on demand.

## Tests

```
cd wgadmin_project
python manage.py test
```

## Deployment notes

- Run behind nginx or another proxy; serve static files from `staticfiles` after `collectstatic`.
- Start with gunicorn: `gunicorn wgadmin_project.wsgi:application --bind 0.0.0.0:8000`.
- Ensure the Django process can read/write `wg0.conf` and execute the helper scripts; consider sudoers rules for the scripts only.
