# Importación de clientes

En **Clientes → Importar clientes** se admiten CSV UTF-8 con coma/punto y coma y XLSX (primera hoja). Descargar la plantilla, cargar, mapear columnas en cualquier orden, actualizar la previsualización y confirmar. No se importan pedidos ni entregas.

Nombre, dirección y ciudad son indispensables. Teléfono, contacto, email, código externo y coordenadas son opcionales. Los registros sin coordenadas muestran **Ubicación pendiente**; se completan posteriormente desde la edición con mapa. No se consulta Photon durante la importación. OSRM/VROOM rechazan hojas con puntos faltantes.

El código externo es texto, opcional y único dentro de la empresa. Se conservan ceros iniciales en CSV y celdas Excel de texto o con máscara numérica de ceros. Excel ya puede haber truncado códigos numéricos de más de 15 dígitos: guardarlos como texto en origen. No es posible recuperar información que la planilla perdió.

Una coincidencia exacta de código actualiza el cliente de la sesión, mostrando cada cambio. No hay búsquedas entre empresas. Sin código se crea un registro nuevo; las coincidencias por nombre solo se advierten, con dirección y ciudad para revisarlas. Se requiere reconocer esa advertencia y se pueden excluir filas explícitamente. Nunca se fusionan clientes por nombre.

Las celdas vacías conservan los valores existentes. **Borrar valores existentes** permite borrar únicamente campos con una columna mapeada; requiere actualizar y revisar la previsualización. Cambiar dirección/ciudad sin un punto confirmado elimina las coordenadas antiguas. Para conservar un punto al cambiar el texto, suministrar ambas coordenadas.

La previsualización no escribe clientes y vence en 24 horas. Confirmar verifica de nuevo los datos y el contenido revisado dentro de una transacción. Si cambiaron mientras se revisaba, muestra otra previsualización. Un error bloquea todo el lote; corregirlo o excluir la fila y volver a revisar. Repetir la confirmación del mismo lote devuelve el resumen sin duplicar datos. Subir nuevamente otro lote sin códigos puede crear duplicados.

El resumen contiene creados, actualizados, filas omitidas, ubicación pendiente y errores. **Descargar errores** genera un CSV privado con número de fila, errores y advertencias; se neutralizan fórmulas de hojas de cálculo. Las columnas internas `company_id`, `empresa_id`, `customer_id` y `user_id` con valores se rechazan. La empresa siempre proviene de la sesión.

## Límites y operación

Predeterminados: 5 MB, 5.000 filas, 30 columnas, 200 entradas ZIP y 20 MB descomprimidos. `CUSTOMER_IMPORT_MAX_MB` permite 1–20 MB y `CUSTOMER_IMPORT_MAX_ROWS` 1–10.000 filas; reiniciar web al modificarlos. CSV binario, tipos incompatibles, ZIP con rutas inseguras/referencias externas y coordenadas inválidas se rechazan. Se verifica el tamaño realmente descomprimido antes de Roo, además del declarado por el ZIP. No se ejecutan fórmulas.

Las migraciones agregan `customers.external_code`, índice único parcial concurrente por empresa, staging `customer_imports` y permiten teléfono NULL. No cambian visitas, direcciones históricas ni operaciones offline pendientes. No revertir la nulabilidad sin completar antes los teléfonos ausentes. El índice se crea fuera de transacción: si una migración interrumpida deja un índice inválido, verificar `pg_index.indisvalid`, retirar solo ese índice inválido y reintentar.

La confirmación se serializa con otras modificaciones de planificación de la empresa para conservar sus reglas de concurrencia. Para lotes grandes conviene importar fuera del horario intenso de sincronización. La carga es sincrónica y debe medirse con datos del cliente antes de aumentar los límites.

Verificación:

```sh
docker compose exec web bin/rails db:migrate
docker compose exec -e RAILS_ENV=test web bin/rails test test/services/customer_importer_test.rb test/controllers/customer_imports_controller_test.rb test/services/product_importer_test.rb
```
