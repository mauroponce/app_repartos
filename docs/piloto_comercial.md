# App Repartos: preparación del piloto comercial

Informe del **15 de noviembre de 2026**. Alcance: estabilización del monolito existente, importación de clientes, GPS voluntario, sincronización, rutas y recuperación. No se ejecutaron despliegues ni cambios productivos.

## 1. Resumen de cambios

Se completaron los flujos del repositorio conservando Rails 8.1, ERB/Hotwire/Stimulus/Tailwind, PostgreSQL 18, Solid Queue, PWA con IndexedDB, Docker/Compose/Kamal y OSRM. VROOM queda explícitamente deshabilitado en el piloto hasta disponer de backend verificado. Las copias externas se cifran con age antes de transferirse mediante rclone a un prefijo R2 privado.

La revisión final corrigió la precisión de coordenadas importadas, la navegación hacia direcciones históricas, las invalidaciones innecesarias de trabajo y la reactivación de sesiones/consentimiento al restaurar. Cada corrección cuenta con cobertura de regresión en su flujo. Los cambios están separados por etapa. Los cambios del usuario preparados previamente en layout y sidebar se preservaron y quedaron fuera de estos commits. También se excluyó el trabajo simultáneo posterior de importación/geocodificación. La CI final usa un checkout aislado de esta entrega; sus resultados no validan esas ediciones concurrentes. No se agregaron cobranzas, facturación, ERP, importación de pedidos/entregas, portal de clientes, alta pública, suscripciones ni GPS obligatorio/en segundo plano.

## 2. Modelos, servicios y migraciones

- **Clientes/importación:** `Customer`, `Company`, nuevo `CustomerImport`, `CustomerImportReader`, `CustomerImporter` y el lector compartido `ProductImportReader`. Se agregan código externo por empresa, staging y teléfono nullable. Índice único parcial concurrente y check de código no vacío.
- **GPS:** columnas de consentimiento en `users`, `DriverLocation`, `Session`, nuevo `DriverLocationSharing`, retención y `OperationsSnapshot`. Consentimiento por UUID/versión, última activación/desactivación y una sola posición por usuario.
- **Offline:** `Current`, `DriverWorkSnapshot`, `DriverDashboard`, controladores Sync/Repartidor, stores y motor existentes. Se conservan versión de API, esquema IndexedDB y UUID pendientes.
- **Rutas:** `RoutePublication`, `RouteOptimizationProposal`, `Osrm::Client`, `RouteOptimization::Dataset/Problem`, problema multivehículo, VROOM, ETA y jobs de preparación/mantenimiento.
- **Backups:** los tres scripts originales se amplían con librería compartida de validación, comandos remoto/monitor/instalador, systemd y pruebas técnicas.

Migraciones nuevas: `20261115173000_support_customer_imports`, `20261115173100_index_customer_external_codes`, `20261115174000_add_explicit_driver_location_consent`. Son aditivas, salvo permitir teléfono NULL; no reescriben ejecución histórica ni operaciones offline. El índice se crea fuera de transacción. La reversión de teléfono requiere completar previamente datos ausentes. No usar rollback de schema como respuesta automática a un fallo de deploy.

## 3. Pantallas y funciones

Clientes incorpora **Importar clientes**, plantilla, mapeo, revisión de cambios, exclusión de filas, errores descargables y resumen. La PWA explica el consentimiento GPS y su revocación; operaciones distingue ubicación reciente, vencida o inexistente. El asistente explica la indisponibilidad de multivehículo y permite continuar manualmente. Una publicación vencida ofrece recuperación explícita.

Una visita histórica nunca cambia su dirección por editar/importar el cliente. Si el punto actual ya no corresponde a esa dirección, la PWA omite ese marcador y navega usando el texto histórico, con una advertencia.

## 4. Importación de clientes

CSV UTF-8 y primera hoja XLSX; 5 MB/5.000 filas/30 columnas por defecto, configurables con límites. Roo/CSV ya existentes; no se consulta Photon. Se verifican extensión, tipo, estructura, ZIP y tamaño real descomprimido, límites, coordenadas, campos requeridos y referencias internas.

El código externo se reconoce solo dentro de la empresa autenticada. Conserva ceros iniciales de texto o máscara Excel. Un cliente existente muestra sus cambios; las celdas vacías conservan datos salvo decisión explícita. Sin código se crean registros nuevos, se advierten coincidencias y se exige reconocer el riesgo de duplicados; no se fusionan por nombre. Se pueden excluir filas y volver a revisar.

Se admiten teléfono y coordenadas ausentes. Nombre, dirección y ciudad son obligatorios. Los puntos se validan antes de redondear a siete decimales; se admiten precisiones comunes de planillas. Ubicación pendiente se completa posteriormente y no entra en optimización. La previsualización vence en 24 horas, no escribe clientes y la confirmación detecta cambios concurrentes, es transaccional e idempotente. [Procedimiento](importacion_clientes.md).

## 5. Sincronización y mediciones

La descarga usa una lectura PostgreSQL REPEATABLE READ sin lock exclusivo de empresa. Revalida cuenta/sesión y conserva los locks críticos de escritura. La revisión refleja filas, bajas, reasignaciones, cantidades, resultados, publicación y presentación. ETag permite **304 sin HTML**, con CSRF fresco solo en memoria. Las pruebas incluyen un escritor que mantiene el lock de empresa mientras el lector completa y otra escritura confirmada entre consultas del snapshot.

La cola, evidencias, firmas, conflictos y grants de 48 horas permanecen compatibles; se renuevan descargas cada hora como máximo. Timestamps internos del mantenimiento comercial no invalidan trabajo sin cambios.

Medición local de 30 paradas por hoja, una ola de 5/20/50 repartidores, Rack dentro del proceso y PostgreSQL real, equipo compartido de 15 GiB:

| Repartidores | p95 actualización sin cambios antes/después | Consultas antes/después | Cuerpo antes/después |
| --- | --- | --- | --- |
| 5 | 4,33 / 0,42 s | 79 / 19 | 1,78 MB / 0 |
| 20 | 11,88 / 1,68 s | 79 / 19 | 7,10 MB / 0 |
| 50 | 40,57 / 3,44 s | 79 / 19 | 17,68 MB / 0 |

Las lecturas posteriores no registraron espera por locks. Las escrituras mantuvieron hasta 49 conexiones esperando; no se demuestra una mejora estable de su latencia y la ola de 20 fue peor después. La descarga inicial de 50 tuvo p95 de 22,5 s; se permite un plazo de 60 s para trabajo completo. No es una prueba HTTP/TLS/red móvil ni dimensionamiento de un VPS de 8 GB. La medición adicional con 100 paradas alcanzó p95 de 38,62 s en 50 descargas iniciales (57,13 MB totales), 3,11 s sin cambios y hasta 14,39 s en confirmaciones de 20 repartidores; RSS final 754.648 KiB. Se ejecutó con CI/build concurrentes y no tiene una medición anterior comparable de 100 paradas. No prometer 50 descargas simultáneas sin validar esa infraestructura. [Resultados completos, p50, memoria, SQL y herramienta](sincronizacion_rendimiento.md).

## 6. OSRM y VROOM

OSRM conserva mapas versionados, release anterior y activación explícita, sin descargas por deploy/cliente. Se comprueba bbox del manifest local, o un bbox externo declarado; fuera de cobertura se muestra el mensaje requerido. Estar dentro del rectángulo no garantiza una calle accesible; los errores viales se mantienen visibles. La cobertura sigue siendo **AMBA**, no Argentina completa.

Una propuesta conocida de otro mapa se rechaza. Los cálculos conservan límites, control de ejecución, idempotencia y publicación explícita/autorizada. Publicaciones sin iniciarse o vencidas fallan de forma recuperable. Cola `routing` separada con un hilo/proceso y límite global de cálculo pesado; ETA se limita por repartidor.

Kamal declara VROOM deshabilitado y URL vacía. El stack opcional de desarrollo es privado y tiene límites/healthcheck; el asistente exige configuración y salud satisfactoria. Tests de contrato/UI controlados **no prueban un VROOM real**. OSRM real sí se verificó con matriz, geometría, solución y benchmark de 10/25/50/100 paradas. Los resultados y recursos están en [mapas](osrm.md). Un fallo de optimización conserva planificación manual.

## 7. GPS opcional

Apagado por defecto. El permiso del navegador no equivale a consentimiento. Activar requiere una decisión explícita, jornada/sesión válidas, conexión y PWA visible; intervalo de 30 s. Solo se guarda última posición, precisión y hora. Tras dos minutos deja de presentarse como reciente, incluso si se interrumpe la actualización del panel.

Detener cancela consultas, conserva una revocación offline por cuenta y borra la posición cuando el servidor confirma. Una versión impide que solicitudes demoradas reactiven el envío. Destruir sesión revoca también en servidor. Cerrar/reabrir requiere otra decisión; no hay recorridos históricos ni GPS en segundo plano. Retención de posición configurable, 24 horas por defecto. [Detalle y límites del navegador](gps_opcional.md).

## 8. Backups R2

Implementados: snapshot principal compartido con catálogo/conteos, dump separado de queue, adjuntos Disk/R2, validación de cada archivo, manifiestos/checksums, cifrado age, rclone, lectura remota para comparar ciphertext, flock, retención, comprobación de espacio/antigüedad/objeto remoto, estado atómico, webhook y timers.

El VPS recibe clave pública; identidad privada fuera del servidor. Bucket privado y token de backup separados de Active Storage. Solo se sube `.tar.age`; no dumps ni sidecars en claro. Copia diaria a las 03:20 Buenos Aires, hasta 15 min de demora; 7 copias locales y 30 días remotos inicialmente. No hay atomicidad entre bases y archivos; los límites se explican sin ocultarlos. La cuenta R2, IAM, ejecución de timers y monitor externo reales todavía deben configurarse/verificarse. [Instalación y configuración](backups_r2.md).

## 9. Restauración

Listar → elegir → descargar → descifrar/verificar → restaurar ambas bases en PostgreSQL 18 temporal sin red → comparar conteos, catálogo y adjuntos → resultado JSON. Se admiten copias locales v1 sin modificarlas; la conversión conserva su fecha original cuando está disponible.

El comando productivo es independiente, exige mantenimiento y confirmación exacta, rechaza roles/conexiones activos y crea una copia previa cifrada antes de recrear/restaurar las bases. Se pueden preparar los datos en otro equipo y transferir por SSH sin llevar la identidad al VPS. Incluye recuperación de un servidor nuevo y conversión explícita de medios R2 a Disk. Se probó el comando protegido **solo contra bases/archivos desechables**. La restauración real elimina sesiones y posiciones GPS y revoca el consentimiento restaurado para impedir que reaparezcan accesos/consentimientos anteriores. Exige autenticarse y decidir nuevamente; conserva operaciones/grants offline y requiere conservar los secretos Rails. Revisar bajas de cuentas posteriores al backup. No se restauró producción. [Recuperación completa](backups_r2.md).

## 10. Pruebas y evidencia

- Línea base: 405 tests Rails/3.006 aserciones, 32 JavaScript y 16 Playwright, todos aprobados; RuboCop, Brakeman y auditorías de gems/importmap/npm aprobadas.
- **CI local final sobre `69e785b`, en checkout aislado: 435 tests Rails/3.248 aserciones, 40 JavaScript, 18 Playwright y 10 Python, todos aprobados.** Sin fallos, errores, omisiones ni reintentos de navegador. RuboCop inspeccionó 273 archivos sin infracciones; ShellCheck/Bash, Brakeman y auditorías de gems/importmap/npm aprobadas. La ejecución completa tomó 14 min 41 s; Chromium, 10 min 34 s.
- Importación: pruebas de CSV/XLSX, ceros, normalización, validaciones, coordenadas, idempotencia, concurrencia de revisión, errores y tenant.
- GPS: consentimiento, revocación, sesión/cuenta, muestras demoradas, retención y navegador real Chromium.
- Offline: tests de lectura/locks/MVCC, 304, caché ausente, sesión y conservación de cola/evidencias. Pruebas existentes de reinicio, fotos/firma, cortes y conflictos preservadas.
- Circuito comercial: un test integrado con 63 aserciones y dos escenarios adicionales de navegador, aprobados; el payload Rails representa la operación offline y el navegador prueba su persistencia real.
- Rutas: 125 tests/515 aserciones y 49 finales/303 aserciones aprobados; native Kamal y Compose válidos; OSRM real aprobado.
- Backups: diez tests Python, ShellCheck/Bash, validación de unidades y paquete local. La integración ejecuta age/rclone reales, catálogo Disk/R2 simulado, dos PostgreSQL desechables, restauración protegida que revoca sesiones/GPS, compatibilidad v1, errores, retención y webhook local. [Resultado completo aprobado](benchmarks/backup-recovery-local.json). R2 no fue utilizado como backend real.

La imagen de producción se construyó y aprobó `bin/test-production`: UID 1000, assets, `/up` interno, ambas bases PostgreSQL con rol restringido, migraciones sin seeds demo, adjuntos Disk, worker Solid Queue y persistencia después de reiniciar. Se verificó sin publicar puertos ni desplegar. Se compararon SHA-256 de 78 archivos modificados de aplicación/scripts/configuración contra el checkout de la entrega: coincidieron y excluyen las ediciones concurrentes. No se ejecutó GitHub Actions remoto; la evidencia anterior corresponde a `bin/ci` local con Compose. Los comandos reproducibles están en [CI](ci.md). No se atribuyen pruebas físicas a dispositivos no disponibles.

## 11. Riesgos y comprobaciones abiertas

- Falta verificar R2/IAM, upload/restore, alertas y timers reales con responsables y claves de recuperación custodiadas.
- Falta piloto HTTPS en Hetzner, rollback y recuperación completa con sus volúmenes, datos y tiempos. Los límites Docker no garantizan capacidad del conjunto en 8 GB.
- Faltan Android Chrome, Safari y PWA instalada iPhone; cuotas, suspensión y pérdida de almacenamiento dependen del sistema. [Plan físico](pruebas_dispositivos_piloto.md).
- Descargas iniciales grandes y confirmaciones simultáneas siguen requiriendo medición HTTP/carga mixta. Importaciones grandes deben programarse fuera del pico de escrituras.
- Cobertura/adecuación de vías AMBA, perfil automóvil y cambios de mapa requieren validación por zona. No hay tráfico en vivo ni restricciones específicas de camiones.
- VROOM queda cerrado hasta medirlo y provisionarlo. No se promete cobertura nacional ni ahorro de ruta.
- Backups no atómicos entre bases; revisar jobs al recuperar. Conservar secretos y mapas mediante procedimiento separado. Un cierre abrupto puede dejar temporales privados que requieren limpieza.

## 12. Requisitos del primer deploy Hetzner

1. Elegir VPS/SSD, dominio, DNS/SSH y responsables; revisar firewall: solo proxy 80/443 y SSH administrado. DB/OSRM/VROOM privados.
2. Configurar secretos externos, rol/bases PostgreSQL 18 y volúmenes con UID/GID 1000; construir la imagen de producción y validar Kamal. No usar seeds demo en producción.
3. Aplicar migraciones compatibles, iniciar web/worker con sus límites y comprobar `/up`, heartbeat y acceso multiempresa. Mantener VROOM deshabilitado inicialmente.
4. Preparar/validar mapa AMBA explícitamente fuera del deploy; conservar anterior, coordinar cambio con jobs detenidos y verificar rutas representativas.
5. Configurar R2/age/rclone/timers/webhook, ejecutar una copia externa y una restauración desde otro equipo. Registrar responsables, RPO/RTO observados y custodia de claves.
6. Ejecutar circuito de la distribuidora, pruebas físicas y carga HTTP realista. Acordar límites del piloto según mediciones. [Procedimiento Kamal](produccion_kamal.md).

## 13. Checklist comercial

- [x] Arquitectura y alcance acordados preservados.
- [x] Importación de clientes con revisión, errores y control de duplicados.
- [x] Consentimiento GPS explícito y revocación durable.
- [x] Lectura offline consistente/incremental y operaciones anteriores conservadas.
- [x] Cobertura AMBA clara, optimización recuperable y planificación manual.
- [x] VROOM deshabilitado hasta disponer de servicio verificado.
- [x] Backups cifrados y restauración implementados con pruebas locales reales.
- [x] Circuito integrado y separación multiempresa verificados automáticamente.
- [x] CI local completa e imagen de producción aprobadas sobre la entrega aislada.
- [ ] Cuenta/bucket R2 privados, copia externa y recuperación real verificadas.
- [ ] Hetzner/HTTPS/secretos/volúmenes/monitoring y límites del VPS validados.
- [ ] Pruebas físicas Android/iPhone y prueba con personal de la distribuidora.
- [ ] Primer backup/restore operativo, responsables y RPO/RTO documentados.

El código prepara el piloto; la habilitación comercial requiere cerrar las verificaciones operativas pendientes anteriores.
