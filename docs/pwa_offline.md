# PWA offline del repartidor

## Uso

Con conexión, iniciar sesión en `/repartidor` y esperar **Datos descargados** y **Acceso offline preparado**. La primera descarga y la instalación del Service Worker necesitan conexión y HTTPS (localhost también funciona). Se descargan todas las hojas publicadas del día asignadas al usuario, sus paradas, clientes, direcciones, teléfonos, coordenadas, productos, unidades, cantidades y resultados conocidos.

Después se pueden consultar rutas y registrar visitas sin conexión. Cada confirmación se guarda primero en IndexedDB; solamente después se muestra «Visita guardada en este dispositivo. Se sincronizará cuando haya conexión». Este camino también se usa online. El selector **Rutas descargadas** conserva acceso a descargas anteriores. No se puede registrar una ruta que nunca se descargó.

Las tarjetas diferencian un registro local de uno sincronizado. El contador muestra pendientes y registros que requieren atención. **Ver registros** permite consultar cantidades, observaciones, UUID y errores, y exportar un respaldo JSON. El respaldo contiene datos privados de la cuenta; debe tratarse como información de trabajo y entregarse solamente a administración por un canal autorizado. No contiene contraseñas, cookies, CSRF ni la prueba firmada de descarga.

La sincronización se intenta al abrir, al recuperar conectividad, al volver al primer plano y con **Sincronizar ahora**. También hay reintentos mientras la app está abierta, con backoff exponencial limitado a 60 segundos. `navigator.onLine` sólo actualiza el aviso de conectividad: la respuesta del servidor confirma la disponibilidad. No se depende de Background Sync ni se promete sincronizar con la app completamente cerrada.

## Arquitectura

Se conserva Rails, PostgreSQL, Stimulus, importmap y la interfaz existente. No se agrega un frontend separado ni una dependencia JavaScript de producción. IndexedDB usa APIs nativas.

- **Service Worker:** cachea únicamente recursos públicos enumerados: JS local de importmap, CSS, fuente local, iconos, manifest y `/repartidor/shell`. Una navegación sin red abre ese shell público. No almacena HTML autenticado, respuestas de API, mutaciones ni imágenes de mapas en Cache Storage.
- **IndexedDB `repartos-offline`, versión 1:** `meta` guarda la cuenta local activa y metadatos de descarga; `packages` guarda los datos estructurados y la presentación privada de cada hoja; `operations` guarda la cola y los comprobantes. Las dos últimas tablas tienen índice por cuenta y claves que incluyen `company_id:user_id`.
- **Presentación:** la descarga incluye HTML generado con los mismos templates escapados de Rails usados online, sin tokens CSRF. Se conserva en IndexedDB dentro de su cuenta y permite reconstruir la misma interfaz desde el shell público. Los registros locales se superponen a la presentación descargada; nunca se confunden con la confirmación del servidor.
- **Servidor:** `DriverOperationSync` coordina deduplicación, autorización de la descarga y ejecución mediante `DriverVisitRecorder`. Las reglas de cumplimiento por producto y auditoría de `Visit` se conservan. `DriverWorkSnapshot` firma la revisión de la planificación.

Los mapas requieren red para cargar sus imágenes. Direcciones, teléfonos, productos y orden de paradas permanecen descargados. Se retiraron `watchPosition()` y los controles de GPS; no existe tracking.

## Cola local

Cada operación conserva también un snapshot local de cliente y mercadería original para seguir consultándolo aunque administración cambie la planificación. La prueba firmada incluye el snapshot original emitido por el servidor, que se guarda en el comprobante administrativo al recibir el intento.

Cada operación contiene UUID generado por `crypto.randomUUID()`, visita, resultado, cantidades por ítem, observaciones, hora declarada por el dispositivo y prueba firmada de la descarga.

| Estado local | Comportamiento |
| --- | --- |
| `pending` | Guardada y pendiente de confirmación. Una falla de red permanece aquí. |
| `syncing` | Una pestaña obtuvo un lease de 30 segundos e inició el envío. |
| `synced` | El servidor confirmó y devolvió el comprobante con ese UUID. |
| `conflict` | No se aplicó el intento; requiere revisión administrativa. |
| `invalid` | No se aplicó por validación; se preserva para revisión. |

Se espera el evento `complete` de la transacción IndexedDB antes de informar que se guardó. El alta local y el control de duplicados por visita son una sola transacción. Los leases también se adquieren transaccionalmente: dos pestañas no reclaman simultáneamente el mismo trabajo. Si una pestaña o el navegador se cierran enviando, el lease vence y el mismo UUID puede reintentarse. La idempotencia de PostgreSQL sigue siendo la garantía final ante carreras o respuestas perdidas.

No se cambian UUID, cantidades ni observaciones durante un reintento. Conflictos y errores de validación no se reenvían automáticamente como operaciones nuevas. Las operaciones conservan tanto el intento original como el comprobante o error. El reloj local es informativo y nunca autoriza una entrega.

## API v1 y esquema

Todos los endpoints usan la sesión Rails activa y requieren rol repartidor. No aceptan empresa, usuario ni repartidor como autoridad. Las respuestas son `no-store`. Las mutaciones mantienen protección CSRF; el token se renueva con la descarga y sólo permanece en memoria.

| Método y ruta | Respuesta |
| --- | --- |
| `GET /repartidor/api/v1/work` | Versión, identidad efectiva, CSRF, hora del servidor y paquetes de trabajo de hoy. |
| `POST /repartidor/api/v1/operations` | Recibe una `operation`; devuelve su UUID, `synced`, `conflict` o `invalid`, y el resultado persistido. |
| `GET /repartidor/api/v1/operations/:uuid` | Consulta el resultado propio previamente registrado. |

`DriverSyncOperation` es la nueva tabla de comprobantes: empresa, usuario, UUID, identificador declarado de visita, payload, digest, estado, resultado, hora local y timestamps del servidor. Su índice único `(company_id, user_id, operation_id)`, la clave foránea compuesta a usuarios y la restricción de estados refuerzan integridad y aislamiento. El identificador de visita del intento se conserva aunque la visita ya no exista; la pantalla administrativa sólo busca detalles en la empresa actual. Los comprobantes son inmutables desde el modelo.

La ejecución y el comprobante se confirman en la misma transacción bajo el bloqueo de empresa ya usado por planificación y reasignación. Un savepoint revierte todas las cantidades si falla una línea posterior. Una falla temporal antes del commit no deja una entrega aplicada sin comprobante. Repetir el UUID con el mismo contenido devuelve el resultado guardado; reutilizarlo con otro contenido devuelve HTTP 409 y conserva el primero.

La migración `20261115030000_create_driver_sync_operations.rb` también agrega `DeliveryRun.assignment_version`, entero no negativo. Aumenta al cambiar repartidor, fecha o cancelar la hoja. Asignar Juan → Pedro → Juan invalida igualmente una descarga anterior de Juan. Una confirmación en otra parada no aumenta este contador.

Aplicar localmente con `docker compose exec web bin/rails db:migrate`. `schema.rb` se obtiene de Rails, sin editarlo manualmente. No se realizó deploy a producción. Un futuro rollback que quite la tabla de operaciones descartaría comprobantes: antes de cualquier reversión hay que conservarlos y detener clientes de sincronización.

## Registros tardíos y conflictos

La descarga de una visita pendiente de hoy obtiene una prueba firmada ligada a usuario, empresa, visita y revisión exacta de la planificación, con vigencia de **48 horas desde la descarga**, medida por el servidor. La prueba no permite iniciar sesión y sólo sirve acompañada de una sesión válida del mismo usuario. La API no emite nuevas autorizaciones para rutas de días anteriores. Cambiar la fecha del teléfono o enviar una hora antigua no extiende la vigencia.

`DriverVisitRecorder` admite esa autorización vigente aunque haya pasado la medianoche. Mantiene los demás controles: repartidor actual, hoja asignada o en progreso, visita pendiente y misma revisión. La revisión incluye cantidades, ítems, snapshots, notas, horarios y versión de asignación; cambios y reversiones posteriores también invalidan la descarga. `confirmed_by_id` sigue siendo el usuario autenticado y `confirmed_at` es la hora real de confirmación en servidor. La hora offline declarada queda separada en el comprobante.

| Situación | Resultado |
| --- | --- |
| Mismo UUID y contenido, incluso después del cierre de la hoja | Se devuelve el comprobante original sin volver a ejecutar. |
| Hoja reasignada, cancelada o visita eliminada | Conflicto conservado; no se aplica. |
| Visita confirmada desde otro dispositivo o administración | Conflicto; no se sobrescribe el resultado. |
| Cantidades, productos, dirección, notas u horarios cambiados | Conflicto por revisión de planificación. |
| Prueba mayor a 48 horas | Conflicto por vencimiento; no se usa el reloj del teléfono para evitarlo. |
| Cantidad negativa, faltante o inválida | `invalid`, sin cambios parciales. |
| Sesión revocada, usuario inactivo o cuenta diferente | HTTP 401/403; se bloquea la vista local y se retiene la cola hasta autenticar la misma cuenta. |
| Error de red, timeout, 429 o 5xx | Reintento con el mismo UUID y backoff; no se presenta como sincronizado. |

Administradores y supervisores pueden abrir **Sincronizaciones** (`/admin/sincronizaciones`) y revisar el intento, su hora declarada, motivo del rechazo y visita actual. La vista es de lectura: revisar no significa reaplicar ni sobrescribir. Deben coordinar con el repartidor y usar las entregas/reprogramaciones existentes si corresponde. Un caso que nunca llegó a subir por sesión o prueba inválida sigue disponible localmente para exportar y revisar.

## Acceso, cierre de sesión y versiones

La cuenta activa se mantiene en IndexedDB; cada login/cambio de cuenta y pantalla de acceso actualizan esa puerta de acceso. `BroadcastChannel` bloquea pestañas de la cuenta anterior; al volver al primer plano se comprueba la cuenta activa. La sincronización verifica la identidad efectiva del servidor antes de enviar y las pruebas firmadas impiden aplicar operaciones de otra cuenta incluso ante una carrera entre sesiones. Las páginas recuperadas del historial del navegador también comprueban esa puerta antes de mostrar contenido privado.

Cerrar sesión con registros pendientes, en conflicto o inválidos requiere confirmar que se conservarán en este dispositivo y se recuperarán sólo con la misma cuenta. Es posible cancelar para revisarlos/exportarlos. Una falla de red durante el cierre no se presenta como una sesión cerrada. Al cerrar sesión correctamente se desactiva el acceso local y se conserva la cola, no se borra la base. La revocación remota se conoce cuando el navegador logra consultar al servidor; estando completamente offline se conservan las capacidades de la última cuenta local habilitada.

No se elimina automáticamente ninguna operación, ni siquiera sincronizada. Tampoco se purgan silenciosamente descargas al cambiar de día, usuario o versión. Las actualizaciones de caché eliminan únicamente cachés públicos anteriores. Los cambios de IndexedDB son aditivos y las conexiones antiguas se cierran ante `versionchange`. Una versión de cliente incompatible se detiene y conserva los datos.

Se solicita almacenamiento persistente mediante `navigator.storage.persist()` cuando está disponible, sin asumir que el navegador lo concede. Quota insuficiente o imposibilidad de guardar se muestran como error y **no** como visita guardada. El almacenamiento sigue sujeto a las reglas del sistema operativo: borrar datos del sitio, desinstalar o usar navegación privada puede eliminarlo. Antes de limpiar manualmente datos del sitio debe verificarse que no haya operaciones pendientes o de revisión, sincronizarlas y/o exportarlas. No hay limpieza automática de información privada. IndexedDB no es un almacén cifrado por cuenta: el aislamiento es de la aplicación y el dispositivo debe permanecer bajo control de sus usuarios autorizados.

## Verificación automática

La suite completa, incluidas estas pruebas de navegador, se ejecuta en cada push y pull request. Para reproducirla con bases y servidor aislados: `docker compose -f compose.ci.yml up --build --abort-on-container-exit --exit-code-from ci`. Ver [CI](ci.md) para limpieza, auditorías y diagnósticos. Los comandos siguientes permiten probar contra el entorno de desarrollo existente.

```sh
docker compose exec web bin/rails db:migrate
docker compose exec web bin/rails test
npm ci
npm run test:js
# Chrome/Chromium instalado; o npx playwright install chromium
npm run test:browser
docker compose exec web bin/rubocop
docker compose exec web bin/brakeman --no-pager
```

Los tests de navegador utilizan `http://127.0.0.1:3006`, crean empresas temporales `pwa-test-*` y limpian únicamente esas empresas. No apuntarlos a producción. En el modo de desarrollo, `PWA_TEST_URL` permite cambiar la URL local y los fixtures usan Docker Compose. Con `PWA_TEST_SERVER=1`, Playwright administra un servidor Rails de test con CSRF activo y ejecuta los fixtures directamente en esa base; este modo requiere preparar las bases y CSS previamente, como hace `bin/ci`. Ambos modos rechazan fixtures en producción. `PLAYWRIGHT_CHROMIUM_EXECUTABLE` permite elegir el navegador. Las dependencias npm son exclusivamente de pruebas; la PWA carga sus recursos locales mediante importmap.

La prueba principal automatizada registra varias visitas totalmente offline, cierra el proceso Chromium, lo reabre con el mismo perfil y sin red, consulta los clientes y registros persistidos, completa otra incidencia y después sincroniza. También comprueba actualización del worker con cola pendiente, ausencia de datos privados en Cache Storage, separación de cuentas y recuperación de errores/sesión revocada. Esto es evidencia en Chromium de escritorio con viewport móvil; no equivale a validación en teléfonos ni en WebKit/iOS.

## Prueba manual pendiente en dispositivos reales

Ejecutar en una instalación de prueba HTTPS, con una cuenta y entregas de prueba. Registrar dispositivo, versión de OS/navegador, fecha y resultado de cada paso. Esta lista no afirma resultados todavía no observados.

1. **Android Chrome:** iniciar sesión, abrir cada hoja asignada y esperar ambos indicadores de preparación. Instalar la PWA desde Chrome y abrirla desde el icono.
2. Activar modo avión y desactivar Wi-Fi. Confirmar una entrega completa, una parcial (20 solicitados, 18 entregados) y una incidencia. Comprobar el mensaje local y el contador pendiente, sin ningún «Sincronizado» anticipado.
3. Cerrar la PWA y quitarla de aplicaciones recientes; volver a abrirla desde el icono todavía sin red. Consultar direcciones y productos, buscar clientes, cambiar de hoja y revisar los tres registros con sus cantidades.
4. Registrar otra parada offline y, si es posible, mantener el dispositivo offline hasta cruzar medianoche. Recuperar red dentro de las 48 horas, abrir la PWA y sincronizar. Comprobar una sola operación por UUID, cantidades y autoría correctas en administración.
5. Repetir interrumpiendo red durante el envío y pulsando sincronizar en dos pestañas. Confirmar que los reintentos no duplican visitas ni entregas.
6. Con registros aún locales, reasignar la hoja o modificar una cantidad desde administración. Sincronizar y comprobar conflicto visible en el teléfono y el panel administrativo, con intento local intacto.
7. Revocar la sesión, recuperar conexión y comprobar bloqueo de datos privados sin pérdida de la cola. Reingresar con la misma cuenta y verificar recuperación. Cambiar a otra cuenta en el mismo dispositivo y comprobar que no aparecen clientes ni registros de la primera.
8. Publicar una versión de prueba con cambios de recursos, manteniendo pendientes. Abrir con red para actualizar y volver a cerrar/reabrir offline. Verificar conservación de la cola y nuevo shell. No usar producción para esta prueba.
9. **Safari/iPhone:** repetir la secuencia abriendo primero Safari y luego **Compartir → Agregar a inicio**. Probar desde la PWA instalada, cerrándola desde el selector de aplicaciones y reabriéndola en modo avión. Verificar especialmente persistencia tras reinicio, regreso al primer plano, reinstalación/almacenamiento y cambios de cuenta. Sincronizar con la app abierta; no depender de tareas en segundo plano.

Android físico y Safari/iPhone instalado quedan pendientes de ejecución manual. Referencias de plataforma: [Service Workers](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers), [commit de IndexedDB](https://developer.mozilla.org/en-US/docs/Web/API/IDBTransaction/complete_event), [Background Sync](https://developer.mozilla.org/en-US/docs/Web/API/Background_Synchronization_API) y [pruebas offline con Playwright](https://playwright.dev/docs/api/class-browsercontext#browser-context-set-offline).
