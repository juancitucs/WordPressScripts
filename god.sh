#!/bin/bash
# vm.sh: Configuración completa de cluster LEMP + WordPress
# 
# PREPARACIÓN ANTES DE EJECUTAR:
# 1) Asignar hostname exactamente como uno de los siguientes roles:
#    - web-lb, web01, web02, db-master, db-slave1, db-slave2
#    Ejemplo:
#      sudo hostnamectl set-hostname web01
# 2) Crear en /root/ dos archivos:
#    a) ips.conf con claves e IPs estáticas:
#       web_lb_ip=10.0.0.10
#       web01_ip=10.0.0.11
#       web02_ip=10.0.0.12
#       db_master_ip=10.0.0.20
#       db_slave1_ip=10.0.0.21
#       db_slave2_ip=10.0.0.22
#       netmask=24
#       gateway=10.0.0.1
#       dns=8.8.8.8
#    b) cluster.conf (opcional, puede estar vacío o con variables extras)
# 3) Exportar variables sensibles o el script las pedirá:
#    export DB_ROOT_PASS="suRoot"
#    export DB_REPL_PASS="suRepl"
#    export WP_DB_PASS="suWpPass"
# 4) Colocar este vm.sh junto a ips.conf y cluster.conf, dar permisos:
#       chmod +x vm.sh
# 5) Ejecutar con sudo:
#       sudo ./vm.sh
# 
# El script validará el hostname y la presencia de ips.conf antes de continuar.

set -euo pipefail

# --- Validaciones iniciales ---
ALLOWED_ROLES=("web-lb" "web01" "web02" "db-master" "db-slave1" "db-slave2")
ROLE=$(hostname)
if [[ ! " ${ALLOWED_ROLES[@]} " =~ " ${ROLE} " ]]; then
  echo "ERROR: Hostname inválido: '$ROLE'"
  echo "Debe ser uno de: ${ALLOWED_ROLES[*]}"
  exit 1
fi

IP_FILE="/root/ips.conf"
CFG_FILE="/root/cluster.conf"

if [[ ! -f "$IP_FILE" ]]; then
  echo "ERROR: No se encontró '$IP_FILE'. Asegúrate de crearlo según las instrucciones al inicio." >&2
  exit 1
fi

# Cargar configuraciones
source "$IP_FILE"
if [[ -f "$CFG_FILE" ]]; then source "$CFG_FILE"; fi

# Variables de IP esperadas
declare -A IPS=(
  [web-lb]="${web_lb_ip:-}"
  [web01]="${web01_ip:-}"
  [web02]="${web02_ip:-}"
  [db-master]="${db_master_ip:-}"
  [db-slave1]="${db_slave1_ip:-}"
  [db-slave2]="${db_slave2_ip:-}"
)
STATIC_IP=${IPS[$ROLE]}
if [[ -z "$STATIC_IP" ]]; then
  echo "ERROR: No hay IP estática configurada para rol '$ROLE' en ips.conf" >&2
  exit 1
fi

# Datos sensibles
: ${DB_ROOT_PASS:=$(read -s -p "Contraseña MySQL root: " && echo) && echo}
: ${DB_REPL_USER:=repl}
: ${DB_REPL_PASS:=$(read -s -p "Contraseña replicación MySQL: " && echo) && echo}
: ${WP_DB_NAME:=wordpress}
: ${WP_DB_USER:=wpuser}
: ${WP_DB_PASS:=$(read -s -p "Contraseña WordPress DB: " && echo) && echo}

# Funciones de despliegue
set_static_ip() {
  echo "[${ROLE}] Configurando IP estática: $STATIC_IP"
  cat > /etc/netplan/01-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses: [${STATIC_IP}/${netmask}]
      nameservers:
        addresses: [${dns}]
      routes:
        - to: 0.0.0.0/0
          via: ${gateway}
EOF
  netplan apply
}

install_common() {
  echo "[${ROLE}] Instalando paquetes comunes (NGINX, MySQL, PHP, wget, unzip)"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx mysql-server \
    php-fpm php-mysql php-curl php-gd php-xml php-mbstring php-zip php-intl \
    wget unzip
}

setup_mysql_master() {
  echo "[db-master] Configurando MySQL Master"
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=1
log_bin=mysql-bin
binlog_do_db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  mysql -uroot -p"${DB_ROOT_PASS}" -e \
    "CREATE USER '${DB_REPL_USER}'@'%' IDENTIFIED BY '${DB_REPL_PASS}'; GRANT REPLICATION SLAVE ON *.* TO '${DB_REPL_USER}'@'%'; FLUSH PRIVILEGES;"
  mysql -uroot -p"${DB_ROOT_PASS}" -e \
    "CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME}; CREATE USER '${WP_DB_USER}'@'%' IDENTIFIED BY '${WP_DB_PASS}'; GRANT ALL ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'%'; FLUSH PRIVILEGES;"
}

setup_mysql_slave() {
  echo "[${ROLE}] Configurando MySQL Slave"
  ID=${ROLE##*-}
  cat >> /etc/mysql/mysql.conf.d/mysqld.cnf <<EOF
server-id=$((ID+1))
replicate-do-db=${WP_DB_NAME}
EOF
  systemctl restart mysql
  MASTER_LOG=$(mysql -uroot -p"${DB_ROOT_PASS}" -h"${db_master_ip}" -e "SHOW MASTER STATUS\G" | awk '/File:/ {file=$2} /Position:/ {pos=$2} END{print file, pos}')
  read FILE POS <<< "$MASTER_LOG"
  mysql -uroot -p"${DB_ROOT_PASS}" -e \
    "CHANGE MASTER TO MASTER_HOST='${db_master_ip}', MASTER_USER='${DB_REPL_USER}', MASTER_PASSWORD='${DB_REPL_PASS}', MASTER_LOG_FILE='${FILE}', MASTER_LOG_POS=${POS}; START SLAVE;"
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
define('DB_HOST', '${db_master_ip}');
// Claves de seguridad...
EOF
}

configure_nginx_lb() {
  echo "[web-lb] Configurando Nginx Load Balancer"
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backends {
    server ${web01_ip};
    server ${web02_ip};
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

# Ejecución principal
set_static_ip
install_common
case "$ROLE" in
  db-master)    setup_mysql_master ;;  
  db-slave1|db-slave2) setup_mysql_slave ;;  
  web01|web02)  setup_wordpress; systemctl restart php*-fpm nginx ;;  
  web-lb)      configure_nginx_lb ;;  
  *) echo "Rol $ROLE no soportado" >&2; exit 1 ;;  
esac

echo "[${ROLE}] Proceso completado."
