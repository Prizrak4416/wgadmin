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

## Installation on Fresh Debian 12 Server

### Quick Start (Automated)

```bash
# 1. Clone the repository and set ownership
sudo mkdir -p /var/www
sudo git clone https://github.com/your-username/wireguard_server_admin.git /var/www/wgadmin
cd /var/www/wgadmin

# 2. Run the initial setup script (as root)
sudo bash wgadmin_project/scripts/wg_first_start.sh --user www-admin --interface wg0

# 3. Create virtual environment and install dependencies
sudo -u www-admin python3 -m venv .venv
source .venv/bin/activate
sudo -u www-admin /var/www/wgadmin/.venv/bin/pip install -r requirements.txt

# 4. Configure environment
cp wgadmin_project/deploy/.env.example /var/www/wgadmin/.env
nano /var/www/wgadmin/.env  # Edit with your settings

# 5. Initialize Django
cd wgadmin_project
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py migrate
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py createsuperuser
sudo -u www-admin /var/www/wgadmin/.venv/bin/python manage.py collectstatic --noinput

# 6. Set up systemd service
sudo chown -R www-admin:wgadmin /var/www/wgadmin  # replace if you use another user/group
sudo cp deploy/gunicorn.service /etc/systemd/system/wgadmin.service
sudo mkdir -p /var/log/wgadmin
sudo chown www-admin:wgadmin /var/log/wgadmin
sudo systemctl daemon-reload
sudo systemctl enable --now wgadmin

# 7. Configure nginx
sudo cp deploy/nginx.conf /etc/nginx/sites-available/wgadmin
sudo ln -s /etc/nginx/sites-available/wgadmin /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default  # Remove default site
# Edit /etc/nginx/sites-available/wgadmin - update server_name and SSL paths
sudo nginx -t
sudo systemctl reload nginx

# final
sudo chown -R root:wgadmin /var/www/wgadmin/wgadmin_project/scripts
sudo chmod -R 710 /var/www/wgadmin/wgadmin_project/scripts
```

### Step-by-Step Manual Installation

#### Step 1: System Preparation

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y \
    wireguard wireguard-tools \
    python3 python3-pip python3-venv \
    nginx git curl qrencode

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

#### Step 2: Create System User/Group

```bash
# Create wgadmin group
sudo groupadd -r wgadmin

# Add www-admin to the group (or your application user)
sudo usermod -aG wgadmin www-admin
```

#### Step 3: Clone Repository

```bash
sudo mkdir -p /var/www/wgadmin
sudo git clone https://github.com/your-username/wireguard_server_admin.git /var/www/wgadmin
sudo chown -R www-admin:wgadmin /var/www/wgadmin
```

#### Step 4: WireGuard Setup

```bash
# Create directories
sudo mkdir -p /etc/wireguard/client /var/www/wireguard/{conf,qr}

# Generate server keys
wg genkey | sudo tee /etc/wireguard/server_private.key | wg pubkey | sudo tee /etc/wireguard/server_public.key

# Create WireGuard config
sudo nano /etc/wireguard/wg0.conf
```

Example `wg0.conf`:

```ini
[Interface]
PrivateKey = <your-server-private-key>
Address = 10.0.0.1/24
ListenPort = 51830
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
```

#### Step 5: Set Permissions

```bash
# WireGuard directories
sudo chown root:wgadmin /etc/wireguard /etc/wireguard/wg0.conf
sudo chmod 750 /etc/wireguard
sudo chmod 640 /etc/wireguard/wg0.conf

# Client directories
sudo chown -R root:wgadmin /etc/wireguard/client /var/www/wireguard
sudo chmod 770 /etc/wireguard/client /var/www/wireguard/conf /var/www/wireguard/qr

# Scripts
sudo chown root:wgadmin /var/www/wgadmin/wgadmin_project/scripts/*.sh
sudo chmod 750 /var/www/wgadmin/wgadmin_project/scripts/*.sh
```

#### Step 6: Configure Sudoers

Create `/etc/sudoers.d/wgadmin`:

```bash
sudo visudo -f /etc/sudoers.d/wgadmin
```

Add these lines:

```
%wgadmin ALL=(root) NOPASSWD: /bin/systemctl restart wg-quick@wg0.service
%wgadmin ALL=(root) NOPASSWD: /usr/bin/wg show wg0 *
%wgadmin ALL=(root) NOPASSWD: /var/www/wgadmin/wgadmin_project/scripts/wg_*.sh *
```

#### Step 7: Python Environment

```bash
cd /var/www/wgadmin
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

#### Step 8: Django Configuration

```bash
# Create .env file
cp wgadmin_project/deploy/.env.example .env
nano .env  # Configure all settings

# Run migrations and create admin user
cd wgadmin_project
python manage.py migrate
python manage.py createsuperuser
python manage.py collectstatic --noinput
```

#### Step 9: Systemd Service

```bash
# Copy service file
sudo cp deploy/gunicorn.service /etc/systemd/system/wgadmin.service

# Create log directory
sudo mkdir -p /var/log/wgadmin
sudo chown www-admin:wgadmin /var/log/wgadmin

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable wgadmin
sudo systemctl start wgadmin

# Check status
sudo systemctl status wgadmin
```

#### Step 10: Nginx Configuration

```bash
# Copy config
sudo cp deploy/nginx.conf /etc/nginx/sites-available/wgadmin

# Edit for your domain
sudo nano /etc/nginx/sites-available/wgadmin

# Enable site
sudo ln -sf /etc/nginx/sites-available/wgadmin /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload
sudo nginx -t
sudo systemctl reload nginx
```

#### Step 11: SSL Certificate (Let's Encrypt)

```bash
# Install certbot
sudo apt install -y certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d your-domain.com

# Auto-renewal is configured automatically
```

#### Step 12: Start WireGuard

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo wg show wg0
```

#### Step 13: Firewall Configuration

```bash
# If using UFW
sudo ufw allow 51830/udp   # WireGuard
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable
```

---

## Production Deployment

### Updating the Application

Use the deploy script:

```bash
cd /var/www/wgadmin
git pull
source .venv/bin/activate
./wgadmin_project/scripts/deploy.sh --update-deps --restart
```

Or manually:

```bash
cd /var/www/wgadmin
git pull
source .venv/bin/activate
pip install -r requirements.txt
cd wgadmin_project
python manage.py migrate
python manage.py collectstatic --noinput
sudo systemctl restart wgadmin
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

## Development Setup

### Local Development

```bash
# Clone repository
git clone https://github.com/your-username/wireguard_server_admin.git
cd wireguard_server_admin

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate  # Linux/macOS
# Or: .venv\Scripts\activate  # Windows

# Install dependencies
pip install -r requirements.txt

# Set environment variables
export DJANGO_DEBUG=true
export DJANGO_SECRET_KEY=dev-secret-key
export WG_USE_SUDO=false  # Disable sudo for local development

# Run migrations
cd wgadmin_project
python manage.py migrate
python manage.py createsuperuser

# Start development server
python manage.py runserver 0.0.0.0:8000
```

### Tailwind CSS (CDN Mode)

This project uses Tailwind CSS via CDN. No build step required. For custom builds:

```bash
npm install -D tailwindcss
npx tailwindcss -i wgadmin/static/wgadmin/css/input.css \
                -o wgadmin/static/wgadmin/css/tailwind.css --watch
```

### Running Tests

```bash
cd wgadmin_project
python manage.py test
```

---

## Scripts Reference

All scripts are in [`wgadmin_project/scripts/`](wgadmin_project/scripts/) and output JSON:

### wg_first_start.sh

Initial server provisioning (run once as root):

```bash
sudo ./wg_first_start.sh --user www-admin --interface wg0
```

### wg_create_peer.sh

Create a new WireGuard peer:

```bash
sudo ./wg_create_peer.sh --name client1 --allowed-ips 0.0.0.0/0
```

### wg_delete_peer.sh

Delete a peer by name or public key:

```bash
sudo ./wg_delete_peer.sh --id client1
```

### wg_toggle_peer.sh

Enable or disable a peer:

```bash
sudo ./wg_toggle_peer.sh --enable --id client1
sudo ./wg_toggle_peer.sh --disable --id client1
```

### wg_generate_qr.sh

Generate QR code for a client config:

```bash
sudo ./wg_generate_qr.sh --id client1
```

### wg_read_config.sh

Read WireGuard configuration:

```bash
sudo ./wg_read_config.sh
```

### deploy.sh

Deploy or update the application:

```bash
./deploy.sh --update-deps --restart
```

---

## Security Considerations

### Important Security Settings

Ensure these are set correctly in production (`.env`):

```ini
DJANGO_DEBUG=false
DJANGO_SECRET_KEY=<strong-random-key>
DJANGO_ALLOWED_HOSTS=your-domain.com
```

### Checklist

- [ ] `DEBUG=false` in production
- [ ] Strong, unique `SECRET_KEY`
- [ ] HTTPS enabled (Let's Encrypt)
- [ ] Firewall configured (only 22, 80, 443, WireGuard port)
- [ ] Regular system updates
- [ ] Log monitoring
- [ ] Backup strategy for `/etc/wireguard/` and database

### Nginx Security Headers

The provided nginx config includes:

- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection: 1; mode=block`
- HSTS (uncomment after confirming HTTPS)

---

## Troubleshooting

### Common Issues

#### "Permission denied" when running scripts

```bash
# Verify user is in wgadmin group
groups www-admin

# Re-login or use newgrp
newgrp wgadmin

# Check sudoers
sudo visudo -cf /etc/sudoers.d/wgadmin
```

#### WireGuard interface not starting

```bash
# Check config syntax
sudo wg-quick strip wg0

# View service logs
sudo journalctl -u wg-quick@wg0 -e

# Check interface exists
ip link show wg0
```

#### Gunicorn socket not found

```bash
# Check service status
sudo systemctl status wgadmin

# Verify socket exists
ls -la /run/gunicorn/

# Check RuntimeDirectory in service file
```

#### 502 Bad Gateway

```bash
# Check if gunicorn is running
sudo systemctl status wgadmin

# Check socket permissions
ls -la /run/gunicorn/wgadmin.sock

# Test gunicorn directly
cd /var/www/wgadmin/wgadmin_project
/var/www/wgadmin/.venv/bin/gunicorn wgadmin_project.wsgi:application --bind 127.0.0.1:8000
```

### Getting Help

1. Check logs (see [Log Locations](#log-locations))
2. Run Django check: `python manage.py check --deploy`
3. Test WireGuard: `sudo wg show`
4. Verify permissions: `ls -la /etc/wireguard/`

---

## License

MIT License - see LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Submit a pull request

---

*Last updated: December 2024*
