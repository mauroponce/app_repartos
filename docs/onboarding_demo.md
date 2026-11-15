# Onboarding de App Repartos

## Iniciar y actualizar el entorno local

Desde la raíz del proyecto:

```sh
docker compose up -d --build
docker compose exec -T web bin/rails db:migrate
docker compose restart web worker
docker compose exec -T web bin/rails demo:onboarding
```

La aplicación abre en <http://localhost:3006>. `web`, `worker` y `db` deben estar activos. El worker de Solid Queue tiene una cola `customer_imports` dedicada: leer, preparar, geocodificar y confirmar son tareas asíncronas. La pantalla consulta el progreso automáticamente; podés salir y volver sin perder el lote. `docker compose logs --tail=100 worker` permite diagnosticar trabajos detenidos. Después de actualizar código de jobs, reiniciar el worker.

`db:seed` conserva Distribuidora Sur, Distribuidora Norte y los escenarios de RoutingDemoSeeds y agrega el onboarding. `demo:onboarding` carga solo este último. Ninguna tarea demo está habilitada en producción. No es necesario borrar ni reiniciar la base.

## Cuentas exclusivas de desarrollo

| Cuenta | Email | Contraseña |
| --- | --- | --- |
| Propietario de plataforma | plataforma@repartos.test | Plataforma-demo-2026 |
| Administrador de Distribuidora Piloto AMBA | admin@piloto.test | Piloto-demo-2026 |
| Juan Rodríguez | juan@piloto.test | Piloto-demo-2026 |
| Camila Fernández | camila@piloto.test | Piloto-demo-2026 |
| Martín López | martin@piloto.test | Piloto-demo-2026 |

Plataforma usa <http://localhost:3006/plataforma>. Los usuarios de empresas ingresan en <http://localhost:3006/session/new>. Los repartidores son redirigidos a `/repartidor`. Las sesiones de plataforma y de empresas tienen cookies y registros separados; cerrar una no otorga ni revoca la otra identidad. La sesión de plataforma vence a las 12 horas y cambiar su contraseña revoca sus sesiones.

La cuenta de plataforma administra altas y metadatos de empresas. Para abrir los recursos privados de una distribuidora se necesita iniciar sesión por separado con un usuario de esa empresa.

Reejecutar el seed conserva contraseñas, emails, SKU, observaciones, nombres editados, asignaciones, estados e historial. Una vez creado el escenario completo, sus claves de hojas identifican que ya fue inicializado y el seed no vuelve a poblarlo. Si cambiaste una contraseña o email, usá los nuevos. El seed no reactiva usuarios que hayas desactivado.

## Modalidad 1: exploración rápida

Ingresar con `admin@piloto.test`. La empresa **Distribuidora Piloto AMBA** contiene:

| Datos iniciales | Cantidad |
| --- | ---: |
| Administradores operativos | 1 |
| Repartidores activos | 3 |
| Clientes | 30 |
| Productos | 16 |
| Programaciones semanales, con dos productos cada una | 20 |
| Entregas generadas | 20 |
| Hojas asignadas y publicadas manualmente | 3 |
| Paradas en las hojas | 18 |

Las hojas tienen seis paradas cada una: lunes 08:00–12:00 para Juan, lunes 14:00–18:00 para Camila y martes 08:00–12:00 para Martín. Hay además dos programaciones de miércoles 09:00–13:00, con sus entregas pendientes de planificación. Los horarios son valores locales de `America/Argentina/Buenos_Aires`.

El primer seed elige el próximo lunes, incluyendo hoy si es lunes. Las siguientes ejecuciones conservan esa semana mediante claves `onboarding:v1:*`; nunca trasladan las hojas históricas. Para una semana posterior, generar las recurrencias y planificar nuevas hojas desde la interfaz.

Los 18 clientes de las hojas tienen **puntos sintéticos**, marcados en su contacto como `DEMO: punto sintético, no geocodificación de la dirección`. El código construye una grilla cercana a AMBA sur (origen aproximado -34.79, -58.40) para mostrar mapas y recorridos. Se guardan como confirmaciones manuales de demostración. No son domicilios comerciales verificados ni respuestas de Georef/Photon. Los otros 12 clientes no tienen ubicación definitiva. El seed no consulta APIs.

Ingresar por separado con cada repartidor. La PWA muestra la jornada de hoy y, bajo **Próximas hojas asignadas**, las hojas propias de los próximos 14 días. Esa consulta requiere conexión y muestra fecha, orden, clientes, franjas y mercadería. El registro y la descarga offline de entregas siguen reservados a la jornada actual. El día asignado se puede abrir una parada, completar cantidades y guardar; con conexión se sincroniza y administración observa el resultado. GPS permanece desactivado salvo una acción expresa del usuario.

**No importar clientes_demo.xlsx sobre esta empresa poblada para probar el alta desde cero.** Sus códigos CLI-001…CLI-030 ya existen. El importador inteligente no fusiona ni actualiza clientes existentes: señala el conflicto y requiere omitir o corregir esas filas. Los productos con SKU sí se actualizan dentro de su empresa; reimportar el mismo SKU conserva un único producto.

## Modalidad 2: onboarding desde cero

1. Ingresar en `/plataforma` con la cuenta de propietario y elegir **Crear empresa**.
2. Completar nombre, un slug nuevo, provincia Buenos Aires, zona horaria, moneda y datos del administrador. La contraseña inicial requiere al menos 12 caracteres con letras y números. Provincia y coordenadas se validan conjuntamente en la importación. Un slug o email repetido impide toda la operación; no queda una empresa parcial.
3. Al crear, el detalle muestra el administrador principal y el enlace al login. No se vuelve a mostrar la contraseña. Cerrar la sesión de plataforma e ingresar con la cuenta de la nueva empresa. Su listado de clientes estará vacío.
4. En **Clientes → Importar clientes**, subir `docs/ejemplos/onboarding/clientes_demo.xlsx`. Esperar la lectura y revisar los mapeos Nombre, Teléfono, Dirección, Localidad y Código. No hay columnas de coordenadas. Confirmar Buenos Aires como provincia de la empresa y elegir **Procesar direcciones**.
5. Esperar el avance y revisar los cinco totales: confiables, manuales, aproximados, ambiguos y sin ubicación. Los resultados reales dependen de la cobertura de los proveedores. Una altura interpolada de Georef no se confirma automáticamente. Gemini es opcional y solo interpreta componentes; no aporta coordenadas cartográficas.
6. Usar **Revisar fila** para inspeccionar dirección original, normalizada, candidatos y mapa. Seleccionar un candidato solo posiciona el marcador: confirmar manualmente únicamente cuando exista evidencia del punto de entrega. Se puede corregir el punto, guardar sin ubicación u omitir la fila. Los puntos fuera de provincia se rechazan. Para importar pendientes, marcar la autorización correspondiente: esos clientes seguirán administrables, sin un punto definitivo para optimizar.
7. Elegir **Confirmar importación**, esperar **Importación confirmada** y **Ver clientes**. Repetir la confirmación del mismo lote no crea duplicados. Un nuevo lote con los mismos códigos exige resolver los conflictos. Los resultados se conservan en el lote según la retención configurada; los clientes ya creados permanecen.
8. Para probar el archivo mínimo, crear otra empresa vacía e importar `clientes_demo_minimo.xlsx`. Contiene seis clientes con solo Nombre, Teléfono y Dirección; por ejemplo `Mitre 450, Adrogué, Buenos Aires`. La localidad se extrae del texto. No importarlo como otro lote en una empresa donde ya cargaste los mismos comercios: al no tener códigos, puede señalar coincidencias y necesita revisión humana.
9. En **Productos → Importar CSV / Excel**, subir `productos_demo.xlsx`, revisar mapeo y vista previa y confirmar. Se muestran 16 SKU, incluido `000015` como texto. Bolsa→bag, unidad→unit, caja→box, paquete→pack, kilo/kilogramo→kg, gramo→g y litro→l; también se normaliza la unidad del contenido. Una unidad desconocida impide confirmar. Reimportar actualiza el catálogo por SKU sin duplicarlo; las filas sin SKU requieren autorización y crearían productos nuevos.
10. En **Repartidores → Nuevo**, crear Juan Rodríguez, Camila Fernández y Martín López con emails únicos `.test`, contraseña y estado activo. El formulario siempre crea rol driver de la empresa actual.
11. Abrir cada cliente y **Nueva programación**. Elegir día, fecha de inicio y franja; agregar productos del catálogo con cantidades. Ejemplo: dos bolsas de harina y tres gaseosas. Preparar seis clientes para lunes 08:00–12:00, seis para lunes 14:00–18:00 y seis para martes 08:00–12:00. Agregar una programación de miércoles 09:00–13:00 para probar otra franja. No combinar horario puntual y franja.
12. En **Entregas**, desplegar **Generar entregas desde programaciones** y elegir el lunes. Repetir conserva las entregas existentes. Generar también martes y miércoles. Revisar productos, cantidades y horarios en las entregas generadas. **Nueva entrega** permite cargar un pedido puntual adicional sin crear una recurrencia.
13. En **Hojas de ruta → Nueva hoja**, completar nombre, fecha y repartidor; continuar, seleccionar las entregas de esa fecha, ordenar paradas y guardar. Crear una hoja por grupo/repartidor. En el detalle, **Publicar con orden manual** y aceptar la confirmación. No requiere OSRM ni afirma haber optimizado. Si previamente había un cálculo fallido o pendiente, esta acción libera la publicación y descarta esa propuesta.
14. Cerrar la sesión operativa e ingresar con cada repartidor. Verificar sus próximas hojas y sus cantidades. Para ejecutar una entrega hoy, crear una entrega puntual con fecha de hoy y una hoja asignada y publicada al mismo repartidor. En la PWA abrir la parada, registrar cantidades, aceptar la confirmación y guardar. Esperar la sincronización. Volver como administrador y comprobar el estado de la visita, pedido y hoja.

## Planillas y regeneración

Los siguientes archivos están versionados, son XLSX reales con celdas de texto y también tienen alternativa CSV UTF-8:

- [clientes_demo.xlsx](ejemplos/onboarding/clientes_demo.xlsx): 30 comercios ficticios, 24 direcciones completas y 6 incompletas/ambiguas. Los domicilios son ilustrativos y no se consideran ubicaciones verificadas.
- [clientes_demo_minimo.xlsx](ejemplos/onboarding/clientes_demo_minimo.xlsx): seis clientes y tres columnas.
- [productos_demo.xlsx](ejemplos/onboarding/productos_demo.xlsx): 16 productos, unidades legibles, contenido y estado.

`datos_demo.json` es la fuente común de planillas y seed. Los teléfonos son ficticios y se escriben como texto, igual que los códigos y SKU. No se admite XLS antiguo.

```sh
python3 script/generate_onboarding_examples.py
docker compose exec -T web bin/rails runner script/check_onboarding_seeds.rb
```

El generador usa solo Python estándar y el escritor XLSX existente. Sus salidas tienen timestamps ZIP fijos para ser reproducibles byte por byte. El chequeo del seed compara también contraseñas y asignaciones, sin imprimir hashes ni contraseñas.

## Pruebas automatizadas en Docker

La ejecución integral usa bases efímeras independientes de desarrollo y no publica puertos:

```sh
docker compose -f compose.ci.yml up --build --abort-on-container-exit --exit-code-from ci
```

Incluye migraciones/preparación desde una base vacía, Minitest completo, tests JS y offline, RuboCop, Brakeman, auditorías y todos los escenarios Playwright. Ver `docs/ci.md` para conservar trazas y consultar logs. El uso existente de `db:seed:replant` en `bin/ci` está limitado a `RAILS_ENV=test`; no ejecutarlo en desarrollo.

Rails 8.1 puede inicializar `db:migrate` desde `schema.rb`. Para ejecutar además cada migración histórica desde cero, el siguiente chequeo crea y elimina una base temporal propia, exclusivamente en test:

```sh
docker compose -f compose.ci.yml run --rm ci sh -c 'bin/rails db:prepare && bin/rails runner script/check_test_migrations.rb'
```

Para repetir solamente el nuevo navegador, después de construir la imagen CI:

```sh
docker compose -f compose.ci.yml up -d db
docker compose -f compose.ci.yml run --rm ci sh -c 'bin/rails db:prepare && bin/rails tailwindcss:build && PWA_TEST_SERVER=1 npm run test:browser -- onboarding_completo.spec.js'
```

El escenario principal crea una empresa vacía mediante plataforma, importa los dos catálogos desde los XLSX, revisa una ubicación en el mapa, crea los tres repartidores, 19 recurrencias, 20 entregas y cuatro hojas mediante formularios reales. Tres hojas prueban lunes/martes y la cuarta permite registrar una entrega hoy sin alterar el reloj ni las fechas históricas. Comprueba sincronización, administración y accesos cruzados desde otra empresa. Un segundo escenario importa el XLSX mínimo. El tercero inicia un worker real de Solid Queue y verifica cuatro jobs encadenados persistidos y finalizados: lectura, preparación, geocodificación y confirmación.

Las pruebas usan un servidor HTTP local con respuestas controladas en formato Georef/Photon. Siguen ejecutando parsers, cache, validación de provincia, evaluator y jobs reales. La importación principal produce 20 confiables, 2 aproximados, 2 ambiguos y 6 sin ubicación; tras confirmar una aproximada manualmente quedan **20 confiables, 1 manual y 9 pendientes**. Estos resultados pertenecen exclusivamente a fixtures sintéticos, no certifican los domicilios del archivo en proveedores públicos.

## Verificaciones externas opcionales

Nunca se ejecutan automáticamente en CI ni durante seeds. Para consultar solo tres direcciones, sin crear ni modificar clientes, obtener el ID de una empresa de Buenos Aires y ejecutar explícitamente:

```sh
docker compose exec -T -e EXTERNAL_GEOCODING_CHECK=1 -e COMPANY_ID=ID web bin/rails runner script/check_onboarding_geocoding.rb > resultados-geocodificacion.json
```

Respeta cache, cuotas y límites. Registra normalización, proveedores, candidatos, precisión, advertencias o aplazamientos. No exige que todos sean exactos. Un resultado aproximado continúa necesitando evidencia manual; no se inventan puntos para completar registros.

OSRM puede iniciarse con el perfil y el mapa descritos en `docs/osrm.md`. Con servicio operativo, una comprobación del motor sobre los puntos **sintéticos** del seed, sin aplicar cambios de orden, es:

```sh
docker compose exec -T -e ONBOARDING_OSRM_CHECK=1 web bin/rails runner script/check_onboarding_routing.rb
```

Para direcciones de una empresa real, verificar primero sus ubicaciones y después usar **Optimizar ruta** en la hoja, revisar la propuesta y aplicarla desde la interfaz. Si el mapa o servicio no está disponible, la prueba externa debe fallar; el circuito básico sigue funcionando mediante publicación manual.

## Bootstrap de plataforma en producción

Las credenciales públicas anteriores no se cargan en producción. No hay registro público ni impersonación. En la instancia de aplicación, suministrar por el gestor de secretos `PLATFORM_ADMIN_NAME`, `PLATFORM_ADMIN_EMAIL` y `PLATFORM_ADMIN_PASSWORD` y ejecutar explícitamente:

```sh
RAILS_ENV=production bin/rails platform:bootstrap
```

La tarea valida las credenciales, cifra la contraseña y rechaza emails existentes sin cambiar su contraseña. No ingresar secretos como literales versionados ni usar contraseñas de demostración en producción. Aplicar migraciones antes de habilitar `/plataforma`.

## Implementación y correcciones

- [Migración de plataforma](../db/migrate/20261116040000_create_platform_administration.rb), `PlatformAdmin`, `PlatformSession`, `Current` y `Company`: autenticación independiente y vínculo opcional al administrador principal. Las empresas preexistentes conservan sus usuarios y restricciones de empresa.
- [Registro transaccional](../app/services/platform_company_registration.rb), controladores y vistas `platform/`, layout y rutas `/plataforma`, tarea `platform:bootstrap`: alta atómica, validaciones y sesiones separadas, sin registro público ni impersonación.
- [ProductImporter](../app/services/product_importer.rb) y ayuda de la pantalla de importación: se corrigió el rechazo de unidades legibles en español, incluyendo la unidad del contenido. El lector y sus límites de archivos permanecen con sus controles existentes; la confirmación conserva la actualización por SKU.
- `CustomerImportsController`, `CustomerImportJob` y resultados de importación: totales separados para ubicaciones manuales y su persistencia al confirmar. Se verificó el XLSX mínimo con el parser existente, que ya extrae localidades desde una celda Dirección.
- [DemoOnboardingSeeds](../app/services/demo_onboarding_seeds.rb), tarea `demo:onboarding` y `db/seeds.rb`: escenario independiente, sin consultas externas, sin modificar datos ya existentes. `DeliveryOrderGenerator` acepta un subconjunto de programaciones para que resembrar no genere entregas de recurrencias agregadas manualmente.
- `RepartidorController`, vistas `scheduled`/`upcoming` y enlace en la jornada: consulta de hojas propias próximas. Durante la regresión se detectó que incluir sus nombres en el HTML descargado cambiaba el contrato offline; la consulta quedó en una pantalla separada y los paquetes siguen conteniendo solo la jornada actual. Los tests anteriores se conservaron.
- [Datos compartidos](ejemplos/onboarding/datos_demo.json), generador y tres XLSX/CSV: identidades ficticias, teléfonos y SKU de texto, archivos reproducibles. `.dockerignore` incluye estos ejemplos en la imagen de CI.
- [Playwright completo](../test/browser/onboarding_completo.spec.js), servidor HTTP controlado, preparación/inspección aislada y chequeo de Solid Queue, junto con tests Minitest de plataforma, planillas, seed y PWA: verificación del circuito real y de accesos cruzados, sin sustituir las altas de navegador por modelos precargados.

La prueba real de geocodificación queda como ejecución externa opcional; las direcciones ilustrativas no fueron certificadas comercialmente. Los puntos del seed y de las respuestas de navegador son sintéticos y están documentados como tales. La consulta de próximas hojas requiere conexión y la ejecución se habilita únicamente el día correspondiente. No se desplegó a producción.

## Resultado de verificación — 15/11/2026

Código base revisado: `main`, `1c268461813d932a32ede447644f807bae3001fa`, coincidente con la referencia remota al comenzar. Se usó Ruby 3.4.12, Rails 8.1.4.1, PostgreSQL 18 y Node 24.19.0 en Docker.

El cierre integral ejecutó `bin/ci` usando la imagen CI existente y una copia aislada del código actual, montada en `/rails`, con las bases efímeras de `compose.ci.yml`. Se recrearon únicamente las bases **test del Compose aislado**; la base de desarrollo se conservó. La ejecución completa terminó correctamente en **22 min 56 s**.

| Verificación y comando ejecutado | Resultado |
| --- | --- |
| `bin/rails runner script/check_test_migrations.rb` en Docker test | 33 migraciones reales desde cero; sin cuentas privilegiadas; base temporal eliminada |
| `bin/rails test` dentro de `bin/ci` | 484 pruebas, 3.706 aserciones; 0 fallos, 0 errores, 0 omitidas |
| `PWA_TEST_SERVER=1 npm run test:browser` dentro de `bin/ci` | 22 escenarios aprobados, incluidos onboarding completo, XLSX mínimo, Solid Queue y offline |
| `npm run test:js` | 40 pruebas aprobadas |
| `bin/rubocop --format simple` sobre el repositorio final | 326 archivos, sin infracciones |
| `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` | 0 errores y 0 advertencias de seguridad |
| `bin/bundler-audit check --update`, `npm audit`, `bin/importmap audit` | Sin vulnerabilidades detectadas; importmap conserva su exclusión preexistente de Leaflet local sin versión |
| `bin/check-backup-scripts` y `python3 -m unittest discover -s test/backup -p 'test_*.py'` | Comprobaciones aprobadas; 10 pruebas Python aprobadas |
| `RAILS_ENV=test bin/rails db:seed:replant` dentro de CI | Aprobado; no crea cuentas ni empresas demo en test |
| `bin/rails test test/services/demo_onboarding_seeds_test.rb`, regresión adicional final en bases de workers independientes | 2 pruebas y 28 aserciones aprobadas; conserva también SKU, emails y observaciones editados |
| `bin/rails runner script/check_onboarding_seeds.rb` en desarrollo | Idempotencia de identidades, contraseñas, asignaciones, fechas, estados y cantidades aprobada |
| `bin/rails runner script/check_routing_seeds.rb` en desarrollo | Seed completo anterior y nuevo ejecutado dos veces; escenarios Sur/Norte conservados e idempotentes |
| `python3 script/generate_onboarding_examples.py`, repetido y comparado por SHA-256 | Tres XLSX idénticos byte por byte; XLSX y CSV leídos por los tests |
| `ONBOARDING_OSRM_CHECK=1 bin/rails runner script/check_onboarding_routing.rb` en Docker desarrollo | Motor real operativo: cálculo exacto factible de seis puntos sintéticos; 2.814,4 m y 352,9 s de conducción; orden no aplicado |

El escenario de navegador confirmó **30 clientes: 20 confiables, 1 manual y 9 pendientes**, conservando sin coordenadas definitivas a los pendientes. Importó **16 SKU** dos veces sin duplicar, creó **3 repartidores**, **19 programaciones**, **20 entregas** y **4 hojas** mediante formularios. Una entrega se guardó desde la PWA y quedó sincronizada y visible para administración. La prueba independiente con worker real finalizó sus **4 jobs** encadenados y creó sus seis clientes aislados.

Desarrollo quedó reiniciado con `web` y `worker` activos: `/up` respondió HTTP 200 y `/plataforma` redirigió al login sin sesión. Queda pendiente únicamente la ejecución opcional contra geocodificadores públicos y la comprobación humana de los domicilios ilustrativos; esos resultados no se sustituyeron por los fixtures.
