# Incidencias, tareas y reportes accionables

Esta funcionalidad pertenece al monolito Rails. Existen únicamente administración y la PWA de repartidores. Los clientes siguen siendo registros de negocio. No hay portal, autenticación ni mensajes automáticos a clientes, WhatsApp, servicios de IA, Redis o Sidekiq.

## Arquitectura y acceso

- `Incident`: reporte original y contexto histórico, estado, prioridad, responsable y resolución. Los tipos iniciales son cerrado, ausente, rechazo, faltante, daño, dirección, vehículo y otro.
- `WorkflowTask`: trabajo operativo, comercial o administrativo, con creador, responsable, vencimiento, resultado y vínculos al origen.
- `InternalNotice`: instrucción destinada a un usuario concreto. Lectura y ejecución son confirmaciones diferentes.
- `WorkflowEvent`: historial inmutable de acciones, autor, fecha y datos relevantes.
- `WorkflowCommand`: UUID, usuario, huella del contenido y resultado de una operación. Hace idempotentes los reintentos y rechaza reutilizar un UUID con otro contenido.
- `IncidentPhoto`: metadatos y archivo privado en Active Storage.
- `CommercialOpportunity`: identidad estable, evidencia, estado, fechas de evaluación y ciclo de seguimiento.
- `CommercialRuleSetting`: umbrales y automatizaciones propios de la empresa.

Las referencias tienen claves foráneas compuestas por empresa. Las visitas son referencias históricas blandas en incidencias y tareas: el planificador existente puede eliminar una parada pendiente vacía. La incidencia conserva nombre, dirección, ruta, pedidos y cantidades observadas en su contexto. No se elimina el reporte al reorganizar una ruta. Los pedidos ejecutados, sus productos, cantidades, precios y costos conservan sus restricciones anteriores.

Administradores y supervisores gestionan ambos módulos. Un repartidor consulta sus incidencias (reportante o repartidor afectado) y solo tareas operativas asignadas a él, o sin responsable específico y relacionadas con una ruta asignada a él. Una asignación explícita a otra persona no se vuelve pública por compartir una ruta. Nunca se muestran tareas comerciales ni avisos comerciales en la PWA, incluso si cambia el rol de un usuario. Una tarea terminal no se reabre: se crea otro seguimiento.

`WorkflowCommands` y los servicios de dominio revalidan la cuenta dentro de una transacción con bloqueo de empresa. Las pantallas envían la versión del registro para rechazar decisiones obsoletas. Las resoluciones y cancelaciones exigen motivo. Las transiciones, reasignaciones y resultados tienen eventos de auditoría.

## Flujo de una incidencia

1. En la visita, el repartidor abre **Informar problema**, elige tipo y prioridad, describe el problema y puede adjuntar hasta cuatro fotos. También puede informar un problema general desde **Avisos y tareas**, sin cliente o visita.
2. La operación se guarda en la misma cola IndexedDB que las entregas. Se conserva su UUID y los archivos hasta que el servidor confirme el resultado y todos los identificadores de las fotos. No marca la visita como fallida ni modifica cantidades.
3. El servidor crea el reporte, su contexto, archivos y evento. Un reintento devuelve el resultado previamente registrado.
4. Administración lo recibe en **Incidencias**, con filtros y contadores de abiertas, pendientes de decisión, en seguimiento, resueltas, descartadas y vencidas.
5. Puede pedir información, instruir reintento/devolución, asignar seguimiento, registrar decisión, reprogramar o cerrar con motivo. Las instrucciones que requieren trabajo crean una tarea operativa y un aviso interno. El repartidor puede agregar información estructurada; no se implementa un chat libre.
6. El repartidor consulta el aviso, confirma lectura y registra el resultado de la tarea. Cada acción offline sigue pendiente hasta recibir confirmación. Confirmar una tarea no confirma mercadería ni altera la visita original: la entrega se registra por su flujo habitual.
7. Reprogramar un pedido ejecutado utiliza `DeliveryOrderRescheduler`: crea otro pedido únicamente con faltantes conocidos y preserva precios, costos y relación con el origen. Un pedido pendiente sin ejecución usa `OperationsDispatch`, conservando su auditoría. Si ya hay ejecución en curso o no se conocen los faltantes, se rechaza la reprogramación y se puede crear un seguimiento operativo.

Al finalizar una visita parcial, no atendida, cerrada, rechazada o reprogramada, `IncidentRecorder` genera una incidencia idempotente. Si ya existe un reporte abierto del mismo tipo para la visita, agrega el resultado al historial de ese reporte en lugar de duplicarlo. Una visita completada con faltantes no se interpreta como entrega al 100%. La reconciliación programada incorpora los últimos 90 días de resultados problemáticos anteriores a esta funcionalidad, sin inventar fecha o autor históricos desconocidos.

## Pantallas y rutas

- `/admin/incidencias`: bandeja y filtros; `/:id` muestra contexto, fotografías, pedidos y decisiones; `/:id/acciones` registra una acción.
- `/admin/tareas`: bandeja compartida, filtros, creación, detalle, reasignación y cierre.
- `/admin/reportes`: indicadores, evolución diaria, distribución, motivos, rendimiento, faltantes, clientes problemáticos, comparación y pedidos de detalle.
- `/admin/oportunidades`: bandeja paginada de alertas; `/:id` muestra evidencia y permite crear tarea, gestionar, posponer o descartar.
- `/admin/reportes/configuracion/edit`: umbrales y automatizaciones.
- `/repartidor`: nueva sección **Avisos y tareas** y reportes dentro de las visitas.
- `/repartidor/avisos`, `/repartidor/incidencias/:id`: consultas privadas para la PWA.
- `/repartidor/api/v1/workflow-operations`: operaciones internas idempotentes, con adjuntos multipart cuando corresponde.
- `/fotos-incidencias/:id`: archivo servido por un controlador con autorización; no tiene seguimiento público ni acceso anónimo.

`WorkflowChannel` autoriza el canal administrativo de la empresa o el canal privado del repartidor. Las emisiones contienen únicamente invalidaciones, nunca datos del cliente, tarea o reporte. Las consultas HTTP vuelven a verificar permisos. Los avisos, tareas e incidencias de la PWA se pueden recorrer por páginas independientes. La PWA actualiza la bandeja con Turbo Streams y consulta de respaldo cada 20 segundos; administración actualiza contadores y contenido sin reemplazar formularios editados. La cola y la bandeja descargada están particionadas por empresa/usuario. IndexedDB y el protocolo de descarga suben a versión 4 de forma aditiva; se conservan operaciones, fotos, firmas y autorizaciones de versiones anteriores.

## Fórmulas de reportes

Los rangos predeterminados incluyen hoy y los últimos 7, 30 o 90 días locales de la empresa. El rango personalizado admite hasta 366 días. El período anterior tiene igual cantidad de días y termina el día anterior al comienzo del actual. Todos los datos se filtran por empresa antes de agregar.

| Indicador | Definición |
| --- | --- |
| Pedidos programados | Pedidos no cancelados con fecha programada dentro del rango. |
| Visitas realizadas | Visitas distintas con resultado terminal, según la fecha de su hoja. Incluye resultados fallidos; varios pedidos en una visita cuentan como una sola visita. |
| Entrega completa | Pedido de una visita realizada con todas las cantidades conocidas y cada línea entregada al menos por lo solicitado. |
| Entrega parcial | Pedido de una visita realizada con cantidades conocidas, alguna entrega positiva y al menos una línea con faltante. |
| Entrega fallida | Visita terminal no completada, o pedido con todas sus cantidades conocidas en cero. |
| Datos insuficientes | Visita completada sin líneas/cantidades suficientes para clasificar su cumplimiento, o pedido histórico sin visita cuyo estado no es pendiente; no se presume entrega ni cero. |
| Pendiente | Pedido pendiente sin visita, o pedido asociado a una visita aún pendiente. |
| Cumplimiento | Completos / (completos + parciales + fallidos) × 100. Pendientes y desconocidos se muestran por separado. Sin denominador: **Sin base**. |
| Faltantes | Máximo(solicitado − entregado, 0) de cada línea conocida de una visita ejecutada. Se agrupa por producto y unidad; los manuales, por descripción y unidad. Un excedente no compensa otro producto. |
| Motivos | Cantidad de incidencias de cada tipo, no cantidad de pedidos. La fecha es la de la incidencia; si se desconoce históricamente, se utiliza la fecha de detección. |
| Rendimiento | Resultados de pedidos por quien confirmó la ejecución con rol de repartidor. No se atribuyen resultados históricos desconocidos ni confirmaciones administrativas a un repartidor por su asignación actual. |
| Clientes con pedidos | Clientes distintos con al menos un pedido no cancelado en el período y los filtros. |
| Clientes sin pedidos | Directorio de la empresa (o cliente seleccionado) menos clientes con pedidos en el conjunto filtrado. No es la alerta de inactividad histórica. |
| Tareas comerciales pendientes | Trabajo comercial pendiente/en curso actual, filtrado por cliente/producto cuando corresponde. No depende del rango de entrega y no se presenta como un dato histórico del período anterior. |
| Variación | (Actual − anterior) / anterior × 100. Si el anterior es cero, se muestran ambos valores sin inventar porcentaje. |

El filtro de producto selecciona pedidos que contienen ese producto. El estado completo/parcial sigue calculándose con todas las líneas del pedido; los faltantes se restringen al producto seleccionado. No se suman kilos, cajas o unidades diferentes. Los gráficos enlazan a pedidos y filtros concretos; no se generan estadísticas de demostración. No se muestran facturación, ganancias ni ventas perdidas monetarias.

Los selectores de clientes, productos y rutas ofrecen búsqueda remota de hasta 30 coincidencias por consulta (se puede refinar por nombre, dirección, ciudad o teléfono del cliente), para no cargar el catálogo completo ni limitar la elección a los primeros registros.

Las consultas de `DeliveryReports` agregan en PostgreSQL mediante CTEs y relaciones indexadas. Los detalles de pedidos se paginan de a 25; los rankings muestran hasta 20 registros y los faltantes hasta 30 grupos. El análisis de oportunidades no se ejecuta en el request del dashboard.

## Reglas comerciales y tareas

| Regla | Valores iniciales y evidencia |
| --- | --- |
| A. Inactividad | Solo clientes activos con pedidos anteriores. Espera al menos 14 días y 2,5 veces su intervalo histórico entre días con pedidos. Si hay recurrencias vigentes, considera los días semanales distintos programados. No alerta por clientes que nunca pidieron ni con pedidos futuros pendientes. Guarda última fecha, días, frecuencia y umbral. |
| B. Disminución | Compara dos ventanas de 30 días equivalentes. Exige al menos 3 pedidos anteriores y una disminución mínima del 40%. Conserva fechas, conteos y variación; se habla de pedidos, no ventas monetarias. |
| C. Faltantes | Al menos 3 pedidos con faltantes conocidos del mismo producto de catálogo/unidad en la ventana de 30 días. Guarda cantidad pendiente y muestra clientes y pedidos afectados. Los ítems manuales siguen disponibles en el reporte de faltantes, sin inventar una identidad de catálogo. |
| D. Fallas reiteradas | Al menos 3 visitas distintas con algún pedido fallido del cliente en la ventana de 30 días, aunque agrupen más pedidos. Conserva visitas, pedidos, motivos y fechas. El campo interno `failure_min_orders` se conserva como nombre del umbral, pero la regla usa visitas distintas. |
| E. Parcial sin seguimiento | Pedido parcial con cantidades conocidas, tras 2 días locales desde la ejecución conocida (o fecha programada si no hay hora histórica). No debe tener recuperación no cancelada ni tarea de seguimiento no cancelada vinculada al pedido, su incidencia o su oportunidad. No considera la incidencia automática por sí sola como seguimiento. |

Los umbrales se configuran por empresa. Cada oportunidad conserva clave estable, evidencia, detección inicial, última evaluación, estado y generación del seguimiento. Las tareas están relacionadas con la oportunidad y con el cliente/pedido cuando corresponde. Las muestras de evidencia conservan hasta 50 pedidos y 30 clientes; los conteos agregados consideran el conjunto completo.

Una oportunidad gestionada o descartada no se reabre por el mero cambio de fecha diaria. Se reabre si cambia la condición sustancialmente o después del enfriamiento configurable (30 días). Para inactividad cambia la última fecha de pedido; la disminución usa bandas de 20 puntos porcentuales; faltantes/fallas usan bandas de múltiplos del umbral. Si la condición desaparece, una alerta abierta/pospuesta pasa a **Condición superada**. Una posposición conserva su fecha futura y no se levanta antes.

Desde la evidencia se puede crear/abrir una tarea comercial, asignarla y registrar una gestión. Se reutiliza una tarea abierta existente; si ya terminó, se permite un seguimiento manual nuevo. Las tareas automáticas están desactivadas inicialmente: requieren seleccionar reglas y un administrador/supervisor activo. Se crea como máximo una tarea automática por oportunidad y generación, incluso si el job se reintenta. Tampoco se duplica trabajo que sigue abierto de un ciclo anterior, ni se vuelve a crear automáticamente una tarea que ya se gestionó durante el ciclo actual. Resolver una tarea no equivale a marcar automáticamente la oportunidad como gestionada: se conserva la decisión comercial explícita.

## Procesamiento, instalación y conservación

Aplicar las migraciones `20261116010000_create_internal_workflows` `20261116011000_strengthen_workflow_integrity` y `20261116012000_index_workflow_reporting` después de las migraciones anteriores de la aplicación, mediante `bin/rails db:migrate`. Reiniciar web y worker al desplegar. No se modifica la configuración de PostgreSQL ni se agregan dependencias de ejecución.

Solid Queue mantiene estos trabajos:

- `CommercialOpportunitiesJob`: evaluación por empresa cada hora. Los cambios de pedidos, líneas, estados de visitas, tareas, altas/estado de clientes o recurrencias marcan la empresa pendiente y solicitan actualización con coalescencia de 10 minutos. La pasada programada cubre cambios suprimidos por esa coalescencia y el avance de la fecha local.
- `ReconcileDeliveryIncidentsJob`: reconciliación por empresa cada 6 horas. La creación ordinaria sucede dentro de la transacción de confirmación de visita.
- `IncidentPhotoRetentionJob`: limpieza diaria de archivos huérfanos y, si se configura, conservación de fotografías de incidencias cerradas.

Se usa la configuración de Active Storage: almacenamiento privado persistente en una instalación nueva con Kamal, R2 opcional para instalaciones existentes y almacenamiento local temporal en desarrollo. Cambiar de servicio requiere migrar explícitamente los archivos anteriores; ver `docs/produccion_kamal.md`. Se admiten JPEG, PNG y WebP, hasta 4 fotos de 2 MB. La PWA reduce imágenes; el servidor verifica contenido real, hash y dimensiones, y recodifica sin EXIF antes de almacenar. Los identificadores devueltos deben coincidir con todos los archivos locales antes de borrarlos de la cola.

`INCIDENT_PHOTO_RETENTION_DAYS` es opcional: sin valor, conserva las fotos. Con un entero positivo, se purgan fotos de incidencias resueltas/descartadas tras ese número de días desde su cierre. Los metadatos, hashes, reportes y eventos permanecen. Los archivos preparados sin vínculo se limpian después de 7 días. Una foto purgada devuelve HTTP 410 y un reintento de una operación ya aceptada no vuelve a subirla.

Los cambios son aditivos. No crean usuarios de clientes ni cambian evidencias o cantidades históricas. No se incorporan estadísticas ficticias a seeds. Las fixtures del navegador usan empresas efímeras protegidas contra ejecución en producción.

## Límites operativos reales

Sin conexión se puede reportar y guardar acciones sobre instrucciones ya descargadas; no se puede conocer una decisión nueva hasta reconectar. La fecha declarada de un reporte manual admite hasta 7 días de antigüedad y hasta 5 minutos de adelanto; fuera de ese rango la operación se conserva para revisión. El detalle actualizado de una incidencia requiere conexión, mientras que los avisos y tareas descargados permanecen disponibles. Una acción obsoleta queda en conflicto para revisión, sin marcarse recibida o ejecutada. No depende de notificaciones push del sistema operativo ni garantiza actividad del navegador cerrado.

Las reglas son determinísticas y señalan oportunidades para evaluación humana. Las ventanas, frecuencia media y umbrales no sustituyen una política comercial específica o estacionalidad. Las oportunidades se analizan a nivel empresa, no se recalculan al cambiar filtros operativos del dashboard; en este se filtran por cliente/producto. La configuración de R2 y el proceso Solid Queue existente deben estar activos para almacenamiento y ejecución programada en producción.

## Verificación

Las pruebas están en `test/services/internal_workflows_test.rb`, `delivery_reports_test.rb`, `commercial_opportunity_detector_test.rb`, `workflow_photo_uploads_test.rb`, `test/controllers/workflow_modules_controller_test.rb`, `test/models/workflow_integrity_test.rb`, `test/channels/workflow_channel_test.rb`, los jobs y `test/browser/workflows.spec.js`. La suite JavaScript comprueba persistencia de la cola, aislamiento por cuenta y rechazo de confirmaciones incompletas.

Comandos de comprobación: `bin/rails test`, `npm run test:js`, `npm run test:browser`, `bin/rubocop`, `bin/rails zeitwerk:check`, `bin/rails tailwindcss:build`, `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error`, `bin/bundler-audit check --update`, `npm audit` y `bin/importmap audit`. Este último no verifica la copia local de Leaflet porque el importmap existente no declara su versión. El almacenamiento se verificó con Disk y la configuración de R2 con tests; una subida real al bucket productivo requiere sus credenciales y queda como verificación del despliegue.
