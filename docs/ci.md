# Integración continua

El workflow `.github/workflows/ci.yml` responde a `push` y `pull_request` en cualquier rama. El job **Rails, JavaScript and security** usa Ubuntu 24.04, Ruby 3.4.12 desde `.ruby-version`, Rails 8.1 del lockfile, Node 24.19.0, Minitest y PostgreSQL 18. Las dependencias se instalan desde `Gemfile.lock` y `package-lock.json`.

El token sólo tiene `contents: read`; checkout no conserva credenciales y todas las actions están fijadas por SHA completo de sus repositorios oficiales. Al actualizar una action, verificar el commit upstream y actualizar su comentario de versión. No se usa `pull_request_target`, secretos, credenciales de producción ni deploy automático. La contraseña PostgreSQL del workflow es pública y exclusiva del servicio efímero de tests.

## Comando común

`bin/ci` es el punto de entrada tanto de Actions como de Compose. Fija por defecto `RAILS_ENV=test` y rechaza cualquier otro entorno antes de cargar Rails. Rails activa `CI=true`, incluyendo eager loading. Ejecuta secuencialmente:

1. `bin/setup --skip-server`: instala/verifica gems, ejecuta `db:prepare` y limpia logs y temporales.
2. `npm ci` y `bin/rails tailwindcss:build`.
3. `bin/rubocop`.
4. `bin/bundler-audit check --update`, `npm audit`, `bin/importmap audit` y `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error`.
5. `bin/rails test`, con dos workers de Minitest.
6. `RAILS_ENV=test bin/rails db:seed:replant`: comprueba que la tarea funciona en la base de prueba; los seeds demo sólo se cargan en development.
7. `npm run test:js`: incluye Photon y la cola offline de IndexedDB.
8. `PWA_TEST_SERVER=1 npm run test:browser`: escenarios offline reales de Chromium, incluyendo cierre/reapertura del navegador, actualización del worker, cambios de cuenta, errores 503 y sesión revocada.

El ejecutor Rails acumula los resultados y termina con código distinto de cero si falla cualquier paso. El workflow no usa `continue-on-error`, y Playwright no reintenta para ocultar fallos. También rechaza `test.only` en CI. Las auditorías necesitan conexión a sus fuentes públicas; un fallo de consulta bloquea el resultado exitoso.

El audit de importmap conserva su alcance actual: omite el archivo local de Leaflet porque su pin no declara una versión. La salida de la herramienta informa esa exclusión.

## Bases y navegador

`config/database.yml` toma `DATABASE_HOST`, `DATABASE_USERNAME` y `DATABASE_PASSWORD`. El servicio PostgreSQL espera el healthcheck antes de iniciar CI. El usuario efímero puede crear las bases `app_repartos_test`, `app_repartos_test_queue` y las copias que genera Minitest para sus workers. `db:prepare` prepara ambos esquemas, incluido `db/queue_schema.rb` de Solid Queue. Los tests de Active Job siguen usando el adaptador `test`; no se necesita un proceso worker.

La suite de navegador corre después de Minitest y de `db:seed:replant`, para evitar que borren datos mientras el navegador trabaja. Playwright inicia y detiene su propio Rails en `127.0.0.1:3006`, con `RAILS_ENV=test` y `PWA_BROWSER_TEST=1` para activar CSRF. No reutiliza servidores existentes. Los fixtures se ejecutan con `bin/rails runner` en la misma base de prueba, crean empresas temporales `pwa-test-*` y sólo eliminan sus propios datos. Chromium y sus dependencias se instalan con la versión de Playwright fijada en el lockfile.

## Ejecución con Docker Compose

Desde la raíz del repositorio, con Docker Engine y Docker Compose:

```sh
docker compose -f compose.ci.yml up --build --abort-on-container-exit --exit-code-from ci
```

`--exit-code-from ci` propaga el fallo de cualquier comprobación al shell. El target `ci` del Dockerfile agrega Node y Chromium; el target predeterminado de desarrollo conserva la imagen Ruby existente. La imagen incluye el código al construir: repetir `--build` después de cambiar archivos. No necesita Ruby, Node, Chrome ni gems en el host.

El proyecto aislado `app_repartos_ci` no monta el código, las gems ni los volúmenes PostgreSQL de desarrollo, y no publica puertos al host. PostgreSQL guarda sus datos en tmpfs: son descartables y desaparecen al detener o eliminar el contenedor. Puede ejecutarse junto al Compose de desarrollo. Para limpiar únicamente este proyecto:

```sh
docker compose -f compose.ci.yml down --volumes --remove-orphans
```

Para consultar un fallo antes de limpiar:

```sh
docker compose -f compose.ci.yml logs ci
docker compose -f compose.ci.yml cp ci:/rails/test-results ./test-results
docker compose -f compose.ci.yml cp ci:/rails/log/test.log ./log/ci-test.log
```

Actions conserva los diagnósticos disponibles (`test-results`, `playwright-report`, `log/test.log`) durante siete días cuando falla un paso. Las trazas pueden abrirse con `npx playwright show-trace test-results/RUTA/trace.zip`.

## Ejecución sin contenedor

Con Ruby 3.4.12, Bundler 2.6.2, Node 24.19.0, las bibliotecas de PostgreSQL/libvips y un PostgreSQL 18 local dedicado a tests:

```sh
export DATABASE_HOST=127.0.0.1
export DATABASE_USERNAME=repartos_ci
export DATABASE_PASSWORD=repartos_ci_local
bundle install
npm ci
npx playwright install --with-deps chromium
bin/ci
```

Crear previamente ese usuario PostgreSQL con permiso para crear bases, usando exclusivamente un servidor local de pruebas. El puerto 3006 debe estar libre para el servidor de Playwright. `PLAYWRIGHT_CHROMIUM_EXECUTABLE` permite elegir explícitamente otro Chromium instalado; CI usa el descargado por Playwright.

Para exigir que el job bloquee merges, agregar **Rails, JavaScript and security** a los status checks requeridos de la regla de protección/ruleset de la rama en GitHub. Esa configuración del repositorio no se aplica desde el YAML. La primera ejecución remota requiere subir los cambios; la verificación local no crea un run de Actions.

## Preparación comercial y backups

CI incluye ahora `bin/check-backup-scripts` (Bash y ShellCheck) y diez tests Python de integridad/seguridad de bundles. Python 3.11+ y ShellCheck están declarados en la imagen CI y en GitHub Actions. La integración real `bin/test-backups` se ejecuta por separado en un host Linux con Docker, age y rclone: crea únicamente sus dos bases y archivos desechables, usa un remote local y prueba también el comando protegido de restauración. No utiliza producción ni certifica R2/IAM real.

Los tests Rails incluyen el circuito Excel → planificación/optimización → recibo, evidencias/incidencia y control multiempresa. Chromium agrega onboarding XLSX/remapeo CSV y revocación GPS offline después de recargar. El servidor gestionado de Playwright inicia un pequeño stub de salud VROOM exclusivo de tests para el flujo de interfaz multivehículo existente, cuyo cálculo ya usa respuestas controladas. No se presenta como una prueba de VROOM real. En producción esa funcionalidad permanece deshabilitada explícitamente hasta verificar el backend.

Las mediciones reproducibles se documentan en [sincronización](sincronizacion_rendimiento.md) y [OSRM](osrm.md). No ejecutar benchmarks con credenciales/red de producción. Las pruebas físicas pendientes y la diferencia respecto de Chromium están en [dispositivos](pruebas_dispositivos_piloto.md).
