# Producción en un VPS Hetzner con Kamal

Preparación para **un único servidor** con Ubuntu 24.04 LTS, Docker, PostgreSQL 18, Rails web, Solid Queue, OSRM y Kamal Proxy. No se ha aprovisionado ni desplegado un servidor real. IP, dominio, usuario, claves y contraseñas deben proporcionarse; los nombres en mayúsculas de los ejemplos son placeholders.

## Equipo que despliega

Debe tener Docker/Buildx, Ruby 3.4.12 y Bundler (o un entorno equivalente de desarrollo), acceso SSH con clave y el repositorio privado. No necesita instalar OSRM en el host. Ejecutar `bundle install`; el lockfile fija Kamal 2.12.0.

Antes de un despliegue real, revisar y commitear los cambios que se quieran publicar. Kamal construye desde el checkout Git: los cambios locales sin commit no deben darse por incluidos. Esta implementación no realiza commits, push ni un despliegue automáticamente.

El [registry local oficial de Kamal](https://kamal-deploy.org/docs/configuration/docker-registry/) usa `localhost:5555` en el equipo que construye y túneles SSH para descargar las imágenes en el VPS. No publica la aplicación en Docker Hub ni requiere cuenta/plan de registry. El equipo constructor debe permanecer conectado durante el deploy, con su Docker funcionando y el puerto local libre. Las imágenes almacenadas en el VPS permiten rollback a versiones conservadas; para reconstruir una versión eliminada debe estar disponible el equipo constructor/repo. Un fallo de túnel no debe solucionarse publicando el registry en Internet.

```sh
bundle install
bin/validate-deploy
docker build --target production -t app-repartos-production:verify .
bin/test-production
```

La validación usa placeholders locales si faltan variables, no se conecta a hosts ni imprime secretos. Para desplegar, las variables reales son obligatorias:

```sh
export DEPLOY_HOST=IP_O_ALIAS_SSH_REAL
export DEPLOY_SSH_USER=USUARIO_SSH_REAL
export APP_HOST=DOMINIO_REAL
# Opcional para un servidor ARM: export DEPLOY_ARCH=arm64
```

Comprobar la huella SSH por un canal confiable y guardarla en `known_hosts`. En `~/.ssh/config` usar `StrictHostKeyChecking yes` e `IdentityFile` para la clave elegida. Nunca desactivar verificación para resolver un fallo de acceso.

## Ubuntu y volúmenes

Crear el VPS con Ubuntu 24.04 e instalar/verificar una clave en el usuario de despliegue. No hay una IP ni cuenta predefinidas en el repo. Configurar en Hetzner Firewall solo SSH desde el origen autorizado, y TCP 80/443 públicos. Apuntar el DNS del dominio al VPS; si existe AAAA, también debe resolver al servidor correcto.

`bin/prepare-vps` es un bootstrap explícito para **un servidor nuevo**, no se ejecuta desde deploy ni en la máquina local. Instala Docker desde su repositorio oficial, Compose/Buildx, UFW y rsync; exige usuario existente, clave instalada y CIDR autorizado:

```sh
scp bin/prepare-vps "$DEPLOY_SSH_USER@$DEPLOY_HOST:/tmp/prepare-app-repartos"
ssh -t "$DEPLOY_SSH_USER@$DEPLOY_HOST" 'sudo env DEPLOY_SSH_USER=USUARIO_SSH_REAL SSH_ALLOW_CIDR=IP_O_CIDR_AUTORIZADO SSH_PORT=22 bash /tmp/prepare-app-repartos'
```

Sustituir los tres placeholders dentro del comando remoto. Mantener la sesión original abierta y comprobar otra sesión antes de cerrarla. El bootstrap deshabilita contraseñas SSH y acceso root, permite 80/443 y SSH desde el CIDR indicado. El puerto SSH debe coincidir con la configuración efectiva del servidor. Reiniciar sesión para tomar el grupo Docker. El usuario no necesita sudo cotidiano para deploy; pertenecer al grupo Docker da capacidad equivalente a root y debe limitarse a operadores de confianza.

Persistencia:

| Host | Contenedor | Contenido |
| --- | --- | --- |
| `/var/lib/app-repartos/postgres` | `/var/lib/postgresql` | PostgreSQL 18, incluidas ambas bases |
| `/var/lib/app-repartos/storage` | `/rails/storage` | Archivos privados en `files/`; UID/GID 1000 |
| `/var/lib/app-repartos/routing` | `/data` | Releases de mapa y enlace `current` |

Los contenedores se pueden reemplazar sin borrar esos directorios. No usar `kamal accessory remove ...` ni eliminar volúmenes como procedimiento de actualización. La memoria predeterminada suma aproximadamente 6,5 GiB de límites entre web, jobs, PostgreSQL y OSRM, más sistema/proxy; comenzar con 8 GiB o más y medir. Procesar mapas fuera del VPS cuando su preparación compita con estos servicios.

## Secretos y bases

```sh
cp .kamal/secrets.example .kamal/secrets
chmod 600 .kamal/secrets
bundle exec rails secret
```

Editar `.kamal/secrets` con un `SECRET_KEY_BASE` generado, `DATABASE_PASSWORD` de la aplicación y un `POSTGRES_PASSWORD` administrativo diferente. No dejar placeholders, compartir el archivo ni subirlo a Git. Kamal gestiona los env-files remotos; no se incrustan credenciales en las capas Docker. Las variables públicas están en `config/deploy.yml`.

El accessory PostgreSQL ejecuta `config/deploy/init-databases.sh` **solo cuando el directorio es nuevo**: crea el rol `repartos` sin superusuario/creación de roles/bases, y las bases `app_repartos_production` y `app_repartos_production_queue`, propiedad de ese rol. No recrea bases durante deploys. Cambiar el secreto después del primer inicio no cambia automáticamente contraseñas de roles: rotarlas mediante PostgreSQL y actualizar el secreto de forma coordinada.

```sh
bundle exec kamal accessory boot db
bundle exec kamal accessory details db
```

Para migrar una instalación previa, detener las escrituras del sistema anterior, obtener backups verificables de **ambas bases y adjuntos**, restaurarlos y comprobarlos antes de activar tráfico. Si los archivos estaban en R2, copiarlos a Disk conservando sus claves o continuar con `ACTIVE_STORAGE_SERVICE=r2` y sus secretos mientras se hace esa migración explícita. Cambiar el servicio predeterminado no migra blobs existentes; estos conservan su `service_name`. No borrar el bucket ni la configuración anterior antes de verificar los archivos.

## Preparar el mapa

En el equipo local:

```sh
bin/routing download
bin/routing prepare
bin/routing activate VERSION
rsync -a --info=progress2 storage/routing/releases/ "$DEPLOY_SSH_USER@$DEPLOY_HOST:/var/lib/app-repartos/routing/releases/"
rsync -a storage/routing/current "$DEPLOY_SSH_USER@$DEPLOY_HOST:/var/lib/app-repartos/routing/"
bundle exec kamal accessory boot osrm
bundle exec kamal accessory details osrm
```

Usar la VERSION impresa por `prepare`. Transferir todo el directorio de release validado y mantener sus permisos de lectura. Para preparar directamente en el VPS se pueden copiar `bin/routing`, `config/routing/` y usar `OSRM_DATA_DIR=/var/lib/app-repartos/routing`; requiere memoria adicional, pero ninguna instalación OSRM manual. La opción local evita ese pico en producción.

Para una actualización, preparar/validar otra versión, transferirla **antes de cambiar el enlace**, conservar `current` previo y activar en el host:

```sh
rsync -a storage/routing/releases/NUEVA_VERSION/ "$DEPLOY_SSH_USER@$DEPLOY_HOST:/var/lib/app-repartos/routing/releases/NUEVA_VERSION/"
bundle exec kamal app stop --roles jobs
ssh "$DEPLOY_SSH_USER@$DEPLOY_HOST" 'cd /var/lib/app-repartos/routing && readlink current > previous && ln -s releases/NUEVA_VERSION .next && mv -Tf .next current'
bundle exec kamal accessory reboot osrm
bundle exec kamal accessory details osrm
# Comprobar OSRM saludable antes de reanudar:
bundle exec kamal app start --roles jobs
```

Sustituir NUEVA_VERSION en los comandos remotos. El enlace relativo funciona porque se monta todo el directorio padre. Si falla la comprobación, devolver `current` al release registrado en `previous` y reiniciar solo OSRM. No regenerar mapas durante deploys de Rails. `OSRM_SERVE_MEMORY` permite ajustar el límite de RAM del accessory antes de cambiar a un extracto mayor. Los límites Compose se ajustan en su archivo; no cambia la lógica Rails.

El accessory usa `--mmap=true`: lee páginas del mapa desde archivos y permite que Linux recupere su caché cuando necesita memoria. No apaga OSRM ni garantiza consumo cero. Mantener almacenamiento SSD y releases inmutables; no sobrescribir los archivos de una versión en uso. El límite de 2 GiB sigue siendo un máximo, no memoria reservada. Para adoptar esta opción en una instalación existente, programar una interrupción breve sin cálculos en curso, detener jobs, ejecutar `bundle exec kamal accessory reboot osrm`, verificar su salud y reanudar jobs. No hace falta preparar otra vez el mapa. Las mediciones y sus límites están en [OSRM y optimización](osrm.md).

Web y jobs leen el manifest del mapa mediante un montaje de solo lectura. El worker se detiene durante el cambio para evitar cálculos que mezclen el manifest nuevo con un OSRM todavía cargado con datos anteriores. La caché vial usa esa versión; el mantenimiento solicita nuevos recorridos solo para publicaciones automáticas todavía editables. Ante rollback del mapa, mantener el worker detenido hasta verificar nuevamente OSRM. Si se usa un proveedor externo sin este manifest, definir y actualizar `OSRM_MAP_VERSION` en su configuración.

## Primer deploy y actualizaciones

Con DB y mapa disponibles:

```sh
bundle exec kamal setup
bundle exec kamal app details
bundle exec kamal app logs --tail 100
bundle exec kamal accessory details all
bundle exec kamal app exec --roles jobs --reuse 'bin/jobs-healthy'
```

Kamal Proxy termina HTTPS y consulta `/up` en el puerto interno 3000. Solo proxy publica 80/443; PostgreSQL y OSRM no publican puertos. Se usa el target `production` del Dockerfile, assets precompilados, Puma en `0.0.0.0:3000`, usuario UID/GID 1000 y almacenamiento Disk privado persistente. No se necesita R2 para una instalación nueva.

La web ejecuta `db:prepare` antes de arrancar por `RUN_DB_PREPARE=1`. Las bases ya existen; Rails aplica migraciones/schema sin recrearlas. El worker no migra. Los seeds demostrativos tienen guard de desarrollo y no crean datos en producción. Para cambios posteriores:

```sh
bundle exec kamal deploy
# Si se requiere ejecutar el paso de migración explícitamente:
bundle exec kamal migrate
```

En una actualización con cambios de schema, comprobar compatibilidad de la versión vieja y nueva antes del despliegue: ambas pueden convivir durante el relevo. Las migraciones destructivas requieren una ventana de mantenimiento propia. Este repo está configurado con una sola web; antes de escalar, separar migraciones como paso coordinado. Los índices/migración de esta funcionalidad son aditivos y no reescriben entregas.

Crear la primera empresa y usuario administrador reales con `bundle exec kamal console`; elegir credenciales propias. No hay alta pública ni portal de clientes. No usar `db:seed` ni cuentas demo en producción.

```sh
bundle exec kamal app logs -f
bundle exec kamal accessory logs osrm
bundle exec kamal accessory logs db
bundle exec kamal app exec --primary 'bin/rails runner "puts Osrm::Client.new.available?"'
bundle exec kamal app exec --primary 'bin/rails db:abort_if_pending_migrations'
```

Para rollback de código:

```sh
bundle exec kamal app version
bundle exec kamal rollback VERSION_ANTERIOR
```

El rollback no revierte schema, adjuntos ni datos. Verificar compatibilidad antes de usarlo. No ejecutar `db:rollback` contra datos reales para resolver automáticamente un fallo de código. Se conservan tres contenedores/versiones; ajustar la retención según espacio y política.

## Backups y restauración

Copiar los scripts al servidor e instalarlos con propietario root y permisos 0750. No necesitan un checkout completo:

```sh
scp bin/vps-backup bin/vps-restore bin/verify-backup "$DEPLOY_SSH_USER@$DEPLOY_HOST:/tmp/"
ssh -t "$DEPLOY_SSH_USER@$DEPLOY_HOST" 'sudo install -m 0750 /tmp/vps-backup /usr/local/sbin/app-repartos-backup && sudo install -m 0750 /tmp/vps-restore /usr/local/sbin/app-repartos-restore && sudo install -m 0750 /tmp/verify-backup /usr/local/sbin/app-repartos-verify-backup'
```

`vps-backup` usa `pg_dump -Fc` de ambas bases, un tar de archivos, manifest y SHA-256. Trabaja en un directorio temporal y publica solo backups completos. Retiene 14 copias completas de forma predeterminada. Variables opcionales: `BACKUP_DIR`, `BACKUP_KEEP`, `APP_STORAGE_DIR`, `POSTGRES_CONTAINER`, `POSTGRES_ADMIN_USER`, `PRIMARY_DATABASE_NAME`, `QUEUE_DATABASE_NAME` y `BACKUP_REMOTE`.

```sh
# En el VPS:
sudo /usr/local/sbin/app-repartos-backup
sudo /usr/local/sbin/app-repartos-verify-backup /var/backups/app-repartos/backup-VERSION
```

Programar con cron del propietario root, por ejemplo `20 3 * * * /usr/local/sbin/app-repartos-backup >> /var/log/app-repartos-backup.log 2>&1`. Configurar rotación de ese log y revisar fallos/espacio disponible. Los dumps tienen snapshots consistentes por base, pero no una transacción distribuida con los archivos: para una copia coordinada y antes de restaurar, activar mantenimiento y detener escrituras/web/jobs. La limpieza de evidencias puede borrar archivos mientras se copian si no se detienen los jobs.

`verify-backup` restaura ambas bases en un PostgreSQL 18 temporal, sin red ni puertos, valida tablas esperadas y lee el archivo de adjuntos. No toca la instancia existente. Para restaurar realmente:

```sh
# Desde el equipo que despliega:
bundle exec kamal app maintenance
bundle exec kamal app stop --roles web,jobs
# En el VPS, tras elegir y verificar el backup:
sudo env RESTORE_MAINTENANCE=1 /usr/local/sbin/app-repartos-restore /var/backups/app-repartos/backup-VERSION
# Luego verificar datos, adjuntos y tareas pendientes antes de reactivar:
bundle exec kamal app start --roles web,jobs
bundle exec kamal app live
```

El script se niega a restaurar si detecta web/jobs activos, exige la variable de mantenimiento y conserva dumps y archivos previos. Restaura objetos bajo el rol `repartos`; si una instalación usa otro rol, ajustar `APP_DATABASE_ROLE`. Las tareas de la base de cola pueden volver a ejecutarse; revisar su estado antes de reactivar worker. Las contraseñas/roles PostgreSQL y secretos se conservan/configuran aparte del dump de cada base.

**Un backup solo dentro del mismo VPS no protege contra pérdida total del servidor.** Copiar opcionalmente a un equipo del propietario mediante SSH/rsync, sin contratar otro servicio:

```sh
# Ejemplo de variable al ejecutar backup; completar host, usuario y ruta reales.
sudo env BACKUP_REMOTE=USUARIO@EQUIPO_DEL_PROPIETARIO:/RUTA_PRIVADA /usr/local/sbin/app-repartos-backup
```

También se pueden descargar los backups desde ese equipo. Conservar fuera del VPS una copia cifrada/controlada de los secretos y del mapa o la capacidad de reconstruirlo. No incluir contraseñas en comandos persistidos en historial.

## Problemas frecuentes y límites

- `/up` falla: revisar env de Rails, conexión DB, migraciones, permisos UID 1000 y logs. El healthcheck no depende de OSRM; un fallo de mapas no impide el panel.
- Jobs no saludables: revisar heartbeat y base queue; `bin/jobs-healthy` limita su comprobación al hostname del contenedor. La web no ejecuta jobs embebidos.
- OSRM reinicia: revisar mapa activo, versión binaria, permisos y OOM. Volver al release anterior y medir RAM antes de aumentar cobertura.
- Registry local inaccesible: mantener Docker/SSH del equipo constructor disponibles y revisar puerto/túnel. No abrir PostgreSQL/OSRM/registry al público.
- No hay un backup remoto contratado, geocodificador comercial, teselas comerciales ni API de optimización paga. Las funciones cartográficas anteriores siguen siendo opcionales y admiten ingreso manual de coordenadas.
- Falta verificar DNS/HTTPS, capacidad efectiva del VPS, acceso SSH y un deploy/rollback reales cuando se proporcione infraestructura. La validación local no sustituye esas pruebas.

Referencias: [Kamal 2 configuración](https://kamal-deploy.org/docs/configuration/overview/), [accessories](https://kamal-deploy.org/docs/configuration/accessories/), [Docker Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [PostgreSQL 18 backup](https://www.postgresql.org/docs/18/backup-dump.html).
