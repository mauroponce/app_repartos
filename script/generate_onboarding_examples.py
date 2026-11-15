"""Generate real XLSX and UTF-8 CSV from the shared, fictional demo dataset."""
import csv
import json
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
from generate_customer_import_examples import workbook

DESTINATION = Path(__file__).resolve().parents[1] / 'docs/ejemplos/onboarding'


def generate():
    data = json.loads((DESTINATION / 'datos_demo.json').read_text())
    customers = [['Nombre', 'Teléfono', 'Dirección', 'Localidad', 'Código']] + [
        [row[key] for key in ('name', 'phone', 'address', 'city', 'external_code')]
        for row in data['customers']]
    minimal = [['Nombre', 'Teléfono', 'Dirección']] + [
        [row['name'], row['phone'], f"{row['address']}, {row['city']}, Buenos Aires"]
        for row in data['customers'][:6]]
    products = [['SKU', 'Nombre', 'Unidad', 'Contenido', 'Unidad de contenido', 'Activo']] + [
        [row[key] for key in ('sku', 'name', 'unit', 'package_content_quantity', 'package_content_unit', 'active')]
        for row in data['products']]
    for name, rows in [('clientes_demo', customers), ('clientes_demo_minimo', minimal), ('productos_demo', products)]:
        # The existing writer uses inline strings, preserving phones and 000015.
        workbook(DESTINATION / f'{name}.xlsx', [('Datos', rows)])
        # Fixed archive timestamps make reruns byte-for-byte reproducible.
        target = DESTINATION / f'{name}.xlsx'
        with ZipFile(target) as archive:
            entries = [(entry.filename, archive.read(entry)) for entry in archive.infolist()]
        with ZipFile(target, 'w', ZIP_DEFLATED) as archive:
            for filename, contents in entries:
                entry = ZipInfo(filename, (2026, 11, 15, 0, 0, 0))
                entry.compress_type = ZIP_DEFLATED
                archive.writestr(entry, contents)
        with (DESTINATION / f'{name}.csv').open('w', encoding='utf-8', newline='') as output:
            csv.writer(output).writerows(rows)


if __name__ == '__main__':
    generate()
