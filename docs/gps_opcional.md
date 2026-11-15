# Ubicación voluntaria del repartidor

La PWA comienza con GPS desactivado. El permiso del navegador no activa el envío. En **Mi perfil**, «Compartir mi ubicación con la empresa» explica el alcance antes de habilitarlo: última posición, precisión y hora para administración/supervisión, coordinación de entregas, intervalo de 30 segundos, jornada activa, conexión y PWA visible. No hay tracking en segundo plano ni historial de recorridos.

La activación se conserva en memoria durante la sesión de la página, incluyendo reemplazos de vistas por Turbo. Cerrar y volver a abrir exige una nueva decisión. En almacenamiento persistente solo se guarda un marcador de revocación por cuenta; nunca se interpreta como consentimiento para reiniciar el GPS. Si no se puede guardar ese control, no se habilita el envío.

Desactivar cancela inmediatamente la consulta Geolocation y las peticiones en curso. Una revocación offline queda pendiente hasta reconectar con la misma cuenta y sesión válida. Activar de nuevo con una revocación pendiente primero confirma esa revocación; luego requiere otra acción voluntaria. Cambiar de cuenta, bloquear la sesión o cerrar sesión detiene el envío. Destruir una sesión en Rails revoca también el consentimiento del servidor y elimina la última posición.

## Protocolo e integridad

`GET /repartidor/api/v1/location` devuelve el estado del consentimiento de la cuenta autenticada. El POST del mismo endpoint recibe comandos `activate`, `sample` y `deactivate`, CSRF y cuenta autenticada. La activación usa un UUID y la versión esperada del consentimiento. Cada cambio incrementa la versión; las muestras requieren el UUID y la versión activa exactos. Una muestra no puede activar la función, aunque tenga coordenadas recientes y permiso del navegador. Una activación demorada con versión anterior a una revocación se rechaza. Las activaciones y revocaciones repetidas del mismo estado son idempotentes.

Se serializa por usuario y se vuelve a comprobar la sesión dentro de ese bloqueo. No se usa el bloqueo de empresa para muestras GPS. Solo se conserva una fila `driver_locations` por usuario, validada por empresa y rangos. `users` registra el último momento de activación, el de desactivación y la versión; no guarda ubicaciones históricas. La revocación confirmada elimina la fila de ubicación. Las coordenadas no se incluyen en logs de parámetros.

El panel muestra una ubicación como reciente durante dos minutos; después la muestra como última ubicación desactualizada, con hora y precisión. Solo consulta repartidores activos con jornada y consentimiento habilitado. `DRIVER_LOCATION_RETENTION_HOURS` limita la visibilidad y eliminación (24 horas por defecto, rango 1–168). `DriverLocationRetentionJob`, programado cada hora, purga filas vencidas. No se presenta como tiempo real ni se extrapola la posición. La ubicación puntual adjunta a una visita es una función diferente, también voluntaria, y conserva sus reglas de evidencia.

El navegador no garantiza que una desactivación llegue al servidor al cerrar la PWA sin conexión. Mientras tanto no se envían nuevas muestras y el panel debe mostrar la última como desactualizada al vencer; la revocación durable se confirma al volver con conexión. Desinstalar o borrar el almacenamiento local puede borrar ese marcador. Las pruebas físicas de Android/iOS deben comprobar este comportamiento.

Clientes PWA anteriores conservan sus operaciones, fotos y firmas pendientes. Deben actualizarse para usar el protocolo de consentimiento GPS; el servidor rechaza sus intentos de compartir sin consentimiento explícito versionado.

```sh
npm run test:js
docker compose exec -e RAILS_ENV=test web bin/rails test test/controllers/driver_locations_controller_test.rb test/services/operations_snapshot_test.rb test/services/operations_eta_test.rb
```
