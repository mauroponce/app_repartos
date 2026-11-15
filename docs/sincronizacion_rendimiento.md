# Descarga incremental y consistencia offline

`DriverWorkSnapshot.consistent_read` genera la descarga con PostgreSQL **REPEATABLE READ**. Todas las consultas y el HTML pertenecen al mismo estado confirmado de la planificación. No toma un lock exclusivo de empresa. Se vuelve a comprobar el usuario activo, rol, empresa y sesión dentro de la lectura. Una reasignación confirmada después de ese snapshot aparece en la siguiente comprobación; una operación contra el plan anterior sigue pasando por las verificaciones de autorización, revisión e idempotencia existentes y produce conflicto cuando corresponde.

`GET /repartidor/api/v1/work` conserva el protocolo versión 4 y el payload completo de clientes anteriores. Las operaciones, UUID, fotos, firmas y autorizaciones existentes no se migran ni se eliminan. Los bloqueos de escritura de confirmación, planificación y reasignación se conservan.

La revisión se calcula sobre filas ordenadas de hojas, visitas, ítems, clientes, pedidos, programaciones, publicación, datos de perfil, historia reciente y contador de avisos. Incluye altas, bajas y valores, no solo `MAX(updated_at)`: detecta también eliminaciones, reasignaciones y actualizaciones sin timestamp. Se vincula a la sesión y a la presentación del servidor. Un cambio de hora fuerza renovar los grants de 48 horas, aunque el plan no cambie.

El cliente conserva un ETag por cuenta en el store `meta` existente de IndexedDB. No cambia la versión de la base ni modifica operaciones pendientes. Envía `If-None-Match`; con revisión vigente, Rails responde **304**, sin serializar paquetes ni generar HTML. Devuelve cuenta, versión y un CSRF fresco en headers. El token queda solo en memoria. Cada comprobación requiere sesión válida: conocer un ETag no otorga acceso. Si faltan paquetes locales, el cliente solicita una descarga completa para recuperarlos. Al cambiar de cuenta, rechaza respuestas ajenas.

El HTML sigue usando las mismas vistas ERB. Las revisiones de visita utilizan las asociaciones precargadas y el dashboard reutiliza sus consultas dentro de la misma petición. No hay un segundo renderizador de la interfaz ni caché HTTP compartida de datos privados; se conserva `Cache-Control: no-store`. Las respuestas 304 se gestionan explícitamente en el cliente.

## Benchmark reproducible, exclusivamente local

```sh
# Recrea únicamente la base app_repartos_benchmark, nunca la principal/test.
docker compose exec -e RAILS_ENV=test -e CI=true -e RAILS_MAX_THREADS=55 \
  -e BENCHMARK_STOPS=30 -e BENCHMARK_REVISION=revision-a-medir web bin/benchmark-driver-work
# Repetir con BENCHMARK_STOPS=100 para hojas mayores.
```

La herramienta rechaza otros entornos, fuerza un nombre de base independiente y recrea allí el schema. Requiere que el usuario PostgreSQL local pueda crear esa base; no ejecutarla con credenciales ni red de producción. Genera 50 repartidores de una empresa y hojas de 30–100 paradas, un producto por parada. Simula olas de 5, 20 y 50 sesiones Rack independientes, incluyendo descarga inicial, actualización sin cambios y confirmación de visitas. Usa la API real y verifica las respuestas de sincronización.

Informa p50/p95, consultas por solicitud (sin hits de query cache), tiempo acumulado SQL, bytes de respuesta sin comprimir, RSS del proceso Ruby y un muestreo cada 20 ms de conexiones que esperan locks. Es un benchmark dentro del proceso Rack con PostgreSQL real, no una prueba HTTP de Puma, TLS, red móvil, compresión o balanceo. El GVL, pool de conexiones, caché del host y las otras aplicaciones del equipo afectan los resultados. No incluye archivos pesados ni permite inferir capacidad del VPS de 8 GB. Las escrituras siguen serializadas por empresa y deben medirse por separado de las lecturas. Repetir en un entorno equivalente al piloto antes de fijar límites comerciales.

La base queda local para inspección; se puede eliminar explícitamente con `dropdb app_repartos_benchmark` usando las credenciales del PostgreSQL de desarrollo. No borrar ni reutilizar las bases principales.

Referencias: [transacciones Rails](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html), [aislamiento PostgreSQL 18](https://www.postgresql.org/docs/18/transaction-iso.html).

## Medición local del 15/11/2026

Antes: `ca8f021` (la corrección del test no afecta ejecución). Después: implementación incremental de esta etapa. Una ola por escenario, misma herramienta y 30 paradas; equipo compartido de 15 GiB, pruebas de navegador concurrentes. Muestras pequeñas, sin intervalos de confianza ni simulación de red. Los JSON conservan también consultas, bytes, SQL, RSS y muestreo de locks.

| Repartidores | Escenario | p50 antes / después (ms) | p95 antes / después (ms) | Consultas antes / después | Cuerpo total antes / después (bytes) |
| --- | --- | --- | --- | --- | --- |
| 5 | initial | 2890.38 / 2166.84 | 5665.99 / 2261.47 | 79.0 / 30.0 | 1782038 / 1784793 |
| 5 | unchanged | 2682.28 / 417.55 | 4328.49 / 420.84 | 79.0 / 19.0 | 1782038 / 0 |
| 5 | sync | 1809.23 / 1552.73 | 1873.54 / 1603.97 | 44.0 / 42.0 | 1195 / 1195 |
| 20 | initial | 8759.27 / 8591.23 | 16693.67 / 9114.43 | 79.0 / 30.0 | 7101639 / 7112659 |
| 20 | unchanged | 6427.14 / 1673.74 | 11880.56 / 1679.48 | 79.0 / 19.0 | 7101639 / 0 |
| 20 | sync | 5364.39 / 9982.91 | 7308.08 / 10114.46 | 43.0 / 41.0 | 4795 / 4795 |
| 50 | initial | 21224.67 / 21858.16 | 42596.98 / 22462.52 | 79.0 / 30.0 | 17683147 / 17710697 |
| 50 | unchanged | 23202.62 / 3431.96 | 40568.58 / 3436.44 | 79.0 / 19.0 | 17683147 / 0 |
| 50 | sync | 14640.99 / 7786.27 | 15937.07 / 8327.47 | 42.4 / 40.4 | 12011 / 12011 |

Las lecturas posteriores no tuvieron conexiones esperando locks en este muestreo. Las confirmaciones conservaron hasta 49 conexiones esperando, pues sus reglas de escritura no cambiaron. El muestreo previo global también alcanzó 49, pero no separaba fases; no permite atribuir a cada fase una reducción exacta del tiempo de lock.

El RSS final del proceso fue 574.772 KiB antes y 414.228 KiB después. Es memoria del proceso entero, incluyendo objetos retenidos y todas las sesiones, no memoria incremental por solicitud ni consumo completo del VPS.

No se demuestra una mejora estable de las escrituras: en 20 repartidores el p95 de sincronización fue peor después. Se necesita repetir sobre hardware equivalente y con cargas mixtas. En 50 descargas iniciales el p95 posterior fue 22,5 s; el cliente permite hasta 60 s para trabajo completo, manteniendo los plazos separados de operaciones y adjuntos. La descarga inicial sigue siendo costosa; los 304 evitan repetirla. No prometer 50 descargas simultáneas en un VPS de 8 GB sin pruebas HTTP adicionales ni considerar 60 s un objetivo de latencia.

Datos: [antes](benchmarks/driver-work-before.json), [después](benchmarks/driver-work-after.json). La ejecución de 100 paradas queda disponible con el comando anterior; esta comparación se midió con 30.
