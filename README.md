# WireGuard Admin - Django 5 + Tailwind CSS 4

A web-based admin interface for managing WireGuard VPN peers. This application provides a secure, user-friendly way to create, manage, enable/disable, and delete WireGuard clients directly from your browser.

## Features

- **Peer Management**: Create, enable/disable, and delete WireGuard clients
- **QR Code Generation**: Automatically generates QR codes for mobile client setup
- **Secure Download Links**: Time-limited, one-time download links for client configurations
- **Audit Logging**: Track all changes with user attribution
- **Real-time Status**: View live connection status, transfer statistics, and last handshake times
- **Staff-only Access**: Protected management interface (requires Django staff/admin user)

## Table of Contents

1. [Requirements](#requirements)
2. [Project Structure](#project-structure)
3. [Configuration](#configuration)
4. [Installation on Fresh Debian 12 Server](#installation-on-fresh-debian-12-server)
5. [Production Deployment](#production-deployment)
6. [Development Setup](#development-setup)
7. [Scripts Reference](#scripts-reference)
8. [Security Considerations](#security-considerations)
9. [Troubleshooting](#troubleshooting)

---

## Requirements

### System Requirements

- **Operating System**: Debian 12 (Bookworm) or Ubuntu 22.04+
- **Python**: 3.11+
- **Privileges**: Root access or sudo privileges
- **Network**: Static IP or DNS name for WireGuard endpoint

### Required System Packages

The setup script will install these automatically:

- `wireguard` & `wireguard-tools`
- `python3`, `python3-pip`, `python3-venv`
- `nginx`
- `qrencode`
- `git`, `curl`

### Python Dependencies

See [`requirements.txt`](requirements.txt):

```
Django>=5.0,<5.1
qrcode>=7.4
Pillow>=10.0
gunicorn>=21.0
```

---

## Project Structure

```
wireguard_server_admin/
├── README.md                          # This file
├── requirements.txt                   # Python dependencies
├── wgadmin_project/                   # Django project root
│   ├── manage.py                      # Django management script
│   ├── wgadmin_project/               # Project settings
│   │   ├── settings.py                # Django configuration
│   │   ├── urls.py                    # URL routing
│   │   └── wsgi.py                    # WSGI entry point
│   ├── wgadmin/                       # Main application
│   │   ├── views.py                   # View functions
│   │   ├── models.py                  # Database models
│   │   ├── forms.py                   # Form definitions
│   │   ├── services/wireguard.py      # WireGuard service layer
│   │   └── templates/                 # HTML templates
│   ├── scripts/                       # Bash management scripts
│   │   ├── wg_first_start.sh          # Initial server setup
│   │   ├── deploy.sh                  # Deployment/update script
│   │   ├── wg_create_peer.sh          # Create new peer
│   │   ├── wg_delete_peer.sh          # Delete peer
│   │   ├── wg_toggle_peer.sh          # Enable/disable peer
│   │   ├── wg_read_config.sh          # Read WireGuard config
│   │   └── wg_generate_qr.sh          # Generate QR code
│   └── deploy/                        # Deployment configurations
│       ├── gunicorn.service           # Systemd service file
│       ├── nginx.conf                 # Nginx configuration
│       └── .env.example               # Environment template
└── tailwind.config.js                 # Tailwind CSS config (CDN mode)
```

---

## Configuration

### Environment Variables

Create a `.env` file (see [`deploy/.env.example`](wgadmin_project/deploy/.env.example)):

| Variable | Description | Default |
|----------|-------------|---------|
| `DJANGO_SECRET_KEY` | Django secret key (**required in production**) | unsafe-secret-key |
| `DJANGO_DEBUG` | Enable debug mode | `true` |
| `DJANGO_ALLOWED_HOSTS` | Comma-separated allowed hosts | `localhost,127.0.0.1` |
| `WG_CONFIG_PATH` | WireGuard config file path | `/etc/wireguard/wg0.conf` |
| `WG_INTERFACE` | WireGuard interface name | `wg0` |
| `WG_SCRIPTS_DIR` | Scripts directory path | `<project>/scripts` |
| `WG_CLIENT_CONFIG_DIR` | Client config storage | `/etc/wireguard/client` |
| `WG_PUBLIC_CONF_DIR` | Downloadable configs | `/var/www/wireguard/conf` |
| `WG_QR_DIR` | QR code storage | `/var/www/wireguard/qr` |
| `WG_ENDPOINT_PORT` | WireGuard port | `51830` |
| `WG_DNS` | DNS for client configs | `1.1.1.1` |
| `WG_USE_SUDO` | Use sudo for scripts | `true` |
| `TZ` | Timezone | `UTC` |

### Generate Secret Key

```bash
python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'
```

---

## License

This project is licensed under the MIT License. See `LICENSE` for details.

---

## Installation on Fresh Debian 12/13 Server

### Quick Start (Automated)

```bash
sudo apt update && sudo apt upgrade -y

# 1. Clone the repository and set ownership
sudo mkdir -p /var/www
sudo git clone https://github.com/Prizrak4416/wgadmin.git /var/www/wgadmin
cd /var/www/wgadmin

# 2. Run the initial setup script (as root)
sudo bash wgadmin_project/scripts/wg_first_start.sh --user www-admin --interface wg0

# 3. Create virtual environment and install dependencies
sudo -u www-admin python3 -m venv .venv
sudo -u www-admin /var/www/wgadmin/.venv/bin/pip install -r requirements.txt

# 4. Configure environment
cp wgadmin_project/deploy/.env.example /var/www/wgadmin/.env
nano /var/www/wgadmin/.env

# 5. Initialize Django
cd wgadmin_project
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py migrate
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py createsuperuser
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py collectstatic --noinput

# 6. Set up systemd service
sudo chown -R www-admin:wgadmin /var/www/wgadmin
sudo find /var/www/wgadmin -type d -exec chmod 2770 {} \;
sudo find /var/www/wgadmin -type f -exec chmod 660 {} \;
sudo chmod 770 /var/www/wgadmin/.venv/bin/gunicorn /var/www/wgadmin/.venv/bin/python

sudo cp deploy/gunicorn.service /etc/systemd/system/wgadmin.service
sudo mkdir -p /var/log/wgadmin
sudo chown www-admin:wgadmin /var/log/wgadmin
sudo systemctl daemon-reload
sudo systemctl enable --now wgadmin

# 7. Configure nginx
sudo cp deploy/nginx.conf /etc/nginx/sites-available/wgadmin
sudo ln -s /etc/nginx/sites-available/wgadmin /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
# Edit /etc/nginx/sites-available/wgadmin - update server_name and SSL paths
sudo nginx -t
sudo systemctl reload nginx

# final
sudo chown -R root:wgadmin /var/www/wgadmin/wgadmin_project/scripts
sudo chmod -R 710 /var/www/wgadmin/wgadmin_project/scripts
```


### Service Management

```bash
# Application status
sudo systemctl status wgadmin

# Restart application
sudo systemctl restart wgadmin

# View logs
sudo journalctl -u wgadmin -f
tail -f /var/log/wgadmin/error.log

# Nginx logs
tail -f /var/log/nginx/wgadmin_access.log
tail -f /var/log/nginx/wgadmin_error.log

# WireGuard status
sudo wg show wg0
```

### Log Locations

| Component | Log Location |
|-----------|--------------|
| Gunicorn access | `/var/log/wgadmin/access.log` |
| Gunicorn errors | `/var/log/wgadmin/error.log` |
| Nginx access | `/var/log/nginx/wgadmin_access.log` |
| Nginx errors | `/var/log/nginx/wgadmin_error.log` |
| Scripts | `/var/www/wgadmin/wgadmin_project/scripts/log.txt` |
| Systemd | `journalctl -u wgadmin` |

### Scheduled Tasks

Add to crontab for automatic token cleanup:

```bash
crontab -e
```

Add:

```
*/15 * * * * /var/www/wgadmin/.venv/bin/python /var/www/wgadmin/wgadmin_project/manage.py cleanup_tokens
```

---
