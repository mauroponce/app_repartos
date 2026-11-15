# Backups externos cifrados y recuperación

El procedimiento de producción usa `age` (cifrado asimétrico) y `rclone` (API S3 de Cloudflare R2). **El repositorio prepara y prueba las herramientas; no crea un bucket ni configura una cuenta real sin credenciales.** El bucket, permisos, subida y recuperación reales se deben comprobar antes del piloto.

## Qué contiene y qué garantiza

Cada `backup-FECHAUTC-ALEATORIO.tar.age` contiene:

- `primary.dump`: PostgreSQL principal, formato custom, sin propietarios ni ACL.
- `queue.dump`: PostgreSQL de Solid Queue, en una copia separada.
- `files.tar.gz`: únicamente `files/` del volumen persistente de Active Storage, más originales R2 si se usa ese servicio.
- `blobs.csv`: catálogo de adjuntos del mismo snapshot que el dump principal.
- `primary-counts.json`: conteos de tablas principales en ese snapshot.
- `manifest.json`: formato, UTC, versión de aplicación declarada, versión de pg_dump, bases, conteos y alcance de consistencia.
- `files.json` y `SHA256SUMS`: tamaño/SHA-256 de archivos y checksums de los componentes.

Se exporta un snapshot PostgreSQL principal compartido por `pg_dump`, catálogo y conteos. El tar se compara contra el tamaño y checksum MD5 de **cada** blob de ese snapshot y se calcula además SHA-256 de los archivos. Si falta un adjunto o cambió su contenido, se aborta antes de cifrar/subir. Esto detecta, por ejemplo, una purga concurrente. Los objetos deben ser inmutables por clave, como espera Active Storage.

**No hay consistencia atómica entre principal, Solid Queue y archivos.** Queue usa otro snapshot; pueden existir trabajos y archivos de momentos diferentes. Una copia online contiene también archivos locales todavía no referenciados. Para una copia coordinada antes de cambios delicados, poner mantenimiento y detener web/jobs mientras se crea. Antes de reanudar una recuperación, revisar la cola: no se garantiza que reproducir todos los jobs antiguos sea correcto. Los UUID/idempotencia del dominio no sustituyen esa revisión operativa.

No se incluyen `.env`, credentials, claves Rails, claves privadas `age`, configuración de rclone ni mapas. El volumen `storage/files` debe contener solo datos de Active Storage. Conservar secretos y la versión del mapa mediante un procedimiento de recuperación separado y protegido; no copiarlos allí. `BACKUP_APP_VERSION` debe actualizarse con cada despliegue para identificar el código que corresponde al dump. Los datos se incluyen para todas las empresas; los backups son privados de operación y no se exponen mediante Rails ni URLs públicas.

## Preparación de R2 y claves

1. Crear un bucket dedicado **privado**, sin dominio público ni acceso `r2.dev`. Usar un prefijo exclusivo, por ejemplo `production/app-repartos`.
2. Crear un token **Object Read & Write**, limitado a ese bucket. La retención necesita borrar objetos dentro del prefijo. No reutilizar credenciales de Active Storage ni un token administrador de toda la cuenta.
3. Obtener endpoint S3 `https://ACCOUNT_ID.r2.cloudflarestorage.com`, Access Key ID y Secret Access Key. Configurar `no_check_bucket=true` evita exigir permisos de administración para verificar/crear buckets.
4. En un equipo de recuperación separado, generar la identidad:

```sh
umask 077
age-keygen -o /RUTA_SEGURA/repartos-recovery.agekey
age-keygen -y /RUTA_SEGURA/repartos-recovery.agekey
```

Guardar la clave privada en al menos dos ubicaciones de recuperación protegidas fuera del VPS. Copiar al servidor **solo** la cadena pública `age1...` como `AGE_RECIPIENT`. Sin la privada no se puede recuperar el backup. No guardarla en Git, una imagen ni el mismo VPS de las copias diarias.

Si Active Storage ya usa R2, configurar además `BACKUP_MEDIA_REMOTE` con otro remote y un token **Object Read only** del bucket de adjuntos. El script descarga únicamente las claves del catálogo del snapshot y las verifica; el resultado se almacena con disposición Disk dentro del backup cifrado. Un servicio no reconocido o adjuntos R2 sin remote producen fallo, en vez de una copia incompleta declarada exitosa. La prueba local incluye ambos tipos de archivo.

Referencias: [R2 con rclone](https://developers.cloudflare.com/r2/examples/rclone/), [permisos R2](https://developers.cloudflare.com/r2/api/tokens/), [age](https://github.com/FiloSottile/age).

## Instalación en Ubuntu del VPS

Requiere Docker operativo, Python 3.11 o superior, Bash, GNU tar, util-linux/flock, age, rclone y curl. La implementación usa el cliente PostgreSQL 18 del propio contenedor, sin instalar otra versión en el host.

```sh
sudo apt-get update
sudo apt-get install -y age rclone python3 curl util-linux
sudo bin/install-backups
sudo install -m 0600 config/backup/backup.env.example /etc/app-repartos/backup.env
sudo install -m 0600 config/backup/rclone.conf.example /etc/app-repartos/rclone.conf
sudoedit /etc/app-repartos/backup.env /etc/app-repartos/rclone.conf
```

El instalador copia scripts y librería bajo `/usr/local/lib/app-repartos`, instala unidades y recarga systemd. No habilita tareas antes de completar la configuración. No hace falta mantener un checkout en el VPS. Se puede verificar el paquete sin cambiar servicios con `bin/install-backups /tmp/repartos-backup-package`.

Completar claves reales, bucket/prefijo, contenedor, directorio y versión de aplicación. Los archivos deben pertenecer a root y tener modo `0600`; directorios de copias/configuración `0700`. Las claves de rclone viven fuera del checkout y de las imágenes. No usar `set -x`, imprimir el entorno ni pasar secretos por argumentos del shell.

```sh
# Ejecutar con EnvironmentFile ya configurado, sin imprimir sus contenidos:
sudo systemctl start app-repartos-backup.service
sudo systemctl status app-repartos-backup.service
sudo journalctl -u app-repartos-backup.service --since today
sudo systemctl enable --now app-repartos-backup.timer app-repartos-backup-check.timer
sudo systemctl list-timers 'app-repartos-backup*'
```

El timer corre diariamente a las **03:20 de Buenos Aires**, con hasta 15 minutos de demora aleatoria y recuperación de ejecuciones omitidas. La comprobación corre cada hora. Ajustar frecuencia sin modificar scripts:

```sh
sudo systemctl edit app-repartos-backup.timer
# [Timer]
# OnCalendar=
# OnCalendar=*-*-* 02:00:00 America/Argentina/Buenos_Aires
sudo systemctl daemon-reload
sudo systemctl restart app-repartos-backup.timer
```

Por defecto se conservan 7 archivos locales cifrados y 30 días remotos. Cambiar `BACKUP_KEEP`, `BACKUP_REMOTE_RETENTION_DAYS` y `BACKUP_MAX_AGE_HOURS` en `backup.env`. La rotación remota solo alcanza `backup-*.tar.age` del primer nivel del prefijo configurado; no usar un prefijo compartido. `BACKUP_REMOTE`/rsync del mecanismo anterior se rechaza para impedir subidas sin cifrado.

El script serializa backup/restauración con flock, usa temporales privados, comprueba espacio (reserva inicial de 512 MiB más estimación conservadora de bases/archivos), limpia al terminar y publica solo el archivo cifrado completo. Sube ese archivo y **vuelve a leer el ciphertext remoto para comparar SHA-256**. Una subida o validación fallida devuelve error y no actualiza `last-external.json`. No sube manifiestos ni sidecars en claro. `BACKUP_LOCAL_ONLY=1` existe para pruebas; dice expresamente que no hay copia externa y no satisface el monitor.

Hay que disponer de espacio para dumps, archivo de adjuntos, cifrado y eventual espejo de medios. Las estimaciones pueden ser conservadoras; medir con los datos reales. Los temporales contienen datos sin cifrar dentro de directorios `0700`, se eliminan al salir normalmente o por error controlado. Un apagón/SIGKILL puede dejar restos privados: revisar `.creating-*`, `.safety-*`, `.restore-*`, `.verify-*` y `.legacy-*` sin procesos activos antes de retirarlos. El borrado no garantiza eliminación física de bloques SSD; la protección del disco del VPS sigue siendo parte de la infraestructura.

## Alertas y comprobaciones

`BACKUP_ALERT_WEBHOOK` es opcional: recibe únicamente aplicación, resultado, acción, etapa y UTC. No recibe clientes, coordenadas, archivos, contraseñas ni nombres de empresas. Las unidades `OnFailure` cubren también fallos del proceso que no lleguen al trap. No se exige un servicio pago.

`bin/check-backup` falla por última ejecución fallida, antigüedad mayor a 36 horas, ausencia de copia externa, objeto remoto inexistente/de tamaño diferente o falta de espacio. Etapas como cifrado, subida, integridad o restauración se identifican en las alertas. `verify-backup` alerta si falla su prueba de restauración.

La prueba de restauración se debe programar en el equipo que conserva la identidad, por ejemplo semanalmente, con descarga, `verify-backup` y alerta. Allí se puede exigir `BACKUP_REQUIRE_VERIFIED=1` y `BACKUP_VERIFY_MAX_AGE_DAYS=7`. El VPS no puede descifrar automáticamente sin la clave privada; no se finge esa comprobación. Si se quiere revisar su frescura desde otro monitor, transportar de forma autenticada el resultado `last-verification.json` o usar el mismo webhook externo. Revisar también el silencio del monitor con un mecanismo externo: un servidor apagado no puede avisar por sí mismo.

## Listar, recuperar y verificar en un equipo separado

Preparar rclone con un token de lectura del bucket de backups y estas variables. Usar un directorio local privado:

```sh
umask 077
export BACKUP_DIR="$HOME/.local/state/repartos-recovery"
export RCLONE_CONFIG=/RUTA_SEGURA/rclone-recovery.conf
export BACKUP_RCLONE_REMOTE=r2-backups:BUCKET_PRIVADO/production/app-repartos
export AGE_IDENTITY_FILE=/RUTA_SEGURA/repartos-recovery.agekey
bin/backup-remote list
# Copiar exactamente un nombre de la lista:
BACKUP_NAME=backup-FECHAUTC-ALEATORIO.tar.age
bin/backup-remote fetch "$BACKUP_NAME" "$BACKUP_DIR/$BACKUP_NAME"
bin/verify-backup "$BACKUP_DIR/$BACKUP_NAME"
```

`verify-backup` descifra en un temporal privado, verifica SHA-256, rechaza rutas inseguras/enlaces/archivos especiales/duplicados y restaura ambas bases en un contenedor **PostgreSQL 18 temporal, sin red ni puertos**. Comprueba tablas, conteos del snapshot, catálogo real restaurado y contenidos de todos los adjuntos. El JSON de resultado identifica el entorno temporal. Nunca conecta a las bases de destino productivas. `VERIFY_POSTGRES_MEMORY` permite cambiar su límite inicial de 1 GiB para bases mayores; disponer de memoria/espacio en el equipo de recuperación. La prueba no inicia workers ni reproduce los jobs restaurados.

Los backups locales v1 anteriores siguen admitidos. Se verifican sus cuatro checksums, se validan las rutas del tar y se reconstruye un catálogo desde PostgreSQL temporal antes de validar cada adjunto. Conversión explícita sin modificar el original:

```sh
mkdir -m 700 /RUTA_PRIVADA/backup-v2
bin/verify-backup --upgrade-legacy /RUTA_PRIVADA/backup-v1 /RUTA_PRIVADA/backup-v2
```

Si el backup anterior nunca incluyó originales remotos, la comprobación falla; recuperar esos objetos desde su almacenamiento original. No subir directorios v1 en claro a R2.

## Restaurar en un VPS nuevo o recuperar producción

1. Elegir backup y ejecutar la verificación anterior en el equipo de recuperación.
2. Preparar Hetzner, Docker, Kamal, DNS, secretos protegidos, PostgreSQL y volúmenes según [Producción](produccion_kamal.md). Usar la versión de aplicación indicada por el manifest y preparar bases/rol/schema vacíos, sin seeds demo. Preparar un mapa versionado por separado; el backup no lo contiene.
3. Descifrar para transferir por SSH sin llevar la identidad privada al VPS:

```sh
# En el equipo de recuperación; el destino no debe existir:
bin/backup-remote prepare "$BACKUP_DIR/$BACKUP_NAME" "$BACKUP_DIR/prepared-recovery"
# Contiene datos en claro bajo 0700. Copiar a un destino privado del usuario SSH:
scp -r "$BACKUP_DIR/prepared-recovery" "$DEPLOY_SSH_USER@$DEPLOY_HOST:~/app-repartos-recovery"
```

4. Activar mantenimiento y detener roles web/jobs con Kamal. En el VPS, cargar las variables de `/etc/app-repartos/backup.env` en un shell root sin imprimirlas. Confirmar expresamente ambas bases:

```sh
# En el VPS, desde un shell root:
set -a
source /etc/app-repartos/backup.env
set +a
export RESTORE_MAINTENANCE=1
export RESTORE_CONFIRM=app_repartos_production:app_repartos_production_queue
/usr/local/lib/app-repartos/bin/vps-restore /home/USUARIO_SSH/app-repartos-recovery
```

El comando rechaza roles Kamal web/jobs activos y conexiones a las bases, verifica primero con PostgreSQL temporal, prepara los archivos y genera una **copia previa cifrada** usando la clave pública antes de recrear/restaurar las dos bases. Exige `RESTORE_MAINTENANCE` y la confirmación exacta; `verify-backup` nunca toma este camino. La restauración real es destructiva y permanece separada de los tests. Un error puede dejar una recuperación incompleta: mantener mantenimiento y recuperar desde la copia elegida o la previa cifrada. El directorio de archivos anterior se conserva con sufijo `before-restore`.

Por defecto preserva nombres de servicio Active Storage. Para recuperar objetos R2 materializados en el backup sobre Disk, elegir explícitamente `RESTORE_STORAGE_SERVICE=persistent` **antes** del comando. Esto cambia `active_storage_blobs.service_name` para usar los archivos restaurados; mantener `ACTIVE_STORAGE_SERVICE=persistent`. Si se conserva `r2`, reponer también sus credenciales y bucket originales mediante el procedimiento separado de secretos.

La restauración elimina las sesiones restauradas, desactiva todo consentimiento GPS y borra la última ubicación. Exige iniciar sesión y decidir nuevamente si se comparte ubicación: una copia anterior no debe resucitar accesos o consentimientos revocados después del backup. Conserva los grants y UUID offline; con los mismos secretos Rails y una cuenta autorizada, el repartidor puede volver a autenticarse y sincronizar operaciones pendientes. Revisar también estados de cuentas/permisos: reflejan la fecha del backup y deben contrastarse con las bajas posteriores antes de habilitar acceso.

5. Verificar empresas, usuarios, clientes, visitas, operaciones offline, fotos y firmas; revisar cola/jobs y mapa. Ejecutar migraciones solo con una versión de código compatible y un plan explícito. Iniciar web, comprobar acceso y adjuntos privados; iniciar jobs después de revisar sus efectos pendientes. Quitar mantenimiento y comprobar PWA/sincronización.
6. Borrar los directorios preparados en claro en ambos equipos y revisar permisos UID/GID (1000 por defecto). Conservar el backup cifrado original y la copia previa hasta confirmar recuperación. Documentar hora/pérdida de datos observada y actualizar monitoreo.

No se ejecutó restauración ni despliegue productivo en este trabajo.

## Verificación técnica reproducible

```sh
python3 -m unittest discover -s test/backup -p 'test_*.py'
bin/check-backup-scripts
# Requiere stack de desarrollo, Docker, age, rclone y Python en el host:
bin/test-backups
```

La integración usa **dos bases desechables con nombres fijos de prueba**, archivos y remotes rclone locales. Prueba cifrado age real, subida/lectura, adjuntos Disk/R2 simulados, restauración aislada y comando protegido contra destinos desechables, revocación de sesiones/GPS restaurados, errores, retención y webhook local. No reemplaza una prueba real de R2/IAM, systemd en Hetzner ni una recuperación con datos y tiempos del cliente. Las claves de prueba se generan en un temporal y se eliminan.

Resultado de la ejecución local completa del 15/11/2026: [verificación de recuperación](benchmarks/backup-recovery-local.json). Las comprobaciones aprobaron con cifrado age y PostgreSQL reales; el backend remoto fue una carpeta rclone local, no R2.
