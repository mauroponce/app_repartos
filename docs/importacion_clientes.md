# Importación inteligente de clientes

Desde **Clientes → Importar clientes**, administradores y supervisores pueden preparar una importación CSV/XLSX, revisar sus ubicaciones y confirmar el alta. Todo acceso se limita a la empresa de la sesión; los jobs reciben explícitamente empresa, lote y generación. No se crean pedidos, entregas ni hojas de reparto.

## Uso y ejemplos

1. Cargar una planilla de `docs/ejemplos/clientes/`, empezando por `clientes_importacion_simple.xlsx`. La lectura se realiza en Solid Queue.
2. Elegir hoja y fila de encabezados (detectada entre las primeras 20). Guardar para releer si cambian. Mapear las columnas por posición, sin exigir nombres específicos. Revisar las primeras cinco filas.
3. Completar localidad, partido/departamento y código postal generales cuando correspondan. La provincia proviene de la empresa y el país es Argentina. No se presupone una localidad. Cada empresa tiene una provincia obligatoria, inicialmente Buenos Aires. Solo el administrador puede cambiarla desde **Provincia de la empresa**, y no mientras existan importaciones pendientes. El país actual es Argentina.
4. **Guardar mapeo / leer hoja** y después **Procesar direcciones**. La pantalla actualiza el progreso mediante Turbo; se puede salir y volver mediante la URL del lote.
5. Filtrar resultados por precisión, errores, duplicados o pendientes. Buscar por nombre/dirección/localidad. **Revisar fila** permite corregir datos, elegir candidatos almacenados, buscar con Photon, arrastrar el marcador, hacer clic en Leaflet o ingresar coordenadas. Confirmar manualmente o guardar sin ubicación; se puede continuar con la próxima fila pendiente. También se pueden omitir filas.
6. Corregir u omitir errores. Reconocer expresamente duplicados y ubicaciones pendientes antes de **Confirmar importación**. El alta se realiza en jobs de 50 filas. Repetir una confirmación o reintentar el job no duplica sus clientes.

Nombre, dirección y localidad conservan las validaciones del modelo. Una localidad puede extraerse del texto si existe evidencia; si sigue faltando se debe corregir o excluir la fila. Email, contacto, teléfono, código externo y coordenadas son opcionales. Los clientes existentes nunca se actualizan por el nuevo asistente. Un código externo ya utilizado es un error que se debe corregir o excluir. Las coincidencias por nombre y las filas similares se advierten y requieren reconocimiento explícito para crear clientes adicionales. Los lotes del importador anterior siguen disponibles en su vista original y con su confirmación explícita de cambios.

El código externo se conserva como texto, incluidas las máscaras numéricas de ceros compatibles. Excel puede haber truncado números de más de 15 cifras antes de la carga; para códigos largos, guardarlos como texto en origen. No es posible recuperar información que la planilla ya perdió.

Los cuatro XLSX incluyen direcciones de Burzaco, Adrogué, Banfield, Lomas de Zamora, Lanús, Quilmes, Avellaneda, Morón y San Martín. El grande tiene 2.000 filas y direcciones repetidas para demostrar la caché. No incluyen coordenadas. Los nombres son ficticios y las direcciones son ejemplos, sin garantía de entrada de entrega. Cargarlos no altera datos existentes; solo la confirmación crea clientes. Regeneración determinística: `python3 script/generate_customer_import_examples.py`. `test/fixtures/files/customer_imports/demonstration_states.json` contiene coordenadas sintéticas, exclusivamente para demostrar clasificaciones en pruebas.

## Arquitectura y procesamiento

Se extiende `customer_imports`, sin duplicar el staging anterior. El archivo original se conserva en Active Storage; `customer_import_rows` contiene una fila persistente por registro con valores originales, datos limpios, interpretación, candidatos completos, rechazos, advertencias, posibles duplicados, precisión, revisión y cliente creado. Los originales no se cambian al revisar datos. Usuario iniciador, estado, generación, totales y heartbeat pertenecen al lote.

Estados: `reading → mapping → preparing → processing → review → importing → completed`. `cancelled` invalida la generación de jobs anteriores. `failed` permite reanudar. Cancelar es posible antes del alta definitiva; un request en curso puede terminar pero no publicar resultados de una generación cancelada. Después de iniciar el alta, las decisiones quedan congeladas. Ante una validación concurrente, vuelve a revisión y protege las filas ya creadas; se corrige/omite la fallida y se confirma el resto.

CSV y XLSX se recorren en streaming; staging se inserta y valida de a 100 filas, y solo se geocodifican hasta 25 filas por ejecución, con un presupuesto de 60 segundos antes de continuar en otro job. La validación inicial corre antes de los proveedores: limpia espacios/caracteres de control, identifica vacías, errores del modelo, coordenadas inválidas/invertidas, códigos internos, repetición de direcciones, códigos y clientes similares del archivo/empresa. Una dirección repetida no supone necesariamente un cliente duplicado. La detección por nombre es una advertencia conservadora, no una resolución de identidad.

`CustomerImportJob` tiene una sola plaza de concurrencia global en Solid Queue y una cola dedicada de un thread/proceso. No usa Redis. Se escriben progreso y resultados tras cada fila. Las operaciones de alta bloquean empresa → lote → fila, creando cliente y referencia de staging en la misma transacción; cada fila creada queda excluida de futuros intentos. Índices únicos y claves foráneas compuestas protegen idempotencia y pertenencia a empresa en PostgreSQL. La tarea periódica `CustomerImportMaintenanceJob` recupera encolados/heartbeats atrasados cada cinco minutos en producción. En desarrollo puede ejecutarse manualmente.

## Pipeline y precisión

1. Normalización determinística local de abreviaturas, calle/altura, localidad explícita, intersección, entrecalles y referencias. Conserva el original. No deduce arbitrariamente una localidad.
2. Georef Argentina v2: POST `/direcciones` en grupos de hasta 25 consultas únicas, con `max=10`, `campos=completo` y filtros disponibles. Se filtra siempre por la provincia de la empresa. Se valida `resultados[].direcciones[]`, incluyendo `altura.valor`, `calle`, `localidad`, `departamento`, `provincia` y `ubicacion.lat/lon`. Conserva candidatos sin punto y señala resultados truncados. No se confía en que el filtro garantice una localidad: se comprobó en la API real que puede devolver coincidencias de otra localidad. Las coordenadas de Georef se consideran interpoladas; no confirman por sí solas una entrada exacta. Una dirección completa cuya única limitación sea la interpolación queda para revisión, sin gastar tokens de Gemini: la IA no puede certificar un punto de entrega.
3. Photon complementa mediante `/api/`, `q`, `limit=8`, `countrycode=ar` y `bbox` opcional. Se reutilizan URL, mapa, controlador Stimulus y búsqueda del formulario individual. El backend valida GeoJSON, país, calle, altura, localidad, provincia y partido. Una geometría de calle, localidad o interpolación no es una dirección exacta. Si Photon informa una ciudad y una subdivisión distintas, se conserva la contradicción y se requiere revisión: se observó realmente el caso ciudad Adrogué/subdivisión Claypole. También puede tratarse de un barrio legítimo; sin evidencia suficiente no se aprueba automáticamente. Admite una consulta alternativa para casos sin resultados.
4. Solo para direcciones sin candidatos utilizables o con componentes faltantes, Gemini puede extraer una estructura estricta con calle, altura, aproximación, localidad, partido, provincia, país, intersección, entrecalles, referencias, información faltante, ambigüedades y evidencia textual por campo. Se envían dirección y contexto geográfico, nunca nombre comercial, teléfono ni email de columnas del cliente.
5. Se valida el JSON y el respaldo de cada hecho en la entrada. No se admiten alturas ausentes, localidades inventadas, campos extra ni coordenadas. Una interpretación utilizable se consulta nuevamente en los proveedores; una interpretación sin respaldo se descarta. Si Gemini falta o falla, los proveedores determinísticos siguen disponibles.
6. El evaluador asigna 35 puntos por calle exacta normalizada, 30 por altura, 25 por localidad y hasta 10 por provincia/partido. Rechaza contradicciones y puntos fuera de la provincia de la empresa, incluso cuando el proveedor declare una provincia incorrecta. Exige altura exacta y localidad para confianza automática, sin entrecalles, intersecciones, ambigüedades ni interpretación de IA. Prefiere evidencia de dirección sobre interpolación. El umbral automático mínimo es 90; nunca puede configurarse por debajo.

**Confiable:** dirección y punto respaldados, sin contradicciones ni candidatos plausibles alejados. **Aproximada:** existe un punto coherente pero evidencia insuficiente (incluye Georef interpolado, altura aproximada, coordenadas aportadas o interpretación con IA). **Ambigua:** ubicaciones plausibles separadas por más de 150 m, evidencia contradictoria o resultados truncados. **Sin ubicación:** ningún candidato utilizable. Se guardan motivos de rechazo y candidatos para revisión. El radio y el umbral son configurables. La pertenencia provincial se comprueba localmente con polígonos oficiales Georef almacenados en `config/geocoding/argentina_provinces.geojson`; también se verifica al confirmar manualmente y antes del alta, sin necesitar una API disponible. CABA es una jurisdicción distinta de Buenos Aires. Un punto fronterizo dudoso se rechaza de forma conservadora. Fuente y actualización: `config/geocoding/README.md`. El evaluador admite un centro esperado y radio máximo; el pipeline no usa el depósito de la empresa como restricción implícita para clientes que pueden pertenecer a otra zona.

Las coordenadas del archivo fuera de la provincia son un error. Las coordenadas válidas se conservan como aportadas, pero necesitan confirmación manual para optimizar rutas. Los puntos aproximados/ambiguos de proveedores permanecen en staging; no se convierten silenciosamente en destinos definitivos. `customers.location_verification` diferencia `pending`, `provided`, `reliable`, `manual` y `legacy`. Se preserva la compatibilidad de puntos anteriores mediante `legacy`. La edición individual sigue requiriendo coordenadas y confirma manualmente el punto. Cambiar dirección sin reconfirmar invalida la ubicación. OSRM, VROOM, navegación de visitas y ETA comprueban `routing_location?`.

## Configuración, cuotas y costos

Configuración equivalente en `.env.example`, `compose.yml` y Kamal. Reiniciar web y worker tras modificar variables. `GEMINI_API_KEY` es una única clave del operador de App Repartos, compartida por el backend para todas las empresas y cargada desde `.env`; ninguna empresa debe proporcionar una clave. Es un secreto exclusivo del servidor; copiar la entrada a `.kamal/secrets`, dejándola vacía si no se usa IA. Kamal solo requiere ese secreto al activar `GEMINI_ENABLED`; no se exige una clave para desplegar el importador sin IA. No poner claves en URLs, frontend, fixtures ni logs.

| Variable | Predeterminado | Función |
| --- | --- | --- |
| `GEOREF_API_URL` | `https://apis.datos.gob.ar/georef/api/v2.0` | Base de API de Argentina |
| `PHOTON_URL` | `https://photon.komoot.io/api/` | Misma configuración del formulario; admite instancia propia |
| `GEMINI_ENABLED` / `GEMINI_API_KEY` | `false` / vacío | IA opcional; ambos necesarios |
| `GEMINI_MODEL` | `gemini-3.5-flash-lite` | Debe estar disponible para la cuenta/API; no se sustituye silenciosamente |
| `GEMINI_LOW_TEMPERATURE` | `false` | Temperatura 0,1 solo para modelos compatibles; Gemini 3 conserva su valor recomendado |
| `GEOREF_DAILY_LIMIT` / `GEOREF_INTERVAL_MS` | 2000 / 1000 | Cuota global y separación de requests |
| `PHOTON_DAILY_LIMIT` / `PHOTON_INTERVAL_MS` | 100 / 1500 | Límite global; servidor público siempre máximo 100/día y mínimo 1500 ms |
| `GEMINI_DAILY_LIMIT` / `GEMINI_INTERVAL_MS` | 100 / 2000 | Techo global de consumo de IA |
| `GEOCODING_TIMEOUT_SECONDS` | 10 | Timeout HTTP, máximo 30 segundos |
| `GEOCODING_CACHE_DAYS` | 30 | Caché positiva por empresa, máximo 90 días; negativos 1 hora |
| `GEOCODING_RELIABLE_SCORE` | 90 | Mínimo de aceptación automática (90–100) |
| `GEOCODING_AGREEMENT_METERS` | 150 | Distancia para contradicción entre candidatos |
| `GEOCODING_EXPECTED_RADIUS_KM` | 50 | Radio del evaluador si se provee un centro esperado |
| `GEOCODING_BBOX` | vacío | Restricción explícita de Photon `minLon,minLat,maxLon,maxLat` |
| `CUSTOMER_IMPORT_MAX_MB` / `CUSTOMER_IMPORT_MAX_ROWS` | 5 / 5000 | 1–20 MB, 1–10.000 filas |
| `CUSTOMER_IMPORT_RETENTION_DAYS` | 7 | Elimina archivos/staging antiguos, conserva clientes; 2–90 días |

Las reservas de tasa y cuotas son atómicas y compartidas en PostgreSQL, por proveedor; el día de cuota es UTC. `geocoding_provider_states` guarda solo solicitudes, errores y tokens agregados cuando Gemini los informa, sin direcciones ni credenciales. La caché se aísla por empresa e incluye todos los componentes geográficos, URL/versionado del parser y modelo/schema. Las consultas idénticas se reutilizan; los fallos de servicios no se guardan como resultados negativos exitosos.

Al agotar una cuota se continúa con otros proveedores o ubicación pendiente. Timeouts/429/5xx tienen como máximo tres intentos por fila y reprogramación con backoff; las esperas por tasa no consumen intentos ni bloquean un thread durmiendo. `Retry-After` se respeta hasta una hora. Reintentar la preparación es seguro; revisar manualmente evita depender de servicios que sigan disponibles. La aplicación evita tráfico masivo en el Photon público mediante un límite global conservador. Con los valores iniciales, en lotes grandes muchos casos quedarán pendientes si Georef no es suficiente. Aumentar cuota en una instancia Photon propia solo tras evaluar sus recursos. No se requiere contratar servidores ni mapas pagos para operar sin IA.

## Seguridad, retención y operación

Se limitan extensión, MIME, tamaño comprimido/descomprimido (20 MB), entradas ZIP (200), filas, columnas y celdas (10 KB). Se rechazan rutas ZIP inseguras, symlinks, referencias externas, fórmulas XLSX, CSV binario o UTF-8 inválido. Los valores CSV nunca se evalúan; los errores exportados neutralizan fórmulas. Roo lee con límites y archivo temporal local eliminado al cerrar `ActiveStorage#open`. El original se guarda con almacenamiento persistente del proyecto; el asistente no expone enlaces públicos al archivo.

URLs únicamente de configuración del servidor, sin credenciales/query/fragmento; no siguen redirects. Respuestas HTTP limitadas a 2 MB, timeouts y estructura validada. Los requests del asistente filtran archivo, datos de fila, dirección, contactos y contexto en logs. No se registra cuerpo de errores externos ni clave API. La API Gemini solo recibe el texto de dirección y contexto; si una dirección de origen incluye información personal escrita dentro de ese mismo texto, se enviará como parte de la dirección. Evitar esa información en origen.

La preparación vence a las 24 horas; conservar la URL antes de salir. Producción ejecuta retención y recuperación por Solid Queue. Desarrollo: `docker compose exec web bin/rails runner 'CustomerImportMaintenanceJob.perform_now'`. Confirmar antes del vencimiento. No revertir la migración mientras haya código/jobs nuevos activos; detener la cola y volver primero a una versión compatible. La migración es aditiva y no cambia datos anteriores; los puntos legacy conservan su comportamiento. El despliegue debe ejecutar migraciones y reiniciar el worker para cargar la nueva cola.

## Pruebas y comprobación real

```sh
docker compose exec -e RAILS_ENV=test web bin/rails db:migrate
docker compose exec -e RAILS_ENV=test web bin/rails test test/services/geocoding test/services/customer_import_workbook_test.rb test/jobs/customer_import_job_test.rb test/controllers/customer_imports_controller_test.rb
docker compose exec -e RAILS_ENV=test web bin/rails test
npm run test:js
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
# En el entorno CI aislado del proyecto:
bin/ci
```

Las pruebas HTTP usan transportes simulados y fixtures determinísticos; no necesitan APIs ni claves reales. La prueba opcional siguiente consume cuotas y escribe solamente caché/métricas de una empresa elegida; no crea clientes. Puede devolver una espera por limitación de consultas. Probar con una empresa de desarrollo y datos no sensibles:

```sh
docker compose exec -e COMPANY_ID=1 -e ADDRESS='Av Espora 1200' -e CITY='Burzaco' -e PROVINCE='Buenos Aires' web bin/rails runner script/check_customer_geocoding.rb
```

Se comprobó realmente GET y POST de Georef v2 con consultas representativas antes de escribir el parser, y una consulta GeoJSON de Photon. La disponibilidad y calidad de Photon dependen de OpenStreetMap; no hay garantía de cobertura de altura. Gemini requiere habilitación y credenciales válidas; el modelo solicitado puede no estar habilitado para una cuenta. Las verificaciones automatizadas no certifican entregas reales. No se consideran precisas las coordenadas interpoladas, centros de calles/localidades, entrecalles, rutas por km ni alturas aproximadas. La revisión humana sigue siendo necesaria en esos casos.

## Otros países y proveedores

Agregar un adaptador Ruby en `Geocoding` que devuelva el mismo contrato de candidatos (`street`, `house_number`, `city`, `district`, `province`, `country`, punto, tipo y precisión). Declarar límites, identidad de caché y evidencias reales del proveedor; seleccionar adaptadores explícitamente según país en `Pipeline`. Incorporar validación geográfica del país y pruebas de contradicciones antes de habilitar confianza automática. El pipeline actual solo consulta servicios configurados para Argentina, sin deducir países/localidades ni añadir integraciones innecesarias.

Referencias oficiales: [Georef y API](https://www.argentina.gob.ar/georef/referencia-completa-de-la-api), [POST por lotes](https://www.argentina.gob.ar/georef/consultas-por-lotes), [Photon](https://github.com/komoot/photon/blob/master/docs/api-v1.md), [JSON estructurado de Gemini](https://ai.google.dev/gemini-api/docs/structured-output), [generateContent](https://ai.google.dev/api/generate-content).

## Archivos principales

| Área | Archivos |
| --- | --- |
| Lectura, mapeo y confirmación | `app/services/customer_imports/workbook.rb`, `preparation.rb`, `workflow.rb` |
| Proveedores, IA y evaluación | `app/services/geocoding/` y `app/services/geocoding.rb` |
| Trabajos y recuperación | `app/jobs/customer_import_job.rb`, `customer_import_maintenance_job.rb` |
| Persistencia | `app/models/customer_import.rb`, `customer_import_row.rb`, `geocoding_cache_entry.rb`, `geocoding_provider_state.rb`; migraciones `20261116030000` y `20261116031000`; `db/schema.rb` |
| Empresa y seguridad vial | `app/models/company.rb`, `customer.rb`, `visit.rb`; `app/services/route_optimization/`, `route_optimization_problem.rb`, `operations_eta.rb` |
| Interfaz y permisos | `app/controllers/customer_imports_controller.rb`, `customer_import_rows_controller.rb`, `company_settings_controller.rb`; sus vistas y `config/routes.rb` |
| Mapas y progreso | `app/javascript/controllers/location_controller.js`, `import_progress_controller.js`; `app/assets/stylesheets/application.css`; vistas de clientes |
| Configuración | `.env.example`, `.kamal/secrets.example`, `compose.yml`, `config/deploy.yml`, `queue.yml`, `recurring.yml`, `initializers/filter_parameter_logging.rb`, `.dockerignore` |
| Datos oficiales y ejemplos | `config/geocoding/`, `docs/ejemplos/clientes/`, `script/generate_customer_import_examples.py`, `script/check_customer_geocoding.rb` |
| Verificación | `test/services/geocoding/`, pruebas de workbook/rutas/jobs/controladores, `test/integration/commercial_pilot_test.rb`, pruebas de navegador de importación y piloto |

`app/services/product_import_reader.rb` comparte la validación segura del ZIP con el lector nuevo; conserva su comportamiento de productos. El importador de clientes anterior se mantiene para lotes históricos en `app/views/customer_imports/legacy.html.erb`.
