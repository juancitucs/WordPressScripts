
#!/usr/bin/env bash
set -euo pipefail

# vm.sh: Configuración LEMP+WordPress+MySQL Replicación+LB
# Soporta QEMU (--qemu) y VirtualBox (--virtualbox)

# --- VARIABLES EDITABLES ---
PASSWORD="1234"
DB_ROOT_PASS="$PASSWORD"
DB_REPL_PASS="$PASSWORD"
WP_DB_PASS="$PASSWORD"
WP_DB_USER="wpuser"
WP_DB_NAME="wordpress"
DB_REPL_USER="repl"

# IPs según diagrama
declare -A IP_MAP=(
  [web-lb]="20.20.20.21"
  [web01]="20.20.20.22"
  [web02]="20.20.20.23"
  [db-master]="20.20.20.24"
  [db-slave1]="20.20.20.25"
  [storage]="20.20.20.26"
)
NETMASK="24"
GATEWAY="20.20.20.1"
DNS="8.8.8.8"

# Variables de modo y acción
VM_MODE="qemu"   # default: qemu
ACTION="install" # default: install (completo)

ROLE=$(hostname)

print_help() {
  cat <<EOF
Uso: sudo ./vm.sh [--set-ip] [--install] [--qemu | --virtualbox]

Opciones:
  --help         Muestra este mensaje
  --set-ip       Solo configura IP estática (solo en modo VirtualBox)
  --install      Ejecuta instalación completa
  --qemu         Modo QEMU (NAT with DHCP)
  --virtualbox   Modo VirtualBox (usa host-only para IP estática)
EOF
  exit 0
}

# Detectar interfaces disponibles (excluye loopback)
detect_interfaces() {
  ls /sys/class/net | grep -v lo
}

# Seleccionar interfaz según modo
select_interface() {
  mapfile -t ifs < <(detect_interfaces)
  if [[ "$VM_MODE" == "virtualbox" ]]; then
    # VirtualBox: segundo adaptador host-only
    echo "${ifs[1]:-}"
  else
    # QEMU: primer adaptador NAT
    echo "${ifs[0]:-}"
  fi
}

# Configuración estática solo para VirtualBox
set_static_ip() {
  STATIC_IP="${IP_MAP[$ROLE]:-}"
  if [[ -z "$STATIC_IP" ]]; then
    echo "[ERROR] Rol '$ROLE' no tiene IP asignada"
    exit 1
  fi
  IFACE=$(select_interface)
  if [[ -z "$IFACE" ]]; then
    read -rp "Interfaz de red (host-only): " IFACE
  fi
  echo "[INFO] $VM_MODE: Configurando IP $STATIC_IP en $IFACE"
  cat > /etc/netplan/50-cloud-init.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [${STATIC_IP}/${NETMASK}]
      gateway4: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF
  netplan apply
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
  MASTER_LOG=$(mysql -uroot -p"${DB_ROOT_PASS}" -h"${IP_MAP[db-master]}" \
    -e "SHOW MASTER STATUS\G" | awk '/File:/ {f=$2} /Position:/ {p=$2} END{print f, p}')
  read FILE POS <<< "$MASTER_LOG"
  mysql -uroot -p"${DB_ROOT_PASS}" -e "
    CHANGE MASTER TO MASTER_HOST='${IP_MAP[db-master]}',
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
define('DB_HOST', '${IP_MAP[db-master]}');
define('FS_METHOD', 'direct');
EOF
}

setup_load_balancer() {
  echo "[web-lb] Configurando Load Balancer"
  cat > /etc/nginx/sites-available/lb.conf <<EOF
upstream backend {
    server ${IP_MAP[web01]};
    server ${IP_MAP[web02]};
}
server {
    listen 80;
    location / {
        proxy_pass http://backend;
        proxy_set_header Host \$host;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/lb.conf /etc/nginx/sites-enabled/default
  systemctl reload nginx
}

main() {
  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --help) print_help ;;  
      --qemu) VM_MODE="qemu" ;;  
      --virtualbox) VM_MODE="virtualbox" ;;  
      --set-ip) ACTION="set-ip" ;;  
      --install) ACTION="install" ;;  
      *) ;;  
    esac
  done

  # Ejecutar según acción y modo
  case "$ACTION" in
    set-ip)
      if [[ "$VM_MODE" == "virtualbox" ]]; then
        set_static_ip
      else
        echo "[QEMU] Modo NAT con DHCP, no se configura IP estática." 
      fi
      ;;
    install)
      if [[ "$VM_MODE" == "virtualbox" ]]; then
        set_static_ip
      else
        echo "[QEMU] Saltando IP estática, usando DHCP en NAT." 
      fi
      install_common
      case "$ROLE" in
        db-master)   setup_mysql_master ;;  
        db-slave1)   setup_mysql_slave ;;  
        web01|web02) setup_wordpress; systemctl restart php*-fpm nginx ;;  
        web-lb)      setup_load_balancer ;;  
        storage)     echo "[storage] Sin acción adicional" ;;  
        *) echo "[ERROR] Rol desconocido: $ROLE"; exit 1 ;;  
      esac
      echo "[$ROLE] Configuración completada"
      ;;
    *) print_help ;;
  esac
}

main "$@"

