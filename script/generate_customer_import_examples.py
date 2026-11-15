#!/usr/bin/env python3
"""Generate deterministic XLSX samples without coordinates or external libraries."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
from xml.sax.saxutils import escape

DESTINATION = Path(__file__).resolve().parents[1] / 'docs/ejemplos/clientes'
HEADERS = ['Código', 'Comercio', 'Dirección', 'Localidad', 'Partido', 'Provincia']
LOCATIONS = [('Av. Espora 1200', 'Burzaco', 'Almirante Brown'), ('San Martín 800', 'Adrogué', 'Almirante Brown'),
             ('Alsina 450', 'Banfield', 'Lomas de Zamora'), ('Mitre 123', 'Lomas de Zamora', 'Lomas de Zamora'),
             ('Hipólito Yrigoyen 3500', 'Lanús', 'Lanús'), ('25 de Mayo 123', 'Quilmes', 'Quilmes'),
             ('Av. Mitre 1500', 'Avellaneda', 'Avellaneda'), ('Belgrano 450', 'Morón', 'Morón'),
             ('Av. San Martín 1500', 'San Martín', 'General San Martín')]


def sheet_xml(rows):
    body = []
    for row_index, row in enumerate(rows, 1):
        cells = []
        for column_index, value in enumerate(row):
            column = chr(65 + column_index)
            cells.append(f'<c r="{column}{row_index}" t="inlineStr"><is><t xml:space="preserve">{escape(str(value))}</t></is></c>')
        body.append(f'<row r="{row_index}">{"".join(cells)}</row>')
    return '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:' + chr(64 + max(len(row) for row in rows)) + str(len(rows)) + '"/><sheetData>' + ''.join(body) + '</sheetData></worksheet>'


def workbook(path, sheets):
    namespace = 'http://schemas.openxmlformats.org'
    with ZipFile(path, 'w', ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', f'<Types xmlns="{namespace}/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' + ''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1, len(sheets) + 1)) + '</Types>')
        archive.writestr('_rels/.rels', f'<Relationships xmlns="{namespace}/package/2006/relationships"><Relationship Id="rId1" Type="{namespace}/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        archive.writestr('xl/workbook.xml', f'<workbook xmlns="{namespace}/spreadsheetml/2006/main" xmlns:r="{namespace}/officeDocument/2006/relationships"><sheets>' + ''.join(f'<sheet name="{escape(name)}" sheetId="{i}" r:id="rId{i}"/>' for i, (name, _) in enumerate(sheets, 1)) + '</sheets></workbook>')
        archive.writestr('xl/_rels/workbook.xml.rels', f'<Relationships xmlns="{namespace}/package/2006/relationships">' + ''.join(f'<Relationship Id="rId{i}" Type="{namespace}/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1, len(sheets) + 1)) + '</Relationships>')
        for i, (_, rows) in enumerate(sheets, 1):
            archive.writestr(f'xl/worksheets/sheet{i}.xml', sheet_xml(rows))


def generate():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    simple = [HEADERS] + [[f'DEMO-{i:04}', f'Comercio de ejemplo {i}', street, city, district, 'Buenos Aires'] for i, (street, city, district) in enumerate(LOCATIONS, 1)]
    incomplete = [HEADERS, ['INC-001', 'Ejemplo sin altura', 'Belgrano', 'Adrogué', '', 'Buenos Aires'],
                  ['INC-002', 'Ejemplo sin localidad', 'Belgrano 450', '', '', ''], ['INC-003', 'Referencia informal', 'a dos cuadras de la plaza', 'Morón', '', 'Buenos Aires'],
                  ['INC-004', '', 'Av. Mitre 1500', 'Avellaneda', '', 'Buenos Aires']]
    ambiguous = [HEADERS, ['AMB-001', 'Esquina', 'alsina esq mitre banfield', 'Banfield', '', 'Buenos Aires'],
                 ['AMB-002', 'Entre calles', 'calle 25 de mayo entre mitre y rivadavia', 'Quilmes', '', 'Buenos Aires'],
                 ['AMB-003', 'Ruta', 'ruta 4 km 21 cerca estacion', '', '', 'Buenos Aires'],
                 ['AMB-004', 'Altura aproximada', 'san martin al 800 adrogue', 'Adrogué', '', 'Buenos Aires']]
    large = [HEADERS] + [[f'GRANDE-{i:05}', f'Comercio de prueba {i}', *LOCATIONS[i % len(LOCATIONS)], 'Buenos Aires'] for i in range(2000)]
    for name, rows in [('simple', simple), ('incompleta', incomplete), ('ambigua', ambiguous), ('grande', large)]:
        sheets = [('Clientes', rows)]
        if name == 'simple':
            sheets.append(('Otra hoja', [HEADERS, ['DEMO-HOJA-2', 'Ejemplo segunda hoja', 'Mitre 123', 'Avellaneda', '', 'Buenos Aires']]))
        workbook(DESTINATION / f'clientes_importacion_{name}.xlsx', sheets)


if __name__ == '__main__':
    generate()
