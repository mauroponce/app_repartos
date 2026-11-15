# Límites provinciales de Argentina

`argentina_provinces.geojson` es una copia de las geometrías oficiales de Georef, descargada de `https://apis.datos.gob.ar/georef/api/v2.0/provincias.geojson` (el endpoint redirige a la descarga oficial). WGS84 / EPSG:4326, orden longitud, latitud. Incluye 24 jurisdicciones, con CABA separada de Buenos Aires. No contiene información de clientes.

Se utiliza para comprobar localmente que un candidato o punto confirmado pertenece a la provincia configurada de la empresa, incluso sin conectividad. El nombre declarado por un proveedor no reemplaza esta comprobación. Un punto exactamente en el límite no tiene garantía de aceptación y debe revisarse conservadoramente.

Para actualizar: descargar de nuevo la fuente oficial, verificar que contiene 24 features Polygon/MultiPolygon con los mismos nombres e IDs, ejecutar las pruebas `test/services/geocoding/province_boundary_test.rb` y revisar especialmente el límite CABA/Provincia de Buenos Aires antes de desplegar. Las geometrías son datos geográficos abiertos del servicio oficial, no coordenadas sintéticas de demostración.

Documentación: https://www.argentina.gob.ar/georef/georef-servicio-de-normalizacion-de-direcciones-y-unidades-territoriales-de-argentina-5
