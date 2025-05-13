
#!/bin/bash
# vm.sh: Configuración completa de cluster LEMP + WordPress + Load Balancer + Replicación
# Roles soportados: web-lb, web01, web02, db-master, db-slave1, storage

set -euo pipefail

### === VARIABLES EDITABLES === ###
# Passwords y credenciales
DEFAULT_PASS="1234"
DB_ROOT_PASS="$DEFAULT_PASS"
DB_REPL_USER="repl"
DB_REPL_PASS="$DEFAULT_PASS"
WP_DB_NAME="wordpress"
WP_DB_USER="wpuser"
WP_DB_PASS="$DEFAULT_PASS"

# Red
NETMASK="24"
GATEWAY="20.20.20.1"
DNS="8.8.8.8"

# Mapeo de hostnames => IPs estáticas
declare -A STATIC_IPS=(
  [web-lb]="20.20.20.21"
  [web01]="20.20.20.22"
  [web02]="20.20.20.23"
  [db-master]="20.20.20.24"
  [db-slave1]="20.20.20.25"
  [storage]="20.20.20.26"
)

# Resto de paquetes comunes (se pueden editar)
COMMON_PACKAGES=(nginx mysql-server php-fpm php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl wget unzip)

### === FIN DE VARIABLES === ###

ROLE="$(hostname)"
IP="${STATIC_IPS[$ROLE]:-}"

if [[ -z "$IP" ]]; then
  echo "ERROR: Hostname desconocido '$ROLE'. Debe ser uno de: ${!STATIC_IPS[*]}"
  exit 1
fi

log() { echo "[$ROLE] $*"; }

set_static_ip() {
  log "Configurando IP estática: $IP/$NETMASK gateway $GATEWAY dns $DNS"
  cat > /etc/netplan/01-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses: [${IP}/${NETMASK}]
      nameservers:
        addresses: [${DNS}]
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY}
EOF
  netplan apply
}

install_common() {
  log "Instalando paquetes comunes: ${COMMON_PACKAGES[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${COMMON_PACKAGES[@]}"
}

configure_mysql_master() {
  log "Configurando MySQL Master"
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=1
log_bin=mysql-bin
binlog_do_db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  mysql -uroot -p"${DB_ROOT_PASS}" <<EOF
CREATE USER IF NOT EXISTS '${DB_REPL_USER}'@'%' IDENTIFIED BY '${DB_REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${DB_REPL_USER}'@'%';
CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME};
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'%' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF
}

configure_mysql_slave() {
  log "Configurando MySQL Slave"
  # Asumimos db-master en .24
  MASTER_HOST="${STATIC_IPS[db-master]}"
  ID=${ROLE##*-}           # p.ej. '1' para db-slave1
  SERVER_ID=$((ID + 1))    # 2,3,...
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=${SERVER_ID}
replicate-do-db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  # Obtener estado del master
  read FILE POS <<<"$(mysql -uroot -p"${DB_ROOT_PASS}" -h"${MASTER_HOST}" -e 'SHOW MASTER STATUS\G' \
      | awk '/File:/ {f=$2} /Position:/ {p=$2} END{print f, p}')"
  mysql -uroot -p"${DB_ROOT_PASS}" <<EOF
CHANGE MASTER TO
  MASTER_HOST='${MASTER_HOST}',
  MASTER_USER='${DB_REPL_USER}',
  MASTER_PASSWORD='${DB_REPL_PASS}',
  MASTER_LOG_FILE='${FILE}',
  MASTER_LOG_POS=${POS};
START SLAVE;
EOF
}

configure_wordpress() {
  log "Instalando WordPress"
  rm -rf /var/www/html/*
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
  tar -xzf /tmp/wp.tar.gz -C /var/www/html --strip-components=1
  chown -R www-data:www-data /var/www/html
  cat > /var/www/html/wp-config.php <<EOF
<?php
define('DB_NAME',     '${WP_DB_NAME}');
define('DB_USER',     '${WP_DB_USER}');
define('DB_PASSWORD', '${WP_DB_PASS}');
define('DB_HOST',     '${STATIC_IPS[db-master]}');
// TODO: Añadir claves de seguridad...
EOF
}

configure_nginx_lb() {
  log "Configurando Nginx como Load Balancer"
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backends {
    server ${STATIC_IPS[web01]};
    server ${STATIC_IPS[web02]};
}
server {
    listen 80;
    location / {
        proxy_pass http://backends;
        proxy_set_header Host \$host;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/lb.conf /etc/nginx/sites-enabled/
  systemctl reload nginx
}

# === EJECUCIÓN ===
log "Iniciando configuración para rol '$ROLE'"
set_static_ip
install_common

case "$ROLE" in
  db-master)
    configure_mysql_master
    ;;
  db-slave1)
    configure_mysql_slave
    ;;
  web01|web02)
    configure_wordpress
    systemctl restart php*-fpm nginx
    ;;
  web-lb)
    configure_nginx_lb
    ;;
  storage)
    log "Servidor de almacenamiento configurado. Sólo IP estática aplicada."
    ;;
  *)
    echo "ERROR: Rol '$ROLE' no soportado."
    exit 1
    ;;
esac

log "¡Configuración completada!"

