# App Repartos

Monolito Rails **8.1.4.1**, Ruby **3.4.12**, PostgreSQL **18**, Hotwire (Turbo + Stimulus), Tailwind CSS y **Solid Queue**. Desarrollo con Docker Compose; producción preparada para un único VPS Hetzner con Docker, Kamal 2, Puma y Kamal Proxy. Sin Sidekiq, Redis ni servicios de optimización comerciales.

Alcance del producto, cobertura AMBA, pasos para ofrecerlo en otras provincias y condiciones de uso: [Decisiones y limitaciones funcionales](docs/decisiones_y_limitaciones_funcionales.md).

Los estados, el cumplimiento por producto, la reprogramación y la autoría de las visitas están documentados en [Entregas y auditoría](docs/entregas_y_auditoria.md).

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

## Integración continua

GitHub Actions ejecuta `bin/ci` en cada push y pull request: prepara ambas bases PostgreSQL 18, compila CSS y verifica Minitest, JavaScript, navegación offline con Chromium, RuboCop, Brakeman y las auditorías de gems, importmap y npm. Cualquier fallo deja el pipeline en rojo. Usa Ruby de `.ruby-version` (3.4.12), Node 24.19.0 y los lockfiles; no incluye deploy.

Para ejecutar las mismas comprobaciones localmente, incluidos el navegador y sus dependencias, sólo se necesita Docker Compose:

```sh
docker compose -f compose.ci.yml up --build --abort-on-container-exit --exit-code-from ci
```

El comando devuelve el código de salida de CI. El proyecto Compose `app_repartos_ci` usa PostgreSQL temporal, sin puertos públicos ni volúmenes compartidos con desarrollo. Después de revisar el resultado:

```sh
docker compose -f compose.ci.yml down --volumes --remove-orphans
```

Detalles de las comprobaciones, diagnóstico de fallos y ejecución sin contenedor: [CI](docs/ci.md).

## Funcionalidad inicial

- Inicio y cierre de sesión con el generador de autenticación de Rails.
- Empresas y usuarios con roles administrador, supervisor y repartidor. Cada usuario pertenece a una empresa; su email de acceso es único en el sistema.
- Listado de clientes en tarjetas, búsqueda por comercio/contacto/ciudad/teléfono, filtro por estado y paginación de 12 registros.
- Alta y edición con validación en servidor y consulta de los datos de un cliente. Modal accesible mediante Turbo Frames y un diálogo HTML nativo; las URLs también admiten acceso directo.
- Administradores y supervisores pueden administrar clientes. El rol repartidor tiene restringido el panel de clientes.

Las consultas y altas parten de `Current.company.customers`. La empresa se resuelve desde la sesión autenticada y no se acepta en los parámetros del formulario. Las claves foráneas y restricciones de estado/rol refuerzan la integridad en PostgreSQL. Los índices del directorio empiezan por `company_id`. Al agregar nuevas funciones, sus consultas, autorizaciones, streams y jobs también deben respetar la empresa; los jobs deben recibir un identificador explícito y no depender del contexto HTTP de `Current`.

El diseño usa `docs/mockups/dashboard_admin.html`. La interfaz del repartidor conserva `docs/mockups/pwa_repartidores.html` como referencia y ya permite trabajar offline con sincronización segura. Las métricas actuales muestran datos reales del directorio, sin simular repartos todavía inexistentes. La dirección corresponde al lugar de entrega del comercio, según el modelo de distribuidora del resumen técnico.

## Solid Queue

Corre como proceso independiente (`worker`, comando `bin/jobs`). Usa una base de jobs separada (`app_repartos_development_queue`) dentro del mismo servidor PostgreSQL. La base principal guarda los datos del negocio. `db:prepare` crea ambas; `db/queue_schema.rb`, `config/queue.yml` y `config/recurring.yml` definen la infraestructura de la cola. Los tests de comportamiento usan el adaptador de Active Job `test`.

## Producción con Kamal

El procedimiento oficial es Docker + Kamal 2.12, con PostgreSQL 18, worker Solid Queue, OSRM y Kamal Proxy en el mismo VPS. El registry local de Kamal mantiene privadas las imágenes sin contratar un registro. No se realizó un despliegue real: IP, dominio, usuario SSH y secretos deben aportarse para el servidor elegido.

La imagen `production` escucha en `0.0.0.0:3000`, compila assets y corre sin root. PostgreSQL y OSRM no publican puertos. Los adjuntos privados se conservan en un volumen del VPS; una instalación que ya usa R2 puede seleccionar explícitamente ese servicio, sin perder la integración existente.

Comprobaciones locales:

```sh
docker build --target production -t app-repartos-production:verify .
docker compose exec web bin/validate-deploy
```

Preparación de Ubuntu, secretos, primer despliegue, migraciones, actualización, rollback y restauración: [Producción con Kamal](docs/produccion_kamal.md). No hay dos procedimientos de producción: se retiraron las dependencias y plantillas anteriores de Capistrano.

## OSRM y optimización de una hoja existente

La planificación manual y la distribución multivehículo existente con VROOM se conservan. Desde el detalle de una hoja editable, **Optimizar ruta** solicita una propuesta en Solid Queue. Compara conducción vial, distancia, atención, espera, horarios y restricciones. Confirmar cambia únicamente posiciones mediante `DeliveryRunReorderer`; una propuesta desactualizada no se aplica.

**Confirmar y optimizar**, disponible en el cierre del asistente y en una hoja editable, prepara y publica el orden definitivo en segundo plano. La PWA espera ese resultado; las modificaciones relevantes solicitan otra preparación antes de la ejecución. Las matrices viales, soluciones y trazados se reutilizan por empresa y versión de mapa. Cambiar nombres, precios o cantidades no obliga a repetir la optimización. También se puede publicar expresamente el orden manual.

Preparación explícita del mapa AMBA (primera vez):

```sh
bin/routing download
bin/routing prepare
# El comando anterior imprime VERSION; usar ese valor en el siguiente comando.
bin/routing activate VERSION
docker compose --profile routing up -d osrm web worker css
bin/test-osrm
docker compose exec web bin/rails db:seed
```

Los seeds agregan escenarios **Demo OSRM** sin reemplazar datos existentes. OSRM nunca descarga/procesa mapas durante `docker compose up`, ni bloquea el arranque del panel. Sin OSRM, los cálculos fallan con un mensaje recuperable y la planificación manual sigue disponible.

Documentación de mapas, algoritmo, límites, configuración, tests reales y benchmarks: [OSRM y optimización](docs/osrm.md).

## Direcciones y coordenadas

El alta y la edición incluyen búsqueda de direcciones con **Photon**, mapa **Leaflet 1.9.4** sobre OpenStreetMap y un marcador ajustable con clic o arrastre. La selección completa dirección y ciudad; conserva el nombre del comercio si ya fue ingresado. Las búsquedas se ejecutan desde el navegador después de 350 ms y 3 caracteres, priorizando el centro del mapa y limitando resultados a Argentina y Uruguay, como en el ejemplo suministrado. No se envían teléfono, email ni identificadores de empresa a Photon. Las respuestas antiguas se descartan y las búsquedas tienen cancelación y timeout.

Las coordenadas `latitude` y `longitude` se guardan en PostgreSQL con 7 decimales. Son obligatorias al guardar desde el alta o la edición, y se pueden ingresar directamente si no se encuentra la dirección o el servicio no responde. El detalle muestra el punto guardado y ofrece acceso a la edición. Cambiar la dirección o ciudad invalida el punto anterior: hay que ubicarlo de nuevo o confirmarlo en el mapa. La validación del servidor también impide reutilizar un punto sin confirmar al cambiar una dirección.

La migración preserva los clientes existentes con ambas coordenadas vacías, sin inventarles una ubicación. Se muestran como “Ubicación pendiente” hasta completarlos al editar. Los seeds conservan ese comportamiento. El contexto de validación `:geocoded` se exige en ambas acciones de guardado del panel; el modelo y PostgreSQL validan siempre el par y sus rangos. El campo transitorio `location_confirmed` registra una confirmación explícita en el formulario cuando el texto cambió pero el punto es el mismo; no es una columna ni sustituye los controles de empresa y rol.

Para aplicar el cambio en una instalación existente:

```sh
docker compose exec web bin/rails db:migrate
```

Leaflet y su CSS se sirven localmente desde el proyecto, con su licencia en `vendor/javascript/leaflet.LICENSE`. Photon y las imágenes del mapa requieren conexión. `PHOTON_URL` y `OSM_TILES_URL` permiten apuntar a instancias propias (reiniciar/recrear los servicios tras cambiar variables). Valores predeterminados: `https://photon.komoot.io/api/` y `https://tile.openstreetmap.org/{z}/{x}/{y}.png`.

La integración usa el [API de Photon](https://github.com/komoot/photon/blob/master/docs/api-v1.md), cuyo [servidor público](https://github.com/komoot/photon#demo-server) no garantiza disponibilidad y puede limitar uso intensivo. El mapa conserva la atribución de OpenStreetMap y utiliza la caché normal del navegador, sin descargas anticipadas ni almacenamiento offline de tiles; ver la [política de tiles](https://operations.osmfoundation.org/policies/tiles/). Los datos de reparto offline se gestionan de forma independiente mediante IndexedDB; los mapas públicos no se precachean.

## PWA offline del repartidor

En `/repartidor`, iniciar sesión con conexión y esperar **Datos descargados** y **Acceso offline preparado**. Las visitas se guardan primero en el dispositivo tanto online como offline, sobreviven al cierre y reapertura de la PWA y se sincronizan al abrir, recuperar conectividad, volver al primer plano o pulsar **Sincronizar ahora**. Requiere HTTPS o localhost.

La cola usa UUID e IndexedDB separado por empresa/usuario. Rails procesa cada UUID de forma atómica e idempotente. Las descargas firmadas permiten sincronizar hasta 48 horas después, incluso al día siguiente; una reasignación, cambio de planificación, visita ya registrada o descarga vencida produce un conflicto conservado. Administración lo revisa en **Sincronizaciones**. No hay GPS ni sincronización garantizada con la app cerrada.

El Service Worker sólo cachea recursos públicos y el shell. Los datos privados, presentaciones de hojas y operaciones están en IndexedDB; no se borran al actualizar ni al cerrar sesión. Con registros pendientes se avisa antes de salir. El navegador puede revocar almacenamiento: revisar/sincronizar o exportar registros antes de borrar datos del sitio.

Arquitectura, API, política de conflictos, comandos de tests y pruebas manuales pendientes de Android y Safari/iPhone: [PWA offline](docs/pwa_offline.md). Se verifica automáticamente con Rails, JavaScript y Chromium; eso no valida todavía dispositivos físicos ni iOS.
