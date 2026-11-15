# Entregas, visitas y auditoría

## Resultado de una visita

`Visit.status` describe lo ocurrido en una parada, independientemente de cuánto se entregó:

| Estado | Significado |
| --- | --- |
| `pending` | Visita sin confirmar. |
| `completed` | Visita realizada; puede tener entrega completa, parcial o cero. |
| `not_attended` | No atendieron. |
| `closed` | Comercio cerrado. |
| `rescheduled` | El resultado registrado fue solicitar reprogramación. No crea automáticamente otro pedido. |

Las transiciones permitidas son de `pending` a cualquiera de los cuatro resultados finales. Una visita finalizada conserva hoja, cliente, resultado, autor, fechas, observaciones y mercadería. No se reabre, traslada ni reutiliza para otro intento.

Al confirmar desde la PWA o administración se guardan `confirmed_by_id` (el usuario autenticado) y `confirmed_at` (hora del servidor). El resultado auditado es el propio `status`, que pasa a ser inmutable. Administración registra su propia autoría, aunque la hoja tenga un repartidor asignado. `completed_at` mantiene su significado anterior: momento de una visita `completed`; `confirmed_at` existe para todos los resultados nuevos.

Las confirmaciones requieren un autor de la misma empresa. Las visitas fallidas nuevas registran cero en todos los productos; se rechaza una incidencia que incluya cantidades positivas. Para `completed` se exigen todas las cantidades, incluso cero. La hoja asignada pasa a `in_progress` si quedan visitas pendientes, o a `completed` si se resolvieron todas. Una hoja en borrador admite registro administrativo y conserva su estado hasta que administración lo cambie.

## Estado del pedido

| `DeliveryOrder.status` | Significado y transición |
| --- | --- |
| `pending` | Pendiente de ejecución. Sin visita está pendiente de planificación; con visita aparece como asignada. |
| `completed` | Visita realizada y todas las líneas cubiertas. Se calcula al confirmar la visita. |
| `needs_attention` | Visita fallida, faltantes o evidencia histórica insuficiente. Se calcula al confirmar o importar ejecución histórica. |
| `cancelled` | Cancelación administrativa explícita de un pedido pendiente y editable, quitándolo primero de su hoja. |

Las transiciones ordinarias son `pending → completed`, `pending → needs_attention` y `pending → cancelled`. Los estados finales conservan el intento y sus cantidades. No se completan pedidos por el solo hecho de finalizar la visita. La reprogramación no cambia el estado ni la visita del pedido original.

`fulfillment_result` se calcula al consultarlo a partir de `DeliveryOrderItem.quantity` y su `DeliveryItem.delivered_quantity`, vinculados por línea y visita. No agrega otra columna de estado:

| Resultado calculado | Regla |
| --- | --- |
| `unrecorded` | Pedido pendiente o cancelado sin visita confirmada. |
| `unknown` | Falta alguna línea de ejecución, cantidad o vínculo con la visita correcta. `NULL` no se interpreta como cero. |
| `full` | Cada producto tiene una cantidad entregada mayor o igual a la solicitada. |
| `none` | Todos los productos tienen cantidad entregada cero. |
| `partial` | Hay cantidades conocidas positivas y al menos un producto con faltantes. |

Se compara cada línea en su unidad original; nunca se suman unidades distintas ni se compensan faltantes con sobrantes de otro producto. El pendiente por línea es `max(solicitado - entregado, 0)`, o desconocido si no hay cantidad registrada. Por ejemplo, 20 paquetes solicitados y 18 entregados dejan 2 pendientes. Un pedido puede tener `needs_attention` y resultado `full` si una visita histórica fallida contiene cantidades contradictorias; exige revisión administrativa.

El resultado se recalcula al leerlo. Para pedidos pendientes con visita pendiente se informa `unrecorded`, aunque se hayan guardado cantidades provisorias. El estado definitivo se escribe dentro de la transacción de confirmación, después de guardar todas las cantidades; las cantidades finalizadas no se editan.

## Intervención y reprogramación

En **Entregas → Requieren intervención** aparecen los pedidos `needs_attention` que todavía no tienen sucesora. El filtro **Con faltantes o incidencias (historial)** también muestra los intentos que ya se reprogramaron. El detalle muestra solicitado, entregado, diferencia, pendiente, autor y resultado de cumplimiento.

**Reprogramar faltantes** crea una entrega puntual `pending` para una fecha posterior a la original, con los mismos snapshots de cliente, dirección, horario, productos y unidades, y solamente las cantidades faltantes conocidas. Conserva `rescheduled_from_id` hacia el intento anterior y permite navegar en ambos sentidos. No copia `delivery_schedule_id`: una reprogramación no es otra ocurrencia recurrente ni debe impedir la generación habitual de esa fecha.

Si vuelve a fallar, se reprograma la sucesora, formando una cadena. Cada intento conserva su propia ejecución. Un pedido original con sucesora aparece como «Reprogramada» en la presentación; el estado almacenado sigue siendo `needs_attention`. La sucesora puede editarse o cancelarse bajo las reglas habituales mientras esté pendiente y su hoja sea editable; cancelar es una decisión administrativa explícita de abandonar ese seguimiento y no reactiva el intento anterior.

Una llamada repetida para el mismo original y fecha devuelve la misma sucesora. Si la fecha difiere, devuelve un error para evitar duplicar el trabajo; se debe revisar la sucesora existente. No se reprograman pedidos completos, cancelados, pendientes de ejecución ni cantidades históricas desconocidas. Estos últimos quedan visibles para revisión; no se inventan cantidades ni se reescribe la visita para habilitar el botón.

Confirmación, planificación, edición de hojas y reprogramación utilizan el bloqueo transaccional de la empresa existente. Así se serializan reintentos y reasignaciones dentro de una empresa. El índice único de `rescheduled_from_id` refuerza la deduplicación en PostgreSQL. Las consultas de entrada se limitan a la empresa autenticada y las claves foráneas compuestas también verifican empresa y cliente.

## Reasignación e historial del repartidor

Cambiar `DeliveryRun.driver_id` durante una hoja en progreso conserva todas las visitas, pedidos y cantidades. El repartidor nuevo puede confirmar las pendientes. El anterior pierde permiso de escritura sobre esa hoja, incluso si conserva una pantalla abierta.

El historial personal y el gráfico semanal consultan `Visit.confirmed_by_id` y `confirmed_at`, en el huso horario de la empresa. La semana cuenta visitas `completed`, incluidas las de cumplimiento parcial; no es una métrica de pedidos totalmente cumplidos. El progreso de la ruta describe todas sus visitas, independientemente de sus autores.

Si Juan confirma cinco visitas y luego Pedro confirma otras cinco de la misma hoja, cada historial contiene sus propias cinco. Las confirmaciones administrativas no se atribuyen al repartidor asignado. Las visitas históricas sin autor conocido se muestran en administración como «Autoría desconocida» y se excluyen de los historiales personales.

## Esquema y datos existentes

La migración `20261115020000_audit_visit_confirmations_and_order_fulfillment.rb` agrega:

- `visits.confirmed_by_id`, nullable, con clave foránea compuesta a usuarios de la misma empresa.
- `visits.confirmed_at`, nullable, e índice `(company_id, confirmed_by_id, confirmed_at)` para el historial.
- Una restricción que exige ambos campos de confirmación juntos y solamente para visitas resueltas. Permite ambos nulos para datos históricos.
- `delivery_orders.rescheduled_from_id`, nullable, con índice único, clave foránea compuesta por empresa y cliente, índice de soporte y restricción contra autorreferencias.
- `needs_attention` en la restricción de estados de pedidos.

Reclasifica los pedidos con visita finalizada comparando las cantidades existentes: solamente una visita `completed` con todas las líneas cubiertas deja el pedido `completed`; los demás pasan a `needs_attention`. Los pedidos antes completados sin una visita finalizada también requieren intervención. No altera resultados de visita, cantidades, snapshots ni timestamps. No atribuye autores ni horarios históricos desde el repartidor actual, `updated_at` o `completed_at`. El backfill de visitas recurrentes aplica las mismas reglas y conserva los valores desconocidos.

Aplicación local: `docker compose exec web bin/rails db:migrate`. Se verificó en desarrollo y tests; no se realizó deploy. Para una futura publicación hay que coordinar migración y reinicio de procesos: el código anterior desconoce `needs_attention` y no debe seguir confirmando visitas tras la migración. La migración es intencionalmente irreversible para impedir que un rollback descarte auditoría o convierta intentos fallidos en pendientes planificables.

Verificación: tests de modelos, servicios, controladores, flujo integrado y concurrencia con conexiones PostgreSQL independientes; suite completa con `docker compose exec web bin/rails test`, estilo con `bin/rubocop` y análisis con `bin/brakeman --no-pager` dentro del mismo contenedor.
