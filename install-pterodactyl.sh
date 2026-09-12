#!/bin/bash
# =====================================================================
# Pterodactyl Panel + Wings auto-installer
# Target  : Ubuntu 22.04/24.04 OR Debian 12/13 (fresh VPS/VM)
# Run     : curl -sSL <this-script-url> | sudo bash
# =====================================================================

set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------------------------------------------------------------- checks
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Run as root: sudo bash install-pterodactyl.sh"
  exit 1
fi

. /etc/os-release
case "$ID" in
  ubuntu)
    OS_IS_UBUNTU=1
    OS_IS_DEBIAN=0
    ;;
  debian)
    OS_IS_UBUNTU=0
    OS_IS_DEBIAN=1
    ;;
  *)
    echo "[!] This script only supports Ubuntu (22.04/24.04) or Debian (12/13)."
    echo "    Your OS ID = '$ID'"
    exit 1
    ;;
esac

DOMAIN=""
read -rp "Enter your domain (or press Enter to use the server IP): " DOMAIN
SERVER_IP=$(hostname -I | awk '{print $1}')

if [ -z "$DOMAIN" ]; then
  DOMAIN="$SERVER_IP"
fi

DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
ADMIN_EMAIL="admin@example.com"
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-12)

echo ""
echo "================================================================"
echo " Pterodactyl installer"
echo " OS            : $ID $(echo "$VERSION_ID")"
echo " Domain        : $DOMAIN"
echo " DB password   : $DB_PASS"
echo " Admin login   : $ADMIN_USER / $ADMIN_PASS"
echo "================================================================"
echo ""

# ---------------------------------------------------------------- update
echo "[1/9] Updating system..."
apt update -y
apt upgrade -y

echo "[2/9] Installing base packages..."
apt install -y curl wget git nginx mariadb-server redis-server \
               certbot python3-certbot-nginx cron
if [ "$OS_IS_UBUNTU" = "1" ]; then
  apt install -y software-properties-common
fi

# ------------------------------------------------------------------- php
echo "[3/9] Installing PHP..."
if [ "$OS_IS_UBUNTU" = "1" ]; then
  add-apt-repository -y ppa:ondrej/php
  apt update -y
  apt install -y php8.2 php8.2-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,redis,sqlite3,json,tokenizer}
else
  apt install -y php php-common php-cli php-gd php-mysql php-mbstring \
                 php-bcmath php-xml php-fpm php-curl php-zip php-redis php-sqlite3
fi

PHPVER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
FPM_SOCK="/run/php/php${PHPVER}-fpm.sock"

if ! command -v composer >/dev/null 2>&1; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

php -m | grep -qi openssl || { echo "[!] PHP OpenSSL extension missing."; exit 1; }

# ------------------------------------------------------------------- db
echo "[4/9] Setting up MariaDB..."
systemctl enable --now mariadb redis-server

mariadb -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "CREATE DATABASE panel;"
mariadb -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';"
mariadb -e "FLUSH PRIVILEGES;"

# ----------------------------------------------------------------- panel
echo "[5/9] Downloading Pterodactyl panel..."
useradd -r -d /var/www/pterodactyl -s /bin/bash pterodactyl || true
mkdir -p /var/www/pterodactyl
chown pterodactyl:pterodactyl /var/www/pterodactyl

cd /var/www/pterodactyl
if [ -d ".git" ]; then
  git pull origin v1.11.12 --force
else
  sudo -u pterodactyl git clone -b v1.11.12 https://github.com/pterodactyl/panel.git .
fi

sudo -u pterodactyl composer install --no-dev --optimize-autoloader --no-interaction

cp .env.example .env
sudo -u pterodactyl php artisan key:generate --force

sed -i "s|^APP_URL=.*|APP_URL=http://${DOMAIN}|" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=panel|" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

chown -R pterodactyl:pterodactyl /var/www/pterodactyl

echo "[6/9] Migrating database + creating admin user..."
sudo -u pterodactyl php artisan migrate --seed --force
sudo -u pterodactyl php artisan storage:link --force
sudo -u pterodactyl php artisan p:user:make \
  --email="${ADMIN_EMAIL}" \
  --username="${ADMIN_USER}" \
  --password="${ADMIN_PASS}" \
  --admin=1 \
  --no-interface

# ----------------------------------------------------------------- nginx
echo "[7/9] Configuring nginx..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/pterodactyl/public;
    index index.html index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\\.ht { deny all; }
    location ~ /\\.(?!well-known).* { deny all; }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx "php${PHPVER}-fpm"
systemctl restart nginx "php${PHPVER}-fpm"

# ------------------------------------------------------------------ cron
echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | crontab -u pterodactyl -

# ------------------------------------------------------------- firewall
echo "[8/9] Configuring firewall..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80
  ufw allow 443
  ufw allow 8080
  ufw allow 2022
  echo "y" | ufw enable
fi

# ----------------------------------------------------------------- wings
echo "[9/9] Installing Docker + Wings..."
curl -sSL https://get.docker.com/ | sh
systemctl enable --now docker

mkdir -p /etc/pterodactyl
curl -sL -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wings

# ----------------------------------------------------------------- done
echo ""
echo "================================================================="
echo " INSTALL COMPLETE"
echo "================================================================="
echo ""
echo " Panel URL     : http://${DOMAIN}"
echo " Admin login   : ${ADMIN_USER}"
echo " Admin email   : ${ADMIN_EMAIL}"
echo " Admin pasword : ${ADMIN_PASS}"
echo " DB password   : ${DB_PASS}"
echo ""
echo " Futures steps (in the panel browser UI):"
echo "  1. Admin Panel -> Nodes -> Create New -> fill Schema Options"
echo "  2. Click 'Generate' -> copy config.yml -> save to /etc/pterodactyl/config.yml"
echo "  3. Run:  systemctl start wings"
echo "  4. Nodes -> your node -> Allocations -> add game ports (e.g. 25565-25570)"
echo "  5. Servers -> Create New -> pick game -> assign node/port -> deploy"
echo ""
echo " Save the passwords above before closing this window!"
echo "================================================================="