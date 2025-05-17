## god.sh - TUTO

Este script ayuda a configurar 5 máquinas virtuales en un sistema distribuido LEMP + WordPress + MySQL + Load Balancer.

### Requisitos

* Ubuntu 20.04 o superior
* Permisos de `sudo` en cada máquina
* Conexión de red entre las máquinas (RED NAT en `enp0s3`, Adaptador solo anfitrión(host-only) en `enp0s8`)

### Instalación del script

1. Copia el archivo `god.sh` en cada máquina, o descargalo mediante wget
```
wget https://raw.githubusercontent.com/juancitucs/WordPressScripts/refs/heads/master/god.sh
```
2. Dale permisos de ejecución:
```bash
sudo chmod +x god.sh
```
3. Ejecuta:
```bash
sudo bash god.sh
```

### Menú Principal

Al ejecutar, verás:
```
Seleccione una opción:
1) Automático
2) Cambiar hostname
3) Configurar LB (master)
4) Instalar WP
5) Configurar MySQL Master
6) Configurar MySQL Slave
0) Salir
>
```

Elige el número y presiona `Enter`.

### Opciones Detalladas

#### 1) Automático

Detecta el nombre de la máquina (`hostname`) y aplica todo lo necesario:

* `master`: configura el balanceador en Nginx.
* `worker01/worker02`: instala WordPress en cada servidor.
* `worker03`: ajusta MySQL como maestro de replicación.
* `worker04`: ajusta MySQL como esclavo.

#### 2) Cambiar hostname

Muestra un menú con los nombres válidos:

```
1) master
2) worker01
3) worker02
4) worker03
5) worker04
```

Selecciona uno para renombrar la máquina y actualizar `/etc/hosts` y `/etc/hostname`.

#### 3) Configurar LB (master)

Instala y activa un sitio en Nginx que reparte el tráfico entre `worker01` y `worker02`.

#### 4) Instalar WP (worker01/02)

* Descarga y descomprime WordPress.
* Crea el archivo `wp-config.php` con datos de la base de datos.
* Activa la configuración de Nginx para servir WordPress.

#### 5) Configurar MySQL Master (worker03)

* Ajusta `mysqld.cnf` para habilitar binlogs y replicación.
* Crea el usuario de replicación (`repl`).
* Ajusta contraseñas y permisos.

#### 6) Configurar MySQL Slave (worker04)

* Ajusta `mysqld.cnf` para ser esclavo.
* Conecta al maestro usando la IP de `worker03`.
* Inicia el proceso de replicación.

#### 0) Salir

Sale del script sin hacer cambios.

---


QDAAAA
