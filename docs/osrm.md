# OSRM y optimización de hojas de ruta

La aplicación conserva la planificación manual y la optimización multivehículo existente con VROOM. Esta funcionalidad optimiza el orden de una hoja ya creada, con un repartidor y entre 1 y 100 visitas. Una visita puede agrupar varios pedidos. No se crean copias de pedidos ni se alteran cantidades al aplicar el orden.

## Iniciar desarrollo

Requisitos del host: Docker con Compose y Buildx, Bash, `flock`, `sha256sum`, `realpath` y conexión para la primera descarga. No se instalan OSRM, Osmium, PostgreSQL ni paquetes Ruby de forma manual en el host.

```sh
docker compose build
docker compose up -d
# Con una instalación previa:
docker compose exec web bin/rails db:migrate
bin/routing download
bin/routing prepare
```

La última línea imprime un identificador VERSION. Copiar ese valor:

```sh
bin/routing activate VERSION
docker compose --profile routing up -d osrm web worker css
docker compose ps
docker compose logs --tail 50 osrm web worker
bin/test-osrm
docker compose exec web bin/rails db:seed
```

Abrir http://localhost:3006 y entrar con la cuenta demo indicada en README. En **Hojas de ruta**, los escenarios llevan el prefijo **Demo OSRM**. Abrir una hoja pendiente y elegir **Optimizar ruta**. Revisar origen, hora y regreso; solicitar, esperar, comparar y confirmar o descartar. Se puede salir de la pantalla durante el cálculo y regresar desde el historial de propuestas de la hoja.

`compose.yml` incluye OSRM bajo el perfil `routing`, sin puertos publicados y sin `depends_on` de Rails hacia OSRM. `OSRM_URL=http://osrm:5000` es el destino interno. El panel, la PWA y el trabajo manual arrancan aunque el mapa no esté preparado. El fallo de optimización es explícito y recuperable. No hay distancia Haversine ni proveedor público de respaldo.

Para mantener el asistente multivehículo existente:

```sh
docker compose -f compose.yml -f compose.routing.yml up -d osrm vroom web worker
```

## Mapas y actualizaciones

La fuente inicial es [Geofabrik Argentina](https://download.geofabrik.de/south-america/argentina.html), basada en OpenStreetMap. `config/routing/region.env` fija la imagen oficial `ghcr.io/project-osrm/osrm-backend:v6.0.0`, perfil `/opt/car.lua`, MLD y bbox AMBA `-59.10,-35.25,-57.65,-34.15` (oeste, sur, este, norte). Incluye CABA y áreas norte, oeste y sur. La cobertura es geográfica, no una promesa de acceso a todas las calles privadas o caminos sin conexión.

Se puede sobrescribir la configuración mediante variables de entorno o un archivo local `.env.routing`, ignorado por Git:

```sh
# Ejemplo de contenido de .env.routing; bbox vacío procesa Argentina completa.
OSRM_BBOX=""
OSRM_THREADS=2
OSRM_BUILD_MEMORY=8g
OSRM_SERVE_MEMORY=8g
```

El toolbox se construye desde Debian con Osmium, Python y certificados. Verifica el MD5 publicado por Geofabrik sobre HTTPS y la estructura PBF. Una descarga parcial utiliza otro nombre y nunca reemplaza un archivo válido. El MD5 se usa para detectar corrupción de transporte, no como firma criptográfica del editor.

`prepare` recorta con `osmium extract --strategy smart`, ejecuta `osrm-extract`, `osrm-partition` y `osrm-customize` en un directorio temporal. Guarda un manifest con imagen, versión, bbox, perfil y algoritmo. La clave de la versión depende del SHA-256 del PBF y la configuración; la misma entrada reutiliza el resultado. Una prueba con un servidor OSRM temporal exige matriz de duraciones y distancias reales no nulas antes de activar.

```sh
bin/routing update
docker compose stop worker
bin/routing activate NUEVA_VERSION
docker compose --profile routing restart osrm
bin/test-osrm
docker compose start worker
# Si algo falla después de activar:
docker compose stop worker
bin/routing rollback
docker compose --profile routing restart osrm
bin/test-osrm
docker compose start worker
```

`update` consulta el checksum y evita descargar de nuevo si no cambió. También se puede procesar un archivo propio:

```sh
bin/routing prepare /ruta/absoluta/region.osm.pbf
bin/routing validate VERSION
bin/routing status
```

No se eliminan automáticamente versiones anteriores. `storage/routing/current` cambia mediante un enlace atómico; OSRM carga el nuevo mapa tras reiniciar. Un fallo de descarga, preparación o validación conserva el mapa activo. El reinicio de OSRM tiene una interrupción breve; la administración continúa funcionando. Se deben conservar al menos la versión activa y la anterior. En un recorte diferente, ajustar `OSRM_CHECK_COORDINATES` a dos puntos conectados de esa región para la validación.

Para aumentar la memoria del servidor local, exportar también `OSRM_SERVE_MEMORY` al ejecutar Compose (por ejemplo, `OSRM_SERVE_MEMORY=8g docker compose --profile routing up -d osrm`). `.env.routing` configura los scripts; Compose no lee ese archivo automáticamente. El healthcheck predeterminado usa CABA, por lo que un recorte que la excluya requiere adaptar también ese punto en la configuración de Compose/Kamal.

Recursos orientativos, sujetos al tamaño real del extracto: AMBA suele requerir varios GB durante preparación; el script limita por defecto a 4 GiB/2 CPU y el servidor a 2 GiB/2 CPU. Reservar al menos 10–20 GB libres para descarga, temporales y dos versiones; medir los manifests/directorios generados. Argentina completa exige más memoria/disco: aumentar límites según medición antes de procesarla, sin cambiar Rails. No se garantiza que quepa en 4/8 GiB. Puede prepararse en el equipo local y transferirse; no requiere otro servicio permanente. Para el conjunto Rails/PostgreSQL/worker/OSRM, comenzar con un VPS de 8 GiB y ajustar con datos reales; preparar mapas grandes fuera del VPS evita competir con producción.

### Lectura del mapa con `--mmap=true`

Compose, la variante VROOM, el servidor de prueba, la validación temporal de mapas y el accessory de Kamal usan `--mmap=true`. En OSRM **v6.0.0** hay que indicar el valor booleano: `--mmap` seguido directamente por la ruta del mapa intenta interpretar esa ruta como su valor y falla al iniciar.

El servidor mapea los archivos del release de solo lectura y accede a las páginas necesarias. Esto reduce la copia privada del mapa; las páginas de archivos pueden permanecer en la caché de Linux y recuperarse bajo presión de memoria. No significa que OSRM deje de usar RAM, que el consumo sea constante ni que el servicio se detenga cuando no hay optimizaciones. También atiende las consultas de ETA. El límite `OSRM_SERVE_MEMORY=2g` se conserva: es un máximo, no una reserva permanente. No se cambian la preparación, la versión del mapa ni las claves de la caché de Rails.

Usar SSD y medir la primera consulta y las consultas repetidas al dimensionar otra región. Conservar los releases inmutables: preparar otra versión y cambiar `current` con el procedimiento anterior; no sobrescribir ni borrar archivos del mapa que está sirviendo OSRM. Al cambiar solo esta opción de ejecución no hace falta reprocesar el mapa. Para aplicarla a un servicio local ya creado:

```sh
docker compose --profile routing up -d --no-deps osrm
bin/test-osrm
```

Esta recreación produce una interrupción breve de OSRM; conviene hacerla sin cálculos en curso. Reiniciar un contenedor existente sin recrearlo no cambia sus argumentos. En producción, aplicar mediante el procedimiento de Kamal, después de revisar el cambio; modificar el archivo local no actualiza el servidor remoto.

## Criterios y garantías

- Las matrices `/table/v1/driving` contienen segundos y metros de caminos de conducción; los arcos pueden ser asimétricos. Un `null` es una conexión inexistente, nunca cero. Se hace una consulta matricial completa, no una por cada par.
- `/route/v1/driving` agrega geometría GeoJSON y tramos. Se dibuja un esquema numerado del recorrido vial sin usar servidores públicos de teselas. No pretende mostrar un mapa base completo. La atribución a OpenStreetMap se conserva.
- Las franjas `window_start/window_end` son obligatorias. La ventana regula el **inicio de atención**; se puede esperar si se llega temprano y terminar de descargar después del cierre de la ventana. La duración de atención se suma después.
- `preferred_time` es una preferencia **blanda**, con tolerancia inicial de 15 minutos. Cada segundo fuera de la tolerancia agrega dos segundos a la función objetivo. No se convierte silenciosamente en una ventana obligatoria. El asistente multivehículo previo conserva su propio contrato existente.
- La atención suma `service_minutes` de todos los pedidos de la visita. Las paradas sin pedidos usan el valor por empresa (5 minutos inicialmente).
- Los horarios locales se convierten a instantes de la fecha de la hoja. Conducción, atención y espera usan segundos realmente transcurridos, incluso en días de cambio de hora. Se rechazan horas locales ambiguas o inexistentes para no elegir una interpretación silenciosamente. Las franjas mantienen la restricción actual del modelo: inicio y fin dentro del mismo día.
- Sin depósito no se inventa uno: el recorrido abierto comienza a atender en el primer cliente a la hora indicada y omite el traslado previo. Con depósito se incluye la salida y, opcionalmente, el regreso. Cada propuesta permite elegir; la empresa guarda los valores predeterminados. Los horarios se interpretan en la zona local configurada.
- Hasta 7 paradas se evalúan todas las permutaciones. Para hojas mayores se usa nearest neighbor con distintos comienzos, inserción por restricciones, 2-opt y relocate. Se evalúa cada movimiento sobre arcos dirigidos completos. La búsqueda es determinista y tiene un presupuesto de 18.000 evaluaciones para la mejora local; la preparación de candidatos también se contabiliza.
- La comparación prioriza cantidad de restricciones obligatorias incumplidas y magnitud de la infracción. Entre soluciones viables minimiza duración total + penalización de preferencias; conducción y metros desempatan. No afirma un óptimo global para la heurística. Ante igualdad conserva el orden original.
- Una propuesta no viable nunca permite confirmar. Si no hay mejora, se recomienda conservar el orden actual. Métricas de recorridos desconectados se marcan parciales/no viables y no sirven como ahorro válido.
- Distancia: suma de arcos viales. Conducción: suma de sus duraciones. Atención: suma de servicios. Espera: anticipación a ventanas. Total: conducción + atención + espera. Diferencia: actual − propuesto; porcentaje: diferencia / actual × 100, sin porcentaje cuando actual es cero. Un aumento de kilómetros puede ser aceptable si mejora tiempo o respeta una ventana, y se muestra con signo negativo.

## Persistencia, seguridad y operación

### Confirmación y publicación automática

**Confirmar y optimizar** en el cierre del asistente o en una hoja editable crea/actualiza `RoutePublication` y encola `PrepareRoutePublicationJob`. La respuesta no espera OSRM. La preparación reutiliza `RouteOptimizationProposal` y `OptimizeDeliveryRunJob`; una propuesta viable se aplica con la autorización del administrador/supervisor que confirmó y luego se publica. Se revalidan su rol/estado, el repartidor activo, la edición de la hoja y los datos bajo los bloqueos de planificación. Los encolados se difieren hasta el commit de la transacción.

`RoutePublication` mantiene estados `pending`, `ready`, `failed`, `manual`, configuración e identidad de entradas y propuesta actual. La PWA excluye hojas pendientes/fallidas y ambos registradores de ejecución rechazan descargas anteriores. Los cambios relevantes invalidan la autorización de descarga y la publicación dentro de la misma transacción, y encolan preparación tras el commit. Un job viejo no puede publicar si perdió su vínculo con la publicación actual. Las jornadas iniciadas no se optimizan. Ante fallo se puede corregir/reintentar o usar **Publicar con orden manual**; un reordenamiento manual también desactiva la publicación automática.

La vista de la hoja consulta un endpoint de estado liviano cada tres segundos mientras está pendiente. Consultar una hoja lista no calcula otra ruta. El flujo anterior de propuesta con revisión/aplicación explícita sigue disponible. Las hojas manuales preexistentes mantienen su comportamiento.

### Reutilización de datos viales y soluciones

`RoutingCacheEntry` guarda tres clases de datos en PostgreSQL, siempre por empresa: matrices sobre coordenadas ordenadas canónicamente, candidatos de solución según paradas/ventanas/atención/salida/depósito/tolerancia, y geometrías según el recorrido ordenado. Los nombres, precios y cantidades no forman parte de la identidad de optimización. La huella completa de ejecución sigue protegiendo la aplicación; una edición ajena al cálculo puede reutilizar un resultado en el flujo automático después de revalidar esa huella. El orden original se evalúa nuevamente contra el candidato guardado para conservar un orden manual mejor o equivalente.

Las claves incluyen proveedor, perfil, versión del mapa e identidad del algoritmo. La versión se obtiene del manifest montado en `storage/routing/current/manifest.json`. Para un OSRM externo sin manifest, establecer `OSRM_MAP_VERSION` y actualizarlo al cambiar el mapa; sin una versión conocida se omite la caché persistente. Un bloqueo asesor por clave evita duplicar un fallo de caché concurrente y el índice único protege PostgreSQL. Las inserciones del cálculo se revierten si falla o cambia la versión del mapa durante el trabajo. Nunca se guarda una respuesta fallida como una matriz vacía.

Solid Queue limita globalmente a una optimización pesada simultánea. La limpieza programada elimina solo entradas sin uso durante 90 días; nunca elimina resultados históricos de propuestas. Las propuestas de vista previa siguen venciendo a los 30 minutos, pero ese vencimiento no obliga a recalcular una ruta aplicada y vigente. El mantenimiento detecta también publicaciones editables calculadas con una versión anterior del mapa y solicita preparación.

Al actualizar el mapa, detener temporalmente el worker antes de activar la versión, reiniciar OSRM y comprobarlo, y recién entonces iniciar/reiniciar el worker. Así no se mezcla el manifest nuevo con un servidor que todavía tenga cargado el mapa anterior. En Kamal el directorio de mapas también se monta como solo lectura en web/jobs. Migraciones nuevas: `20261116021000_add_route_publications_and_routing_cache` y `20261116021100_use_input_digest_for_routing_cache`; aplicar y reiniciar web/worker juntos antes de usar la confirmación automática.

`RouteOptimizationProposal` guarda empresa, hoja, solicitante, parámetros normalizados, fingerprint, resultado, error, vigencia y usuario/fecha de aplicación. El fingerprint incluye hoja, visitas/posiciones, ejecución, pedidos, líneas, ubicaciones, horarios y configuración. Los reintentos con la misma entrada reutilizan un cálculo activo. Las propuestas caducan a los 30 minutos.

`OptimizeDeliveryRunJob` recibe empresa/propuesta explícitas, calcula sin bloquear la empresa durante HTTP/CPU y verifica nuevamente la huella al guardar. `RouteProposalMaintenanceJob` vence propuestas y recupera cálculos interrumpidos; Solid Queue limita concurrencia por propuesta. Se puede solicitar otro cálculo tras un fallo.

Confirmar bloquea empresa, propuesta, hoja, ubicaciones de los clientes y programaciones históricas utilizadas; revalida permisos/edición/huella y llama a `DeliveryRunReorderer` dentro de la misma transacción. Las ubicaciones y ventanas quedan protegidas incluso cuando su editor no usa el bloqueo de planificación de la empresa. Solo cambian posiciones y timestamps de visitas. Se conservan pedidos, cantidades, precios/costos, fechas, repartidor, notas, estados y auditoría de ejecución. Una aplicación repetida devuelve la misma confirmación. Dos propuestas incompatibles no pueden sobrescribirse: la segunda detecta el cambio. Se permite reordenamiento manual posterior. La PWA descarga el orden confirmado mediante el mecanismo existente de actualizaciones; un formulario o entrega offline obsoletos mantienen las protecciones de conflicto anteriores.

No se aceptan URLs del proveedor en parámetros HTTP. Los repartidores no acceden a configuración, propuestas ni acciones administrativas; todos los recursos parten de la empresa autenticada. OSRM acepta únicamente tráfico interno Docker. El cliente limita coordenadas, bytes y tiempos, no sigue redirects y reintenta una sola vez fallos transitorios contra el mismo destino. Las distancias no incluyen tráfico en vivo, restricciones específicas de camiones, clima ni cortes recientes no incorporados en el mapa.

Migración: `20261116020000_add_single_route_optimization`. Los cambios son aditivos; no hay backfill que reescriba ejecuciones anteriores.

## Tests y rendimiento

```sh
docker compose exec web bin/rails test
docker compose exec web bin/rails test test/services/osrm test/services/route_optimization test/controllers/single_route_optimizations_controller_test.rb test/jobs/route_proposal_maintenance_job_test.rb
docker compose exec web bin/rubocop
docker compose exec web bin/brakeman --no-pager
npm run test:js
npm run test:browser
```

La suite estándar usa matrices/HTTP simulados y no requiere OSRM ni servidores públicos. Para verificar el protocolo con un contenedor real y un grafo sintético diminuto, reproducible y local:

```sh
bin/test-osrm --fixture
```

El grafo está en `test/osrm_live/fixture.osm` y se identifica como sintético; no se presenta como calles reales. El servidor de prueba usa otro nombre y no reemplaza el mapa AMBA. Para comprobar el extracto real ya preparado y la comunicación desde Rails:

```sh
bin/test-osrm
docker compose exec web bin/benchmark-routing --live
```

Benchmarks con matrices precalculadas, sin HTTP:

```sh
docker compose exec web bin/benchmark-routing
```

Se informan tiempo de matriz, consultas matriciales, tiempo del algoritmo, evaluaciones y RSS del proceso (Linux), para 10/25/50/100 visitas. No se impone un tiempo máximo dependiente del hardware. RSS no es memoria incremental del algoritmo y las matrices sintéticas no representan tiempos de una ciudad específica.

Referencia medida con el extracto AMBA y puntos de prueba en CABA (no es una garantía de latencia):

| Paradas | Matriz OSRM | Algoritmo Ruby | Consultas de matriz |
| --- | --- | --- | --- |
| 10 | 0,20 s | 0,20 s | 1 |
| 25 | 0,48 s | 2,05 s | 1 |
| 50 | 1,17 s | 4,26 s | 1 |
| 100 | 2,42 s | 8,32 s | 1 |

En esa preparación, el PBF de Argentina ocupó aproximadamente 416 MiB, el release AMBA procesado 649 MiB y el mayor pico informado por OSRM fue aproximadamente 828 MiB. El contenedor de rutas utilizó alrededor de 490 MiB tras iniciar con un límite de 2 GiB. Los tamaños y consumos cambian con los datos y la carga.

Comparación local del 15/11/2026: misma imagen v6.0.0, release AMBA `5316c4d3c77ef88b7107`, MLD, dos hilos y límite de 2 GiB. Se comparó el servicio existente con otro contenedor aislado usando `--mmap=true`, sin modificar el mapa. Se alternaron ocho consultas por modalidad para cada uno de ocho casos: matrices de 10/25/50/100/101 ubicaciones en CABA, matriz de diez ubicaciones distribuidas por AMBA, recorrido con geometría y consulta de ETA. Las 128 respuestas coincidieron en matrices, ubicaciones ajustadas, distancias, tiempos y geometrías; se excluyeron de la comparación los identificadores opacos `hint`, que la aplicación no reutiliza.

| Memoria después de las consultas | Carga predeterminada | Con `--mmap=true` |
| --- | --- | --- |
| Residente del proceso (RSS) | 508 MiB | 88 MiB |
| Privada anónima del proceso | 501 MiB | 12 MiB |
| Páginas de archivos residentes del proceso | 7 MiB | 75 MiB |
| Total contabilizado al contenedor, incluida caché de archivos y memoria del kernel | 527 MiB | 225 MiB |

RSS y memoria del contenedor miden cosas diferentes. La caché puede compartirse entre contenedores y su contabilización depende de qué proceso leyó primero los archivos. `docker stats` además descuenta parte de la caché; no se debe presentar su cifra como toda la RAM utilizada ni interpretar el tamaño virtual como RAM física.

| Consulta | Mediana predeterminada | Mediana con mmap |
| --- | --- | --- |
| Matriz de 10 ubicaciones CABA | 0,155 s | 0,153 s |
| Matriz de 25 ubicaciones CABA | 0,411 s | 0,400 s |
| Matriz de 50 ubicaciones CABA | 0,977 s | 0,915 s |
| Matriz de 100 ubicaciones CABA | 1,604 s | 1,554 s |
| Matriz de 101 ubicaciones CABA | 1,789 s | 1,899 s |
| Matriz de 10 ubicaciones AMBA | 0,130 s | 0,136 s |
| Recorrido con geometría, 5 ubicaciones | 0,007 s | 0,007 s |
| ETA, 3 ubicaciones | 0,014 s | 0,014 s |

Las medianas usan las siete repeticiones posteriores a la primera. En la primera matriz distribuida por AMBA, mmap tardó 1,007 s frente a 0,257 s del servicio existente, que ya estaba iniciado y atendiendo consultas. No se vació la caché del host ni se simuló un arranque desde disco frío; no es una comparación controlada de latencia en frío ni una promesa de ahorro bajo cualquier carga. Los tiempos corresponden al motor vial, no incluyen el algoritmo Ruby de optimización.

Como prueba adicional de recuperación de caché, se redujo **solo el contenedor aislado** a 128 MiB. La integración Rails con matriz, geometría y optimizador pasó; tres consultas de 101 ubicaciones conservaron el resultado y tardaron 2,434/2,072/2,555 s. El total del contenedor quedó en 122 MiB, sin eventos de falta de memoria ni procesos terminados por ese motivo. Esto demuestra funcionamiento para esas consultas bajo ese límite, no dimensionamiento para producción, concurrencia, VROOM o regiones mayores. El límite configurado de servicio se mantiene en 2 GiB.

La verificación realizada incluyó la suite completa de 365 pruebas Rails (87 casos nuevos respecto de la base anterior), regresiones de bloqueos y cambios de hora, 32 pruebas JavaScript y los 15 escenarios de navegador, más la variante de navegador con OSRM real/Solid Queue. Una corrida amplia tuvo un timeout de login bajo carga de disco; ese caso pasó al repetirse aisladamente. Se verificaron también ambas bases restauradas en PostgreSQL 18 temporal, el grafo pequeño de OSRM, el extracto AMBA, RuboCop, Brakeman, compilación CSS, configuración nativa de Kamal y la imagen de producción: usuario sin root, migraciones, ausencia de seeds demo, archivos privados, heartbeat de Solid Queue y persistencia tras reiniciar. Los artefactos de las pruebas de navegador se excluyen del contexto Docker para no incluir trazas, cookies o capturas en imágenes.

Después de la suite opcional se puede retirar únicamente su servicio, conservando los servicios de desarrollo y sus datos:

```sh
docker compose -f compose.yml -f compose.osrm-test.yml stop osrm-test
docker compose -f compose.yml -f compose.osrm-test.yml rm --force osrm-test
```

## Diagnóstico

- **OSRM no configurado/no responde:** comprobar `OSRM_URL` dentro de web/worker, `docker compose --profile routing ps`, logs y `bin/test-osrm`. No usar URLs públicas para ocultar el fallo.
- **NoSegment/NoRoute:** revisar cobertura, accesibilidad vial y coordenadas. Se admite snap de hasta 1 km; una ubicación más distante debe corregirse, no ampliarse silenciosamente.
- **Proceso sin memoria:** revisar `docker inspect` y logs; reducir bbox, limitar hilos o procesar fuera del VPS. No borrar `current`.
- **Cálculo en cola:** comprobar `worker`, `bin/jobs-healthy` y base de Solid Queue. La pantalla consulta cada 3 segundos mientras está abierta; una desconexión no equivale a aplicación.
- **Propuesta obsoleta:** solicitar otra; nunca forzar el fingerprint ni modificar datos terminales.
- **Cambio de mapa:** reiniciar OSRM y recalcular propuestas antes de operar si se modificó significativamente la red.

Referencias: [API OSRM](https://project-osrm.org/docs/v5.24.0/api/), [imagen oficial fijada](https://github.com/Project-OSRM/osrm-backend/pkgs/container/osrm-backend/399470569?tag=v6.0.0), [Osmium extract](https://docs.osmcode.org/osmium/latest/osmium-extract.html).

## Piloto: cobertura, disponibilidad y recuperación

La cobertura se verifica contra `bbox` del manifest del mapa local activo antes de solicitar una matriz o propuesta. Para un proveedor externo, declarar `OSRM_COVERAGE_BBOX=OESTE,SUR,ESTE,NORTE` y una `OSRM_MAP_VERSION` real. Sin metadatos externos, OSRM sigue verificando acceso a la red mediante su radio de ajuste; no se inventa un polígono de cobertura. Un bbox malformado impide optimizar hasta corregirlo. Estar dentro del rectángulo no garantiza calles accesibles: `NoSegment` también requiere revisar la ubicación. Fuera del área se muestra «Esta ubicación está fuera de la zona disponible para optimización». Registrar clientes y planificar manualmente sigue permitido.

Las propuestas viales con versión conocida no se pueden aplicar después de cambiar el mapa. Los cálculos vencidos pasan a un fallo recuperable; no se renuevan indefinidamente en mantenimiento. Una publicación sin propuesta tiene un plazo de diez minutos para iniciarse, y las propuestas conservan su vencimiento de treinta minutos. La pantalla permite reintentar explícitamente o publicar el orden manual aun antes de que el mantenimiento procese el vencimiento. Los controles de ejecución, fingerprint, idempotencia y empresa se conservan.

Para el primer VPS se elige **VROOM deshabilitado**: Kamal declara `MULTIVEHICLE_OPTIMIZATION_ENABLED=false` y `VROOM_URL` vacío. No se instala un servicio multivehículo que no haya sido dimensionado. El asistente conserva controles deshabilitados con una explicación, en vez de ofrecer un cálculo operativo. Declarar solo la URL no habilita la función.

El stack opcional de desarrollo `compose.routing.yml` habilita VROOM internamente, sin puertos publicados, con 512 MiB, una CPU, un hilo y healthcheck `/health`. Web y worker reciben la misma configuración. La interfaz habilita multivehículo solo con el flag, URL y respuesta de salud satisfactoria (cacheada hasta 15 s). Una falla posterior del cálculo deja intacta la planificación manual. El healthcheck prueba el servicio, no reemplaza una optimización real con la cobertura elegida. Antes de habilitarlo en Hetzner hay que agregar su accessory privado, medir RAM/CPU con OSRM y Rails simultáneos y verificar propuestas reales. No se validó un VROOM real en esta etapa; las pruebas de contrato y UI usan respuestas controladas.

Solid Queue separa `routing` en un worker de un hilo y un proceso. El resto de colas conserva dos hilos por proceso; `JOB_CONCURRENCY` se aplica a esas colas. `OptimizeDeliveryRunJob` mantiene el límite global de un cálculo pesado y las ETA se serializan por repartidor durante un minuto. Reiniciar el worker al modificar `config/queue.yml`. Los límites Docker son máximos, no reservas ni garantías de capacidad. El piloto de 8 GB requiere medir el conjunto: web 1,5 GiB, jobs 1,5 GiB, PostgreSQL 1,5 GiB y OSRM 2 GiB, más sistema operativo y caché. Preparar mapas fuera del horario operativo o en otro equipo; no sumar un proceso de construcción de mapa a esa carga.

Medición real adicional del 15/11/2026, equipo local compartido, mapa AMBA ya disponible y `bin/benchmark-routing --live`:

| Paradas | Matriz OSRM (s) | Algoritmo (s) | Consultas matriz | RSS proceso Ruby (KiB) |
| --- | --- | --- | --- | --- |
| 10 | 4,6883 | 0,2379 | 1 | 114800 |
| 25 | 0,4122 | 1,5341 | 1 | 119356 |
| 50 | 0,8569 | 3,0742 | 1 | 120128 |
| 100 | 1,6177 | 5,4851 | 1 | 120328 |

Es una ejecución por tamaño, sin vaciar caché ni aislar el disco de otras tareas. La primera matriz tuvo una latencia mayor. RSS corresponde al cliente Rails/Ruby y no incluye OSRM ni PostgreSQL. `bin/test-osrm` también verificó la matriz real, geometría y solución de cinco paradas. No convertir estos resultados en promesas de tiempos o ahorros comerciales.

Referencia del healthcheck: [VROOM Express](https://github.com/VROOM-Project/vroom-express).
