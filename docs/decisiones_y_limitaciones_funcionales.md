# Decisiones y limitaciones funcionales de App Repartos

Referencia funcional al **15 de noviembre de 2026**. Esta guía explica qué se puede ofrecer actualmente, qué condiciones necesita cada función y qué hay que preparar para ampliar el servicio. Los instructivos técnicos están enlazados al final.

## 1. Cobertura actual: AMBA

**OSRM, el motor que calcula recorridos por calles, está configurado para trabajar con un recorte de AMBA. No tiene habilitado el mapa de toda la Argentina.**

El recorte incluye CABA y zonas de sus alrededores hacia el norte, oeste y sur. Es un área geográfica configurada, no una lista de municipios ni una garantía de cobertura de todos los caminos de AMBA. Antes de ofrecer el servicio en una localidad, hay que probar direcciones y recorridos representativos.

La aplicación puede registrar clientes y pedidos de otras provincias. Eso no significa que pueda optimizar sus recorridos con el mapa actual. La búsqueda de una dirección y el mapa que se ve en pantalla son funciones distintas del cálculo vial: encontrar un cliente en Córdoba no habilita automáticamente las rutas de Córdoba.

La cobertura de cálculo se comparte entre las empresas de una misma instalación. Actualmente no hay un selector de provincia o de mapa por empresa en el panel.

| Situación comercial | Qué hace falta |
| --- | --- |
| Una distribuidora trabaja dentro del área actualmente cubierta | Verificar sus direcciones, depósito y caminos habituales. |
| Una distribuidora trabaja en Córdoba, Santa Fe u otra zona fuera del recorte | Preparar y activar un mapa que incluya esa zona antes de ofrecer optimización. |
| Se atenderán empresas de AMBA y de otras provincias en la misma instalación | Ampliar el mapa conservando todas las zonas necesarias, o preparar Argentina completa. Reemplazarlo por un recorte de Córdoba dejaría sin cobertura a AMBA. |
| Hay repartos entre provincias | Incluir también los caminos que conectan origen y destino; no alcanza con cubrir ambas ciudades por separado. |
| Se quiere ofrecer cobertura nacional | Preparar Argentina completa, medir recursos y probar recorridos urbanos e interurbanos antes de comprometer el servicio. |

### Pasos para vender en otra provincia

1. **Definir la operación real:** localidades, depósitos, zonas rurales y viajes entre ciudades o provincias. Incluir las zonas que ya usan otros clientes de la instalación.
2. **Ampliar el mapa:** preparar una región mayor o Argentina completa. Esto requiere una intervención de mantenimiento; cargar un cliente de otra provincia no descarga mapas automáticamente.
3. **Comprobar capacidad:** los mapas más grandes necesitan más memoria y espacio. Se puede preparar el mapa fuera del servidor de producción para no afectar a los usuarios. El consumo medido para AMBA no permite prometer el mismo consumo para todo el país.
4. **Hacer una prueba con la distribuidora:** usar direcciones y cantidades de paradas reales, comprobar accesos al depósito, sentidos de circulación, tiempos y ventanas de entrega.
5. **Activar y verificar:** conservar el mapa anterior para poder volver atrás. Si la nueva región excluye CABA, también hay que adaptar las comprobaciones del servicio, que hoy usan puntos de CABA.

Ampliar la cobertura no requiere rediseñar los pedidos ni la PWA. Sí requiere preparar los datos viales y validar el servicio en la nueva región. El procedimiento está en [OSRM y optimización](osrm.md).

## 2. Qué significa «Optimizar ruta»

Al terminar el asistente o desde una hoja editable, **Confirmar y optimizar** responde enseguida y deja el cálculo en segundo plano. Se muestra **Preparando recorrido** y el repartidor recibe la hoja cuando el orden definitivo está listo. No necesita quedarse esperando en la pantalla.

La optimización con vista previa también sigue disponible para comparar tiempos y distancias antes de aplicar una propuesta. La planificación manual se conserva.

- **Alcance:** una hoja, con su repartidor ya asignado, entre 1 y 100 visitas. Una visita puede agrupar varios pedidos.
- **Distribución entre vehículos:** este botón ordena esa hoja; no reparte su carga entre varios repartidores. El asistente multivehículo existente es un flujo separado y necesita tener habilitado su servicio de optimización.
- **Capacidad:** ordenar una hoja no valida por sí mismo que el vehículo soporte el peso, volumen o tipo de mercadería asignada. Esa asignación debe revisarse en la planificación.
- **Criterio:** se buscan recorridos viables según horarios y luego una mejor combinación de tiempo total y preferencias. El recorrido recomendado puede tener más kilómetros si permite atender en horario o reducir tiempo.
- **Resultado:** para recorridos grandes se busca una buena solución, sin garantizar que sea la mejor combinación matemáticamente posible. Tampoco se garantiza un porcentaje mínimo de ahorro.
- **Control administrativo:** «Confirmar y optimizar» autoriza a aplicar y publicar el resultado automáticamente si es viable. En el flujo de vista previa, la propuesta espera una confirmación posterior. En ambos casos se conservan pedidos, cantidades, repartidor e información histórica.

Solo se optimizan hojas que todavía admiten edición. Una hoja con ejecución o finalizada conserva su recorrido histórico. Las propuestas de vista previa vencen a los 30 minutos; un recorrido ya confirmado conserva su resultado y consultar la hoja no vuelve a calcularlo.

### Cuándo se vuelve a calcular

En una hoja confirmada con optimización automática, agregar o quitar paradas, cambiar coordenadas, ventanas, duración de atención, depósito o criterios de salida deja el recorrido pendiente y solicita una nueva preparación. Mientras tanto, no se permite comenzar entregas con el plan anterior. Cambiar un nombre, teléfono, precio o cantidad de mercadería no obliga por sí solo a buscar otro orden.

Las distancias y tiempos entre ubicaciones se guardan por separado. Si solo cambia un horario o la duración de descarga, se vuelve a evaluar el orden reutilizando esos datos viales. También se reutilizan el orden calculado y su trazado cuando sus condiciones siguen iguales. La reutilización respeta cada empresa y la versión del mapa; una actualización vial se revisa en segundo plano, sin reordenar jornadas ya iniciadas.

Si el cálculo falla o los horarios son incompatibles, la hoja queda pendiente de revisión. Administración puede corregir y reintentar o elegir **Publicar con orden manual**. Reordenar manualmente una hoja desactiva su publicación automática, para conservar esa decisión.

Los cálculos evitan trabajo repetido y se limita a uno el proceso pesado de optimización simultáneo. Los datos reutilizables que no se usan durante 90 días pueden limpiarse; el historial de propuestas y entregas se conserva.

Si faltan coordenadas, la dirección de la parada ya no coincide con la ubicación actual o no existe una conexión vial válida, el cálculo requiere revisión. La aplicación no inventa recorridos en línea recta para ocultar esos problemas. Si el motor vial no está disponible, la planificación manual continúa funcionando.

### Memoria del mapa cuando no se está optimizando

OSRM queda disponible porque también calcula estimaciones de llegada durante la jornada. Está configurado para leer el mapa desde los archivos a medida que los necesita (`--mmap=true`), en lugar de mantener una copia completa en memoria privada. Linux puede aprovechar la memoria libre para conservar partes del mapa y liberarlas cuando otras aplicaciones necesiten espacio.

En una prueba local con el mapa AMBA, después de consultar matrices de hasta 101 ubicaciones, recorridos y estimaciones de llegada, la memoria residente del proceso bajó de aproximadamente **508 a 88 MiB**. Contando también la caché de archivos y otros consumos del contenedor, se midieron aproximadamente **527 frente a 225 MiB**. Los resultados viales coincidieron y los tiempos habituales fueron similares. Son referencias de esta prueba, no garantías para otro servidor o una región mayor.

Esto **no equivale a consumo cero ni apaga el servicio cuando queda sin uso**. La primera consulta sobre una zona que ya no está en memoria puede tardar más al leer el disco; conviene usar almacenamiento SSD. El límite configurado de memoria es un máximo permitido, no una reserva que se consume permanentemente. Al ampliar a otras provincias hay que volver a medir memoria, disco y tiempos, manteniendo el procedimiento de mapas versionados explicado en [OSRM y optimización](osrm.md).

## 3. Horarios, depósito y estimaciones

- **Depósito:** se puede calcular desde un depósito configurado, incluyendo opcionalmente el regreso. Cada empresa tiene sus valores predeterminados.
- **Recorrido abierto:** comienza en el primer cliente a la hora indicada. No cuenta el traslado previo desde la casa del repartidor, una base desconocida u otro punto. Hay que usar un depósito cuando ese trayecto deba formar parte de la comparación.
- **Ventana obligatoria:** indica cuándo debe comenzar la atención. Se puede llegar antes y esperar; la descarga puede terminar después del cierre de la ventana.
- **Hora preferida:** orienta el orden, pero no es una obligación. La tolerancia inicial es de 15 minutos y puede configurarse.
- **Descarga:** se suma el tiempo de atención de los pedidos agrupados. Las paradas manuales sin pedidos usan inicialmente 5 minutos, configurable por empresa.
- **Jornada:** las ventanas actuales tienen inicio y fin dentro del mismo día. Una operación nocturna con ventanas que cruzan medianoche necesita una ampliación funcional.

Los tiempos incluyen conducción, atención y espera. Se interpretan según la zona horaria de la empresa. Son estimaciones para planificar: no incluyen tráfico en vivo, clima ni cortes recientes que todavía no estén reflejados en el mapa.

El cálculo vial usa un perfil de automóvil. No debe ofrecerse como planificación especializada para camiones con restricciones de altura, peso, materiales peligrosos o permisos de acceso. Esas necesidades requieren un análisis adicional.

## 4. Calidad y mantenimiento de los mapas

Los datos viales provienen de OpenStreetMap. La calidad de las direcciones y de los caminos registrados influye en los resultados; debe comprobarse especialmente en accesos privados, parques industriales y zonas rurales.

Las actualizaciones del mapa se preparan y activan expresamente. No se descargan con cada pedido ni con cada actualización de la aplicación. Conviene acordar una frecuencia de mantenimiento y revisar antes cuando un cliente detecte cambios importantes.

La vista previa de optimización muestra el trazado vial y paradas numeradas. Es un esquema del recorrido; no es un navegador de conducción con instrucciones giro a giro. La búsqueda de direcciones y las imágenes de los otros mapas necesitan conexión y usan servicios externos configurados; su disponibilidad debe evaluarse al crecer la cantidad de usuarios.

## 5. Trabajo sin conexión y comprobantes de entrega

El repartidor debe iniciar sesión y descargar sus hojas con conexión antes de salir. Después puede consultar la información descargada y guardar entregas, cantidades, incidencias y evidencias en el dispositivo.

**«Guardado en este dispositivo» y «sincronizado con administración» son estados diferentes.** Administración conoce el registro cuando el servidor confirma su recepción. Recuperar señal no significa que todo se haya enviado correctamente.

- La sincronización se intenta con la aplicación abierta, al volver a ella, al recuperar conectividad o mediante la acción manual. No se garantiza con el navegador cerrado o el teléfono bloqueado.
- Las autorizaciones descargadas para registrar visitas tienen una vigencia de 48 horas desde la descarga. Una visita ya registrada, una reasignación o cambios relevantes del plan pueden producir conflictos que administración debe revisar.
- Sin conexión no llegan decisiones administrativas nuevas ni cambios de orden. El repartidor sigue viendo la última información descargada hasta actualizar.
- Los mapas de fondo no se descargan para uso sin conexión. Direcciones, mercadería y orden de paradas sí quedan disponibles cuando se descargó la hoja.
- Se admiten hasta cuatro fotos y una firma opcional por comprobante. Las fotos y firmas tienen límites de tamaño; las incidencias admiten hasta cuatro fotos.
- Borrar los datos del navegador, perder el dispositivo o desinstalar la PWA puede eliminar registros que todavía no se enviaron. Hay que sincronizar o exportar los pendientes antes de limpiar el dispositivo.

Las pruebas automatizadas de navegador no sustituyen las pruebas en teléfonos reales. La validación manual documentada de Android y de la PWA instalada en iPhone sigue pendiente.

## 6. Centro de operaciones, incidencias y tareas

Administración ve estados recibidos, incidencias, tareas y la última ubicación conocida cuando el repartidor decide compartirla y otorga permiso. La ubicación se envía mientras la aplicación está visible y hay conexión. **No hay seguimiento GPS permanente con la aplicación cerrada.**

Una ubicación antigua no demuestra dónde está el repartidor ahora. Las llegadas estimadas dependen de una ubicación reciente, de datos viales disponibles y de los tiempos de atención; actualmente se ofrecen para la primera hoja activa del repartidor. No son una promesa de puntualidad.

Las incidencias permiten informar problemas y recibir decisiones estructuradas. Reportar manualmente un problema no cambia por sí solo el resultado de la visita. Confirmar lectura de una instrucción tampoco confirma su ejecución; completar una tarea no registra automáticamente mercadería entregada.

Los reintentos y reprogramaciones conservan la ejecución original. Cuando corresponde recuperar faltantes conocidos de una entrega ya realizada, se crea un nuevo pedido relacionado con el anterior. No se reabre ni se sobrescribe el intento histórico.

Este flujo reemplaza comunicaciones internas informales mediante responsables, instrucciones e historial. No incluye chat libre ni mensajes a clientes.

## 7. Reportes y oportunidades comerciales

**Visita terminada y pedido entregado al 100 % son cosas diferentes.** Si se solicitaron 20 cajas y se entregaron 18, la visita puede estar completada, pero el pedido tiene una entrega parcial y 2 cajas pendientes.

- Varios pedidos en una parada cuentan como una sola visita. El cumplimiento de cada pedido se analiza por separado.
- No se suman kilos con cajas ni se compensan faltantes de un producto con sobrantes de otro.
- El cumplimiento compara pedidos completos contra completos, parciales y fallidos. Los pendientes y los registros con datos insuficientes se muestran por separado; no se presume que fueron entregados.
- Los períodos usan las fechas locales de la empresa. La comparación anterior cubre la misma cantidad de días.
- El dashboard comercial inicial analiza pedidos, productos, cantidades y frecuencias. Aunque se pueden conservar precios y costos históricos cuando se cargan, no se presenta como un sistema de facturación ni se deducen ganancias o ventas perdidas de datos incompletos.

Las oportunidades se detectan mediante reglas explicables: inactividad, caída de pedidos, faltantes recurrentes, fallas reiteradas y entregas parciales sin seguimiento. Los clientes nuevos que nunca compraron no se consideran inactivos por ese solo motivo.

Los umbrales se configuran por empresa. Las reglas no interpretan automáticamente vacaciones, estacionalidad ni acuerdos particulares con un cliente: la alerta orienta una revisión comercial. El análisis se actualiza periódicamente y ante cambios relevantes; no es instantáneo.

Cada oportunidad permite revisar su evidencia y crear una tarea interna. La creación automática de tareas está desactivada inicialmente y debe habilitarse para las reglas elegidas. Cerrar una tarea y marcar una oportunidad como gestionada son decisiones separadas. Los repartidores no acceden a estas tareas comerciales.

## 8. Usuarios, archivos y continuidad del servicio

Existen dos interfaces: administración y PWA del repartidor. Administradores y supervisores gestionan la operación; los repartidores acceden al trabajo autorizado. Cada empresa conserva sus propios datos. Los clientes son registros de negocio: no tienen usuario, portal, pedidos por autoservicio ni seguimiento público. No hay integración con WhatsApp.

Los archivos se consultan con permisos. Una instalación nueva está preparada para conservarlos en el almacenamiento persistente del servidor; Cloudflare R2 sigue disponible como opción. Cambiar de almacenamiento requiere trasladar expresamente los archivos existentes. También hay que definir cuánto tiempo conservar fotos y comprobantes según las necesidades del negocio.

La puesta en producción está preparada para un único servidor. Esto simplifica la operación, pero una caída de ese servidor afecta al servicio central. Los repartidores pueden continuar con lo previamente descargado dentro de los límites offline. Una copia de seguridad en el mismo servidor no cubre su pérdida: hay que conservar copias externas y comprobar que se pueden restaurar.

La preparación y las comprobaciones locales realizadas no acreditan un despliegue comercial en Hetzner. Antes de incorporar una empresa real hay que completar y verificar servidor, dominio, acceso seguro, almacenamiento y copias de seguridad.

## 9. Antes de comprometer una venta

1. Confirmar que el mapa activo cubre los depósitos, clientes y caminos de toda la operación.
2. Probar una jornada representativa con direcciones correctas, horarios, descarga y cantidad real de paradas.
3. Verificar si necesita reparto entre vehículos, restricciones específicas de camiones o jornadas nocturnas; son necesidades distintas de ordenar una hoja.
4. Probar la PWA en los teléfonos que usarán los repartidores, incluyendo pérdida de señal y sincronización posterior.
5. Acordar cómo se revisan conflictos, incidencias y faltantes, y quién queda responsable de cada tarea.
6. Confirmar capacidad del servidor, mantenimiento de mapas, conservación de evidencias y recuperación de copias externas.

## Referencias para ejecutar los cambios

- [Mapas, ampliación de cobertura y optimización](osrm.md).
- [Puesta en producción, almacenamiento y copias de seguridad](produccion_kamal.md).
- [Funcionamiento sin conexión y revisión de conflictos](pwa_offline.md).
- [Entregas parciales, reprogramaciones e historial](entregas_y_auditoria.md).
- [Incidencias, tareas, fórmulas y reglas comerciales](incidencias_tareas_reportes.md).

## Preparación comercial incorporada

La importación de clientes desde Excel/CSV se prepara y confirma en segundo plano, con mapeo de columnas, código externo único por empresa y revisión persistente. Primero consulta Georef y Photon; solo recurre a Gemini para direcciones difíciles, usando una única clave del servidor, sin pedir credenciales a las empresas. Los clientes importados deben pertenecer a la provincia de su empresa, inicialmente Buenos Aires: se comprueban tanto los datos del proveedor como los puntos dentro de límites provinciales oficiales, incluyendo la revisión manual. Las ubicaciones aproximadas o ambiguas requieren revisión, y las pendientes no se usan en OSRM/VROOM. No se actualizan clientes existentes ni se crean pedidos o entregas automáticamente. Las ubicaciones verificadas fuera del mapa vial activo permiten planificación manual. Ver [importación](importacion_clientes.md).

GPS apagado por defecto: permiso del navegador y consentimiento para compartir son decisiones diferentes. Se exige activación voluntaria, primer plano, sesión y jornada válidas; se conserva la revocación pendiente y se elimina la última posición al confirmarla. No se guardan recorridos históricos. Ver [GPS](gps_opcional.md).

La descarga offline comprueba cambios con ETag y puede reutilizar sus hojas sin otra transferencia de HTML. Las confirmaciones siguen verificándose de forma idempotente y las reasignaciones producen conflictos conservados. Ver [mediciones y límites](sincronizacion_rendimiento.md).

En Kamal, VROOM permanece deshabilitado expresamente hasta verificar infraestructura y recursos. OSRM conserva el mapa AMBA versionado y la planificación manual está disponible cuando falla la optimización. Los backups nuevos se cifran antes de salir hacia R2; cuenta, permisos, timers y restauración operativa real deben completarse antes del piloto. Ver [informe comercial](piloto_comercial.md) y [backups](backups_r2.md).

El alcance excluye cobranzas, rendiciones, facturación electrónica, ERP, importación de pedidos/entregas, portal de clientes, registro público, suscripciones y tracking obligatorio o en segundo plano.
