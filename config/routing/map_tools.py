#!/usr/bin/env python3
"""Runs only inside the routing tools container. Never replaces a valid download."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

root = Path('/data')
command = sys.argv[1]
if command == 'download':
    url = os.environ['OSRM_PBF_URL']
    if not url.startswith('https://'):
        raise SystemExit('La fuente del mapa debe utilizar HTTPS')
    destination = root / 'downloads/argentina.osm.pbf'
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and '--update' not in sys.argv:
        saved_checksum = destination.with_suffix('.md5')
        if saved_checksum.exists() and hashlib.file_digest(destination.open('rb'), 'md5').hexdigest() == saved_checksum.read_text().strip():
            subprocess.run(['osmium', 'fileinfo', str(destination)], check=True, stdout=subprocess.DEVNULL)
            print('Se conserva el PBF descargado y verificado. Usá update para buscar una versión nueva.')
            sys.exit(0)
        print('El PBF local no coincide con su checksum; se descargará una copia verificada.')
    checksum = urllib.request.urlopen(url + '.md5', timeout=60).read().decode().split()[0]
    if len(checksum) != 32:
        raise SystemExit('Checksum MD5 de Geofabrik inválido')
    if destination.exists() and hashlib.file_digest(destination.open('rb'), 'md5').hexdigest() == checksum:
        print('El PBF ya coincide con Geofabrik.')
        sys.exit(0)
    temporary = destination.with_suffix('.download')
    digest = hashlib.md5()
    try:
        with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as output:
            while block := response.read(1024 * 1024):
                digest.update(block)
                output.write(block)
        if digest.hexdigest() != checksum:
            raise SystemExit('Descarga incompleta: el checksum no coincide; se preservó la versión anterior')
        subprocess.run(['osmium', 'fileinfo', '-F', 'pbf', str(temporary)], check=True, stdout=subprocess.DEVNULL)
        os.replace(temporary, destination)
        destination.with_suffix('.md5').write_text(checksum + '\n')
        print(f'PBF verificado: {destination.stat().st_size / 1024 / 1024:.1f} MiB')
    finally:
        temporary.unlink(missing_ok=True)
elif command == 'extract':
    source, target = sys.argv[2:4]
    bbox = os.environ.get('OSRM_BBOX', '')
    if bbox:
        subprocess.run(['osmium', 'extract', '--bbox', bbox, '--strategy', 'smart', source, '--output', target, '--overwrite'], check=True)
    else:
        import shutil
        shutil.copyfile(source, target)
    subprocess.run(['osmium', 'fileinfo', target], check=True)
else:
    raise SystemExit('Comando de mapas desconocido')
