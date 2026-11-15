# Pruebas físicas de PWA antes del piloto

**Pendientes: no se dispuso de Android/iPhone para ejecutarlas.** Chromium automatizado no certifica Safari, instalación iOS, permisos reales, almacenamiento del sistema ni recuperación después de cerrar el proceso. Completar una ejecución por cada combinación siguiente y conservar versión de sistema/navegador, fecha, resultado e incidencias.

| Plataforma | Modos a probar | Estado |
| --- | --- | --- |
| Android con Chrome | Navegador y PWA instalada | Pendiente |
| iPhone con Safari | Navegador normal | Pendiente |
| iPhone con PWA instalada | Añadir a pantalla de inicio; abrir como aplicación | Pendiente |

Usar staging con HTTPS y datos ficticios: dos empresas, dos cuentas de repartidor, hoja de 30 paradas y otra de 100, productos fraccionables/no fraccionables y visitas con fotos/firma. Verificar administración desde otro equipo. No hacer pruebas de carga, purgas o cambios de cuenta destructivos sobre datos reales.

| Escenario | Comprobación observable |
| --- | --- |
| Instalar y descargar | Acceso offline preparado, hojas correctas y sin datos de otra cuenta; primera descarga y actualización sin cambios. |
| Modo avión | Registrar visita completa/parcial/fallida, cantidades, incidencia, llegada/descarga, dos fotos y firma; ver pendientes locales sin simular confirmación de servidor. |
| Cerrar/reabrir offline | Forzar cierre, volver desde icono, recuperar hojas, operaciones y evidencias con los mismos UUID. No borrar datos del navegador. |
| Corte durante subida | Desconectar entre foto, firma y confirmación. Reconectar y comprobar una sola visita, todas las evidencias y un recibo que confirma exactamente sus identificadores. |
| Reintento duplicado | Pulsar sincronizar, cambiar de red y reabrir: una sola ejecución en Rails, sin duplicar cantidades ni incidencias. |
| Reasignación | Con una operación pendiente, reasignar desde administración. Mantener operación/fotos y mostrar conflicto; no aplicarla a la nueva hoja. |
| Borrador abierto | Cambiar cantidades/paradas desde administración con formulario abierto. Conservar el plan visible hasta que la persona aplique los cambios; no confirmar cantidades de otro plan. |
| Sesión vencida/revocada | Revocar sesión mientras hay pendientes. Bloquear datos privados, conservar cola y recuperarla al autenticar la misma cuenta. |
| Cambio de cuenta/empresa | Probar cierre e ingreso con otra cuenta y otra pestaña. No exponer cola, fotos, firmas, avisos o hojas anteriores; no borrarlos. Volver con la cuenta original. |
| Permiso GPS concedido previamente | Abrir sin activar compartir: ningún prompt ni envío automático. Ver perfil desactivado. |
| GPS voluntario | Leer explicación, activar con jornada visible; comprobar posición/hora/precisión y estado reciente en administración. Denegar permiso y verificar que queda apagado. |
| Ocultar/bloquear/cerrar | Confirmar que no se envían muestras en segundo plano. A los dos minutos el panel debe distinguir última ubicación desactualizada. |
| Revocación offline | Desactivar en modo avión, cerrar/reabrir y reconectar. Sin nueva decisión, no capturar ni reactivar; confirmar eliminación de posición en servidor. |
| Cuenta o sesión cambia con GPS | Cancelar la consulta en curso y no enviar a otra cuenta. La sesión destruida revoca en servidor. |
| Almacenamiento/permisos limitados | Comprobar aviso si no puede guardarse una operación o el control GPS. No indicar éxito ni descartar archivos. Registrar cuota disponible y comportamiento de iOS. |
| Actualización de la PWA | Instalar nueva versión con operaciones pendientes. Conservar IndexedDB, UUID y evidencias; clientes anteriores deben poder sincronizar sus operaciones válidas. |
| Mapas sin red | Conservar direcciones/orden; explicar ausencia de tiles sin inventar recorrido vial. No descargar masivamente tiles de OSM. |

Registrar también consumo de datos/batería de una jornada representativa, tiempo de primer download, tamaño de fotografías y cantidad de pendientes. Distinguir suspensión esperable del sistema de pérdida de datos. Antes de borrar cachés o desinstalar, sincronizar/exportar pendientes. Ninguna de estas pruebas físicas se da por realizada por tener tests JavaScript verdes.
