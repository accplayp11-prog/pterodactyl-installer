#!/bin/bash
# =====================================================================
# Pterodactyl Panel + Wings auto-installer
# Target  : Ubuntu 22.04/24.04 OR Debian 12/13
#           Works with or without systemd (LXC/container friendly)
# Run     : curl -sSL https://raw.githubusercontent.com/accplayp11-prog/pterodactyl-installer/main/install-pterodactyl.sh | sudo bash
# =====================================================================

set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------------------------------------------------------------- checks
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Run as root."
  exit 1
fi

. /etc/os-release
case "$ID" in
  ubuntu) ;;
  debian) ;;
  *)
    echo "[!] This script only supports Ubuntu (22.04/24.04) or Debian (12/13)."
    echo "    Your OS ID = '$ID'"
    exit 1
    ;;
esac

# systemd running or container without systemd?
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
  SYSTEMD=1
else
  SYSTEMD=0
  echo "[i] systemd not detected (PID1 = $(ps -p 1 -o comm= 2>/dev/null)). Using 'service' commands."
fi

svc() { # svc <start|stop|restart|enable|disable> <service>
  local action=$1 name=$2
  if [ "$action" = "enable" ]; then
    if [ "$SYSTEMD" = "1" ]; then systemctl enable "$name"; else update-rc.d "$name" defaults; fi
  elif [ "$action" = "disable" ]; then
    if [ "$SYSTEMD" = "1" ]; then systemctl disable "$name"; else update-rc.d "$name" disable; fi
  else
    if [ "$SYSTEMD" = "1" ]; then systemctl "$action" "$name"; else service "$name" "$action"; fi
  fi
}

# -------------------------------------------------------------- config
if [ -t 0 ]; then
  read -rp "Enter your domain (or press Enter to use the server IP): " DOMAIN
else
  echo "[i] Non-interactive run -> using server IP as domain."
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
[ -z "$DOMAIN" ] && DOMAIN="$SERVER_IP"
[ -z "$SERVER_IP" ] && SERVER_IP="$DOMAIN"

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
if [ "$ID" = "ubuntu" ]; then
  apt install -y software-properties-common
fi

# ------------------------------------------------------------------- php
echo "[3/9] Installing PHP..."
if [ "$ID" = "ubuntu" ]; then
  add-apt-repository -y ppa:ondrej/php
  apt update -y
  apt install -y php8.2 php8.2-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,redis,sqlite3,json,tokenizer}
else
  apt install -y php-cli php-common php-fpm php-gd php-mysql php-mbstring \
                 php-bcmath php-xml php-curl php-zip php-redis php-sqlite3
fi

PHPVER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
FPM_SOCK="/run/php/php${PHPVER}-fpm.sock"

if ! command -v composer >/dev/null 2>&1; then
  echo "[i] Installing Composer..."
  apt install -y composer
fi

php -m | grep -qi openssl || { echo "[!] PHP OpenSSL extension missing."; exit 1; }

# ------------------------------------------------------------------- db
echo "[4/9] Setting up MariaDB..."
if [ "$SYSTEMD" = "1" ]; then
  systemctl start mariadb 2>/dev/null || svc start mariadb || true
else
  echo "[i] No systemd -> starting mariadbd directly..."
  mkdir -p /run/mysqld
  chown mysql:mysql /run/mysqld 2>/dev/null || true
  if [ -d /var/lib/mysql/mysql ]; then
    echo "[i] MariaDB data dir already initialized."
  else
    echo "[i] Initializing MariaDB data dir..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
    chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true
  fi
  if ! pgrep -x mariadbd >/dev/null && ! pgrep -x mysqld >/dev/null; then
    mkdir -p /var/log/mysql
    chown -R mysql:mysql /var/log/mysql 2>/dev/null || true
    nohup mariadbd --user=mysql --log-error=/var/log/mysql/error.log >/dev/null 2>&1 &
    echo "[i] mariadbd launched (log: /var/log/mysql/error.log)"
  fi
fi
svc start redis-server || true

for i in $(seq 1 30); do
  mariadb -e "SELECT 1" >/dev/null 2>&1 && break
  echo "[i] waiting for MariaDB... ($i/30)"
  sleep 2
done

if ! mariadb -e "SELECT 1" >/dev/null 2>&1; then
  echo "[!] MariaDB failed to start. Last log lines:"
  tail -n 20 /var/log/mysql/error.log 2>/dev/null || true
  exit 1
fi

mariadb -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "ALTER USER 'pterodactyl'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "CREATE DATABASE IF NOT EXISTS panel;"
mariadb -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';"
mariadb -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';"
mariadb -e "FLUSH PRIVILEGES;"

# ----------------------------------------------------------------- panel
echo "[5/9] Downloading Pterodactyl panel..."
useradd -r -d /var/www/pterodactyl -s /bin/bash pterodactyl 2>/dev/null || true
mkdir -p /var/www/pterodactyl
chown pterodactyl:pterodactyl /var/www/pterodactyl

cd /var/www/pterodactyl
if [ -f "artisan" ]; then
  echo "[i] Panel already installed, keeping existing checkout."
else
  rm -rf .git 2>/dev/null || true
  sudo -u pterodactyl git clone -b v1.15.1 https://github.com/pterodactyl/panel.git .
fi

sudo -u pterodactyl composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-req=php

cp .env.example .env
chown pterodactyl:pterodactyl .env
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
  --admin=1 --overwrite \
  --no-interface

# ----------------------------------------------------------------- nginx
echo "[7/9] Configuring nginx..."
if [ -d /etc/apache2 ]; then
  echo "[i] Stopping/disabling apache2 (conflicts with nginx on port 80)..."
  svc stop apache2 2>/dev/null || true
  svc disable apache2 2>/dev/null || true
fi

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
svc enable nginx
svc enable "php${PHPVER}-fpm"
svc restart nginx
svc restart "php${PHPVER}-fpm"

# ------------------------------------------------------------------ cron
echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | crontab -u pterodactyl -
svc enable cron
svc start cron || true

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
curl -sSL https://get.docker.com/ | sh || true

if [ "$SYSTEMD" = "1" ]; then
  systemctl enable --now docker 2>/dev/null || svc start docker
else
  svc enable docker 2>/dev/null || true
  svc start docker 2>/dev/null || true
fi

mkdir -p /etc/pterodactyl
curl -sL -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod +x /usr/local/bin/wings

if [ "$SYSTEMD" = "1" ]; then
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
  svc enable wings
else
  cat > /etc/init.d/wings <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          wings
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       Pterodactyl Wings Daemon
### END INIT INFO

DAEMON=/usr/local/bin/wings
PIDFILE=/var/run/wings.pid

case "$1" in
  start)
    start-stop-daemon --start --background --make-pidfile \
      --pidfile "$PIDFILE" --exec "$DAEMON"
    ;;
  stop)
    start-stop-daemon --stop --pidfile "$PIDFILE"
    ;;
  restart)
    "$0" stop 2>/dev/null
    "$0" start
    ;;
  status)
    start-stop-daemon --status --pidfile "$PIDFILE"
    exit $?
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x /etc/init.d/wings
  svc enable wings || true
fi

if ! pgrep -x dockerd >/dev/null; then
  echo ""
  echo "[!] WARNING: Docker daemon is not running."
  echo "    If this is an unprivileged LXC/container, game servers cannot run."
  echo "    You may need a privileged container or a real VM."
fi

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
echo " Future steps (in the panel browser UI):"
echo "  1. Admin Panel -> Nodes -> Create New -> fill Schema Options"
echo "  2. Click 'Generate' -> copy config.yml -> save to /etc/pterodactyl/config.yml"
echo "  3. Start Wings:  service wings start   (or: systemctl start wings)"
echo "  4. Nodes -> your node -> Allocations -> add game ports (e.g. 25565-25570)"
echo "  5. Servers -> Create New -> pick game -> assign node/port -> deploy"
echo ""
echo " Save the passwords above before closing this window!"
echo "================================================================="