
#!/usr/bin/env bash
set -euo pipefail

# vm.sh: Configuración LEMP + WordPress + MySQL Replicación + LB
# Soporta instalación y configuración en 5 máquinas

# --- VARIABLES EDITABLES ---
PASSWORD="1234"
DB_ROOT_PASS="$PASSWORD"
DB_REPL_PASS="$PASSWORD"
WP_DB_PASS="$PASSWORD"
WP_DB_USER="wpuser"
WP_DB_NAME="wordpress"
DB_REPL_USER="repl"

# Mapeo de IPs por hostname para interfaces
# enp0s8: red de gestión/storage (20.20.20.x)
declare -A IP_MAP_ENP0S8=(
  [web-lb]="20.20.20.21"
  [web01]="20.20.20.22"
  [web02]="20.20.20.23"
  [db-master]="20.20.20.24"
  [db-slave1]="20.20.20.25"
  [storage]="20.20.20.26"
)
# enp0s3: red de aplicación (10.10.10.x)
declare -A IP_MAP_ENP0S3=(
  [web-lb]="10.10.10.100"
  [web01]="10.10.10.101"
  [web02]="10.10.10.102"
  [db-master]="10.10.10.103"
  [db-slave1]="10.10.10.104"
  [storage]="10.10.10.105"
)
NETMASK="24"
GATEWAY_ENP0S3="10.10.10.1"
GATEWAY_ENP0S8="20.20.20.1"
DNS="8.8.8.8"

ROLE=$(hostname)

print_menu() {
  echo "Seleccione una opción:" 
  echo "1) Automático (instala y configura según el hostname)"
  echo "2) Cambiar nombre de máquina (hostname + /etc/hosts)"
  echo "3) Configurar NGINX Load Balancer"
  echo "4) Instalar WordPress"
  echo "5) Configurar MySQL Master"
  echo "6) Configurar MySQL Slave"
  echo "0) Salir"
}

set_static_ip() {
  IP3="${IP_MAP_ENP0S3[$ROLE]:-}"
  IP8="${IP_MAP_ENP0S8[$ROLE]:-}"
  if [[ -z "$IP3" || -z "$IP8" ]]; then
    echo "[ERROR] Rol '$ROLE' no tiene IP asignada en uno de los mapas"
    exit 1
  fi
  cat > /etc/netplan/50-static.yaml <<EOF
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: no
      addresses:
        - ${IP3}/${NETMASK}
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY_ENP0S3}
      nameservers:
        addresses: [${DNS}]
    enp0s8:
      dhcp4: no
      addresses:
        - ${IP8}/${NETMASK}
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY_ENP0S8}
      nameservers:
        addresses: [${DNS}]
EOF
  netplan apply
  echo "[INFO] IP estática configurada: enp0s3=${IP3}, enp0s8=${IP8}"
}

install_common() {
  echo "[INFO] Instalando paquetes comunes"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx mysql-server php-fpm php-mysql php-curl php-gd \
    php-xml php-mbstring php-zip php-intl wget unzip
}

setup_mysql_master() {
  echo "[db-master] Configurando Master"
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
  echo "[${ROLE}] Configurando Slave"
  ID=${ROLE##*-}
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=$((ID+1))
replicate-do-db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  MASTER_LOG=$(mysql -uroot -p"${DB_ROOT_PASS}" -h"${IP_MAP_ENP0S3[db-master]}" \
    -e "SHOW MASTER STATUS\G" | awk '/File:/ {f=$2} /Position:/ {p=$2} END{print f, p}')
  read FILE POS <<< "$MASTER_LOG"
  mysql -uroot -p"${DB_ROOT_PASS}" -e "
    CHANGE MASTER TO MASTER_HOST='${IP_MAP_ENP0S3[db-master]}',
                   MASTER_USER='${DB_REPL_USER}',
                   MASTER_PASSWORD='${DB_REPL_PASS}',
                   MASTER_LOG_FILE='${FILE}',
                   MASTER_LOG_POS=${POS};
    START SLAVE;"
}

setup_wordpress() {
  echo "[${ROLE}] Instalando WordPress"
  rm -rf /var/www/html/*
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
  tar -xzf /tmp/wp.tar.gz -C /var/www/html --strip-components=1
  chown -R www-data:www-data /var/www/html
  cat > /var/www/html/wp-config.php <<EOF
<?php
define('DB_NAME', '${WP_DB_NAME}');
define('DB_USER', '${WP_DB_USER}');
define('DB_PASSWORD', '${WP_DB_PASS}');
define('DB_HOST', '${IP_MAP_ENP0S3[db-master]}');
define('FS_METHOD', 'direct');
EOF
}

setup_load_balancer() {
  echo "[web-lb] Configurando Load Balancer"
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backend {
    server ${IP_MAP_ENP0S3[web01]};
    server ${IP_MAP_ENP0S3[web02]};
}
server {
    listen 80;
    location / {
        proxy_pass http://backend;
        proxy_set_header Host $host;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/lb.conf /etc/nginx/sites-enabled/default
  systemctl reload nginx
}

change_hostname() {
  read -rp "Nuevo hostname: " NEWHOST
  hostnamectl set-hostname "$NEWHOST"
  sed -i "/127\.0\.1\.1/c\127.0.1.1 $NEWHOST" /etc/hosts
  echo "[INFO] Hostname cambiado a $NEWHOST"
}

main() {
  print_menu
  read -rp "> " opt
  case "$opt" in
    1)
      set_static_ip
      install_common
      case "$ROLE" in
        db-master) setup_mysql_master ;;        db-slave1) setup_mysql_slave ;;        web01|web02)
          setup_wordpress
          systemctl restart php*-fpm nginx
          ;;
        web-lb) setup_load_balancer ;;        storage) echo "[storage] Sin acción adicional" ;;        *) echo "[ERROR] Rol desconocido: $ROLE"; exit 1 ;;      esac
      ;;
    2) change_hostname ;;    3) setup_load_balancer ;;    4) setup_wordpress ;;    5) setup_mysql_master ;;    6) setup_mysql_slave ;;    0) exit 0 ;;    *) echo "Opción inválida"; exit 1 ;;  esac
  echo "[${ROLE}] Tarea completada"
}

main

