# App Repartos

Monolito Rails **8.1.4.1**, Ruby **3.4.12**, PostgreSQL **18**, Hotwire (Turbo + Stimulus), Tailwind CSS y **Solid Queue**. Desarrollo con Docker Compose; producción prevista en Hetzner con Capistrano, Puma y systemd. Sin Sidekiq, Redis ni Kamal.

## Desarrollo local

Requiere Docker Engine y Docker Compose. Desde esta carpeta:

```sh
docker compose up --build -d
```

Abrir **http://localhost:3006**. El servicio `setup` prepara las bases, carga datos de ejemplo en una instalación nueva y compila Tailwind antes de iniciar Rails y el worker. `css` recompila los estilos al editar. PostgreSQL y los jobs persisten en volúmenes; únicamente Rails publica un puerto, enlazado a localhost.

Cuentas de demostración, exclusivas del entorno de desarrollo:

| Empresa | Email | Contraseña |
| --- | --- | --- |
| Distribuidora Sur | `admin@repartos.test` | `Repartos-demo-2026` |
| Distribuidora Norte | `norte@repartos.test` | `Repartos-demo-2026` |

Cada cuenta ve su propio directorio. Para volver a ejecutar los seeds sin sobrescribir registros existentes:

```sh
docker compose exec web bin/rails db:seed
```

Comandos habituales:

```sh
docker compose logs -f web worker
docker compose exec web bin/rails console
docker compose exec web bin/rails db:migrate
docker compose exec web bin/rails test
docker compose exec web bin/rubocop
docker compose exec web bin/brakeman --no-pager
docker compose down
```

`docker compose down` conserva los datos. Agregar `--volumes` elimina las bases locales. Tras cambiar Gemfile/Gemfile.lock, reconstruir la imagen y actualizar el volumen de gems con `docker compose run --rm --no-deps setup bundle install` antes de iniciar los servicios.

## Funcionalidad inicial

- Inicio y cierre de sesión con el generador de autenticación de Rails.
- Empresas y usuarios con roles administrador, supervisor y repartidor. Cada usuario pertenece a una empresa; su email de acceso es único en el sistema.
- Listado de clientes en tarjetas, búsqueda por comercio/contacto/ciudad/teléfono, filtro por estado y paginación de 12 registros.
- Alta y edición con validación en servidor y consulta de los datos de un cliente. Modal accesible mediante Turbo Frames y un diálogo HTML nativo; las URLs también admiten acceso directo.
- Administradores y supervisores pueden administrar clientes. El rol repartidor tiene restringido el panel de clientes.

Las consultas y altas parten de `Current.company.customers`. La empresa se resuelve desde la sesión autenticada y no se acepta en los parámetros del formulario. Las claves foráneas y restricciones de estado/rol refuerzan la integridad en PostgreSQL. Los índices del directorio empiezan por `company_id`. Al agregar nuevas funciones, sus consultas, autorizaciones, streams y jobs también deben respetar la empresa; los jobs deben recibir un identificador explícito y no depender del contexto HTTP de `Current`.

El diseño usa `docs/mockups/dashboard_admin.html`. Se revisó también `docs/mockups/pwa_repartidores.html`: la PWA offline, rutas, repartos, visitas y sincronización quedan para las siguientes etapas. Las métricas actuales muestran datos reales del directorio, sin simular repartos todavía inexistentes. La dirección corresponde al lugar de entrega del comercio, según el modelo de distribuidora del resumen técnico.

## Solid Queue

Corre como proceso independiente (`worker`, comando `bin/jobs`). Usa una base de jobs separada (`app_repartos_development_queue`) dentro del mismo servidor PostgreSQL. La base principal guarda los datos del negocio. `db:prepare` crea ambas; `db/queue_schema.rb`, `config/queue.yml` y `config/recurring.yml` definen la infraestructura de la cola. Los tests de comportamiento usan el adaptador de Active Job `test`.

## Hetzner / Capistrano

Esta primera etapa incluye configuración y plantillas; **no se realizó un despliegue ni se aprovisionó un VPS**. Hay que definir repositorio Git, host y dominio reales antes de preparar producción.

El contrato de las plantillas en `config/deploy/templates/` es Ubuntu LTS, usuario `deploy`, Ruby/Bundler en `/opt/ruby/bin`, aplicación en `/var/www/app_repartos`, PostgreSQL local y Caddy apuntando a Puma en `127.0.0.1:3000`. La producción ejecuta Rails y Solid Queue directamente con systemd.

Antes del primer despliegue:

1. Preparar Ruby y dependencias del sistema (compilador, libpq, libvips), PostgreSQL y Caddy. Crear las bases `app_repartos_production` y `app_repartos_production_queue` y el usuario de la aplicación.
2. Crear `/var/www/app_repartos/shared/.env.production` basándose en `.env.example`, con las dos URLs de base de datos y un `SECRET_KEY_BASE` generado con `bin/rails secret`. Usar permisos `600` para `deploy`. No subirlo a Git. El archivo debe ser compatible con Bash y systemd (`CLAVE=valor`, sin `export`; entrecomillar valores cuando corresponda).
3. Ajustar e instalar las unidades systemd y el dominio en Caddy. Autorizar a `deploy` mediante sudoers únicamente a reiniciar los dos servicios. Verificar la clave SSH del servidor y el acceso de lectura al repositorio.
4. Crear el primer usuario y empresa con credenciales propias. Los seeds de desarrollo no se ejecutan en producción. No se incluyó registro público ni recuperación de contraseña en esta etapa.
5. Definir y probar backups y restauración de ambas bases y del almacenamiento antes de usar datos reales.

Con esos requisitos resueltos, desde el equipo que despliega:

```sh
export DEPLOY_REPO_URL=git@github.com:ORGANIZACION/REPOSITORIO.git
export DEPLOY_HOST=HOST_REAL
export DEPLOY_USER=deploy
bundle exec cap production deploy:check
bundle exec cap production deploy
```

Capistrano instala gems, compila assets, migra las bases y publica releases; después reinicia Puma y Solid Queue. `bin/bundle-production` carga el archivo compartido de entorno para los comandos remotos. `DEPLOY_BRANCH` permite elegir una rama (predeterminado: `main`). No ejecutar seeds demo en producción. La conexión y el despliegue real deben verificarse contra el VPS cuando esté definido.


## Direcciones y coordenadas

El alta y la edición incluyen búsqueda de direcciones con **Photon**, mapa **Leaflet 1.9.4** sobre OpenStreetMap y un marcador ajustable con clic o arrastre. La selección completa dirección y ciudad; conserva el nombre del comercio si ya fue ingresado. Las búsquedas se ejecutan desde el navegador después de 350 ms y 3 caracteres, priorizando el centro del mapa y limitando resultados a Argentina y Uruguay, como en el ejemplo suministrado. No se envían teléfono, email ni identificadores de empresa a Photon. Las respuestas antiguas se descartan y las búsquedas tienen cancelación y timeout.

Las coordenadas `latitude` y `longitude` se guardan en PostgreSQL con 7 decimales. Son obligatorias al guardar desde el alta o la edición, y se pueden ingresar directamente si no se encuentra la dirección o el servicio no responde. El detalle muestra el punto guardado y ofrece acceso a la edición. Cambiar la dirección o ciudad invalida el punto anterior: hay que ubicarlo de nuevo o confirmarlo en el mapa. La validación del servidor también impide reutilizar un punto sin confirmar al cambiar una dirección.

La migración preserva los clientes existentes con ambas coordenadas vacías, sin inventarles una ubicación. Se muestran como “Ubicación pendiente” hasta completarlos al editar. Los seeds conservan ese comportamiento. El contexto de validación `:geocoded` se exige en ambas acciones de guardado del panel; el modelo y PostgreSQL validan siempre el par y sus rangos. El campo transitorio `location_confirmed` registra una confirmación explícita en el formulario cuando el texto cambió pero el punto es el mismo; no es una columna ni sustituye los controles de empresa y rol.

Para aplicar el cambio en una instalación existente:

```sh
docker compose exec web bin/rails db:migrate
```

Leaflet y su CSS se sirven localmente desde el proyecto, con su licencia en `vendor/javascript/leaflet.LICENSE`. Photon y las imágenes del mapa requieren conexión. `PHOTON_URL` y `OSM_TILES_URL` permiten apuntar a instancias propias (reiniciar/recrear los servicios tras cambiar variables). Valores predeterminados: `https://photon.komoot.io/api/` y `https://tile.openstreetmap.org/{z}/{x}/{y}.png`.

La integración usa el [API de Photon](https://github.com/komoot/photon/blob/master/docs/api-v1.md), cuyo [servidor público](https://github.com/komoot/photon#demo-server) no garantiza disponibilidad y puede limitar uso intensivo. El mapa conserva la atribución de OpenStreetMap y utiliza la caché normal del navegador, sin descargas anticipadas ni almacenamiento offline de tiles; ver la [política de tiles](https://operations.osmfoundation.org/policies/tiles/). Los datos de reparto offline de la futura PWA son una función independiente.
