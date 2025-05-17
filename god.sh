
#!/usr/bin/env bash
set -euo pipefail

# vm.sh: Configuración LEMP + WordPress + MySQL Replicación + LB
# Instalación y configuración en 5 máquinas: master, worker01-04

# --- VARIABLES EDITABLES ---
PASSWORD="1234"
DB_ROOT_PASS="$PASSWORD"
DB_REPL_PASS="$PASSWORD"
WP_DB_PASS="$PASSWORD"
WP_DB_USER="wordpress"
WP_DB_NAME="wordpress"
DB_REPL_USER="repl"

# Mapas de IPs según hostname:
# enp0s3 (NAT interna): 10.10.10.x
declare -A IP_MAP_ENP0S3=(
  [master]="10.10.10.100"
  [worker01]="10.10.10.101"
  [worker02]="10.10.10.102"
  [worker03]="10.10.10.103"
  [worker04]="10.10.10.104"
)
# enp0s8 (host): gestión/SSH y visualización distribuidos
declare -A IP_MAP_ENP0S8=(
  [master]="20.20.20.21"
  [worker01]="20.20.20.22"
  [worker02]="20.20.20.23"
  [worker03]="20.20.20.24"
  [worker04]="20.20.20.25"
)
NETMASK="24"

ROLE=$(hostname)

print_menu() {
  echo "Seleccione una opción:"
  echo "1) Automático (instala y configura según el hostname)"
  echo "2) Cambiar hostname y /etc/hosts"
  echo "3) Configurar NGINX Load Balancer (master)"
  echo "4) Instalar WordPress + Nginx site"
  echo "5) Configurar MySQL Master (worker03)"
  echo "6) Configurar MySQL Slave (worker04)"
  echo "0) Salir"
}

# Detectar socket PHP-FPM automáticamente
detect_php_sock() {
  find /run/php -type s -name '*.sock' | head -n1 || {
    echo "[ERROR] No se encontró socket de PHP-FPM en /run/php"
    exit 1
  }
}

set_static_ip() {
  IP3="${IP_MAP_ENP0S3[$ROLE]:-}"
  IP8="${IP_MAP_ENP0S8[$ROLE]:-}"
  [[ -z "$IP3" || -z "$IP8" ]] && { echo "[ERROR]  cat > /etc/netplan/50-static.yaml <<EOF
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: no
      addresses:
        - ${IP3}/${NETMASK}
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    enp0s8:
      dhcp4: no
      addresses:
        - ${IP8}/${NETMASK}
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
      routes:
        - to: 0.0.0.0/0
          via: 20.20.20.1
          metric: 100
EOF
  netplan apply
  echo "[INFO] IP configuradas: enp0s3=$IP3 (NAT), enp0s8=$IP8 (host)"
}

install_common() {
  echo "[INFO] Actualizando e instalando paquetes comunes"
  apt update && apt install -y nginx mysql-server \
    php-fpm php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl \
    wget unzip
}

setup_mysql_master() {
  echo "[worker03] Configurando MySQL Master"
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=1
log_bin=mysql-bin
binlog_do_db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  mysql -uroot -p"${DB_ROOT_PASS}" -e "
    CREATE USER IF NOT EXISTS '${DB_REPL_USER}'@'%' IDENTIFIED BY '${DB_REPL_PASS}';
    GRANT REPLICATION SLAVE ON *.* TO '${DB_REPL_USER}'@'%';
    CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME};
    CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '${WP_DB_PASS}';
    GRANT ALL ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'%';
    FLUSH PRIVILEGES;"
}

setup_mysql_slave() {
  echo "[worker04] Configurando MySQL Slave"
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=2
replicate-do-db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  MASTER_LOG=$(mysql -uroot -p"${DB_ROOT_PASS}" -h"${IP_MAP_ENP0S3[worker03]}" \
    -e "SHOW MASTER STATUS\G" | awk '/File:/ {f=$2} /Position:/ {p=$2} END{print f, p}')
  read FILE POS <<< "$MASTER_LOG"
  mysql -uroot -p"${DB_ROOT_PASS}" -e "
    CHANGE MASTER TO MASTER_HOST='${IP_MAP_ENP0S3[worker03]}',
                   MASTER_USER='${DB_REPL_USER}',
                   MASTER_PASSWORD='${DB_REPL_PASS}',
                   MASTER_LOG_FILE='${FILE}',
                   MASTER_LOG_POS=${POS};
    START SLAVE;"
}

setup_wordpress() {
  echo "[${ROLE}] Instalando WordPress"
  PHP_SOCK=$(detect_php_sock)
  mkdir -p /var/www/wordpress
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
  tar xzvf /tmp/wp.tar.gz -C /var/www/wordpress --strip-components=1
  chown -R www-data:www-data /var/www/wordpress

  # Configurar wp-config.php
  cp /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php
  sed -i "s/database_name_here/${WP_DB_NAME}/" /var/www/wordpress/wp-config.php
  sed -i "s/username_here/${WP_DB_USER}/" /var/www/wordpress/wp-config.php
  sed -i "s/password_here/${WP_DB_PASS}/" /var/www/wordpress/wp-config.php
  sed -i "s/localhost/${IP_MAP_ENP0S8[worker03]}/" /var/www/wordpress/wp-config.php

  # Configurar sitio Nginx para WordPress
  cat > /etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 80;
    server_name ${IP_MAP_ENP0S8[$ROLE]};
    root /var/www/wordpress;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

setup_load_balancer() {
  echo "[master] Configurando Load Balancer"
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backend {
  server ${IP_MAP_ENP0S8[worker01]};
  server ${IP_MAP_ENP0S8[worker02]};
}
server {
  listen 80;
  server_name ${IP_MAP_ENP0S8[master]};
  location / {
    proxy_pass http://backend;
    proxy_set_header Host \$host;
  }
}
EOF
  ln -sf /etc/nginx/sites-available/lb.conf /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
}

change_hostname() {
  echo "Selecciona el nuevo hostname:"
  select NEWHOST in master worker01 worker02 worker03 worker04; do
    if [[ -n "$NEWHOST" ]]; then
      hostnamectl set-hostname "$NEWHOST"
      sed -i "/127\.0\.1\.1/c\127.0.1.1 $NEWHOST" /etc/hosts
      echo "[INFO] Hostname actualizado a $NEWHOST"
      break
    else
      echo "Opción inválida"
    fi
  done
}

main() {
  print_menu
  read -rp "> " opt
  case "$opt" in
    1)
      set_static_ip
      install_common
      case "$ROLE" in
        worker03) setup_mysql_master ;;
        worker04) setup_mysql_slave ;;
        worker01|worker02) setup_wordpress ;;
        master) setup_load_balancer ;;
        *) echo "[ERROR] Rol desconocido: $ROLE"; exit 1 ;;
      esac ;;
    2) change_hostname ;;
    3) setup_load_balancer ;;
    4) setup_wordpress ;;
    5) setup_mysql_master ;;
    6) setup_mysql_slave ;;
    0) exit 0 ;;
    *) echo "Opción inválida"; exit 1 ;;
  esac
  echo "[${ROLE}] Tarea completada"
}

main

