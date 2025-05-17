
#!/usr/bin/env bash
set -euo pipefail

PASSWORD="1234"
DB_ROOT_PASS="$PASSWORD"
DB_REPL_PASS="$PASSWORD"
WP_DB_PASS="$PASSWORD"
WP_DB_USER="wordpress"
WP_DB_NAME="wordpress"
DB_REPL_USER="repl"
NETMASK="24"
ROLE=$(hostnamectl hostname)

# Mapas de IPs según hostname
declare -A IP_MAP_ENP0S3=(
  [master]="10.10.10.100"
  [worker01]="10.10.10.101"
  [worker02]="10.10.10.102"
  [worker03]="10.10.10.103"
  [worker04]="10.10.10.104"
)
declare -A IP_MAP_ENP0S8=(
  [master]="20.20.20.21"
  [worker01]="20.20.20.22"
  [worker02]="20.20.20.23"
  [worker03]="20.20.20.24"
  [worker04]="20.20.20.25"
)

print_menu() {
  echo "Seleccione una opción:"
  echo "1) Automático"
  echo "2) Cambiar hostname"
  echo "3) Configurar LB (master)"
  echo "4) Instalar WP"
  echo "5) Configurar MySQL Master"
  echo "6) Configurar MySQL Slave"
  echo "0) Salir"
}

detect_php_sock() {
  find /run/php -type s -name '*.sock' | head -n1 || { echo "No socket PHP-FPM"; exit 1; }
}

set_static_ip() {
  cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.backup
  local IP3=${IP_MAP_ENP0S3[$ROLE]:-}
  local IP8=${IP_MAP_ENP0S8[$ROLE]:-}
  [[ -z $IP3 || -z $IP8 ]] && { echo "Rol $ROLE sin IP"; exit 1; }
  cat > /etc/netplan/50-cloud-init.yaml <<EOF
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: no
      addresses:
        - ${IP3}/${NETMASK}
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
      routes:
        - to: 0.0.0.0/0
          via: 10.10.10.1
          metric: 100
    enp0s8:
      dhcp4: no
      addresses:
        - ${IP8}/${NETMASK}
      routes:
        - to: 0.0.0.0/0
          via: 20.20.20.1
          metric: 200
EOF
  netplan apply
  echo "IPs: enp0s3=$IP3, enp0s8=$IP8"
}

install_common() {
  apt update && apt install -y nginx mysql-server \
    php-fpm php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl wget unzip
}

setup_mysql_master() {
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=1
log_bin=mysql-bin
binlog_do_db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  mysql -uroot -p"$DB_ROOT_PASS" -e "
    CREATE USER IF NOT EXISTS '${DB_REPL_USER}'@'%' IDENTIFIED BY '${DB_REPL_PASS}';
    GRANT REPLICATION SLAVE ON *.* TO '${DB_REPL_USER}'@'%';
    CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME};
    CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '${WP_DB_PASS}';
    GRANT ALL ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'%';
    FLUSH PRIVILEGES;"
}

setup_mysql_slave() {
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=2
replicate-do-db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  local ml=$(mysql -uroot -p"$DB_ROOT_PASS" -h"${IP_MAP_ENP0S3[worker03]}" -e "SHOW MASTER STATUS\G")
  local file=$(echo "$ml" | awk '/File:/ {print $2}')
  local pos=$(echo "$ml" | awk '/Position:/ {print $2}')
  mysql -uroot -p"$DB_ROOT_PASS" -e "
    CHANGE MASTER TO MASTER_HOST='${IP_MAP_ENP0S3[worker03]}', MASTER_USER='${DB_REPL_USER}', MASTER_PASSWORD='${DB_REPL_PASS}', MASTER_LOG_FILE='${file}', MASTER_LOG_POS=${pos}; START SLAVE;"
}

setup_wordpress() {
  local sock=$(detect_php_sock)
  mkdir -p /var/www/wordpress
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
  tar xz -C /var/www/wordpress --strip-components=1 -f /tmp/wp.tar.gz
  chown -R www-data:www-data /var/www/wordpress
  cp /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php
  sed -i "s/database_name_here/${WP_DB_NAME}/; s/username_here/${WP_DB_USER}/; s/password_here/${WP_DB_PASS}/; s/localhost/${IP_MAP_ENP0S8[worker03]}/" /var/www/wordpress/wp-config.php
  cat > /etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 80;
    server_name ${IP_MAP_ENP0S8[$ROLE]};
    root /var/www/wordpress;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:${sock}; }
    location ~ /\.ht { deny all; }
}
EOF
  ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

setup_load_balancer() {
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backend {
  server ${IP_MAP_ENP0S8[worker01]};
  server ${IP_MAP_ENP0S8[worker02]};
}
server {
  listen 80;
  server_name ${IP_MAP_ENP0S8[master]};
  location / { proxy_pass http://backend; proxy_set_header Host \$host; }
}
EOF
  ln -sf /etc/nginx/sites-available/lb.conf /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

change_hostname() {
  select h in master worker01 worker02 worker03 worker04; do
    [[ -n $h ]] && { hostnamectl set-hostname $h; sed -i "/127.0.1.1/c\127.0.1.1 $h" /etc/hosts; break; }
  done
}

main() {
  print_menu; read -rp "> " o
  case $o in
    1) set_static_ip; install_common; case $ROLE in worker03) setup_mysql_master;; worker04) setup_mysql_slave;; worker01|worker02) setup_wordpress;; master) setup_load_balancer;; esac;;
    2) change_hostname;;
    3) setup_load_balancer;;
    4) setup_wordpress;;
    5) setup_mysql_master;;
    6) setup_mysql_slave;;
    0) exit;;
  esac
  echo OK
}

main

