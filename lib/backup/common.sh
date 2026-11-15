#!/usr/bin/env bash
# Sourced by the backup tools; configuration contains paths/public keys only.
set -euo pipefail
umask 077
backup_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
backup_stage="init"
backup_cleanup_paths=()
backup_snapshot_pid=""
backup_snapshot_input=""
backup_snapshot_output=""

backup_init() {
  backup_action="${1:-backup}"
  backup_root="${BACKUP_DIR:-/var/backups/app-repartos}"
  backup_storage="${APP_STORAGE_DIR:-/var/lib/app-repartos/storage}"
  backup_db="${POSTGRES_CONTAINER:-app-repartos-db}"
  backup_user="${POSTGRES_ADMIN_USER:-postgres}"
  export PRIMARY_DATABASE_NAME="${PRIMARY_DATABASE_NAME:-app_repartos_production}"
  export QUEUE_DATABASE_NAME="${QUEUE_DATABASE_NAME:-app_repartos_production_queue}"
  backup_remote="${BACKUP_RCLONE_REMOTE:-}"
  backup_keep="${BACKUP_KEEP:-7}"
  backup_remote_days="${BACKUP_REMOTE_RETENTION_DAYS:-30}"
  backup_root="$(realpath -m "$backup_root")"
  backup_storage="$(realpath -m "$backup_storage")"
  for directory in "$backup_root" "$backup_storage"; do
    case "$directory" in /|/tmp|/var|/var/lib|/var/backups|/etc|/home|"$HOME"|/usr|/usr/local|/opt|/root)
      echo 'Usá directorios exclusivos de la aplicación, no directorios generales del sistema' >&2; return 1 ;;
    esac
  done
  [[ "$backup_root/" != "$backup_storage/"* && "$backup_storage/" != "$backup_root/"* ]] || { echo 'Separá los directorios de backups y adjuntos' >&2; return 1; }
  for value in "$backup_keep" "$backup_remote_days" "${BACKUP_MAX_AGE_HOURS:-36}"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo 'La retención y antigüedad deben ser enteros positivos' >&2; return 1; }
  done
  [[ "$PRIMARY_DATABASE_NAME" =~ ^[a-zA-Z0-9_]+$ && "$QUEUE_DATABASE_NAME" =~ ^[a-zA-Z0-9_]+$ ]] || { echo 'Nombre de base inválido' >&2; return 1; }
  [[ "$PRIMARY_DATABASE_NAME" != "$QUEUE_DATABASE_NAME" ]] || { echo 'Principal y Solid Queue requieren bases diferentes' >&2; return 1; }
  for database in "$PRIMARY_DATABASE_NAME" "$QUEUE_DATABASE_NAME"; do
    [[ "$database" != postgres && "$database" != template0 && "$database" != template1 ]] || { echo 'No se admiten bases de sistema como destino' >&2; return 1; }
  done
  mkdir -p "$backup_root"
  chmod 700 "$backup_root"
  trap 'backup_exit $?' EXIT
}

backup_notify() {
  local status="$1"
  printf 'Backup: %s (%s, %s)\n' "$status" "$backup_action" "$backup_stage" >&2
  [[ -n "${BACKUP_ALERT_WEBHOOK:-}" ]] || return 0
  local payload
  payload="$(python3 - "$status" "$backup_action" "$backup_stage" <<'PY'
import datetime,json,sys
print(json.dumps(dict(application='app-repartos', status=sys.argv[1], action=sys.argv[2], stage=sys.argv[3], at=datetime.datetime.now(datetime.timezone.utc).isoformat())))
PY
)"
  curl --silent --fail --connect-timeout 5 --max-time 10 --output /dev/null -H 'Content-Type: application/json' --data "$payload" "$BACKUP_ALERT_WEBHOOK" 2>/dev/null || printf 'No se pudo enviar la alerta de backup\n' >&2
}

backup_write_state() {
  local status="$1" external="${2:-false}" target="${3:-}"
  python3 - "$backup_root" "$backup_action" "$backup_stage" "$status" "$external" "$target" <<'PY'
import datetime,hashlib,json,os,pathlib,sys,tempfile
root,action,stage,status,external,target=sys.argv[1:]
state=dict(at=datetime.datetime.now(datetime.timezone.utc).isoformat(),action=action,stage=stage,status=status,external=external=='true')
if target:
 p=pathlib.Path(target)
 state.update(file=p.name,bytes=p.stat().st_size)
 with p.open('rb') as stream: state['sha256']=hashlib.file_digest(stream,'sha256').hexdigest()
name={'backup':'last-run.json','verify':'last-verification.json'}.get(action)
if name:
 fd,tmp=tempfile.mkstemp(prefix='.state-',dir=root)
 with os.fdopen(fd,'w') as out:
  json.dump(state,out);out.write('\n');out.flush();os.fsync(out.fileno())
 os.replace(tmp,pathlib.Path(root)/name)
 if status=='ok' and action=='backup' and state['external']:
  destination=pathlib.Path(root)/'last-external.json'
  fd,tmp=tempfile.mkstemp(prefix='.state-',dir=root)
  with os.fdopen(fd,'w') as out:
   json.dump(state,out);out.write('\n');out.flush();os.fsync(out.fileno())
  os.replace(tmp,destination)
PY
}

backup_exit() {
  local status="$1" path
  set +e
  if [[ -n "$backup_snapshot_input" ]]; then printf 'ROLLBACK;\n\\q\n' 1>&"$backup_snapshot_input" 2>/dev/null; fi
  [[ -z "$backup_snapshot_pid" ]] || kill "$backup_snapshot_pid" 2>/dev/null
  [[ -z "${backup_verify_container:-}" ]] || timeout 15s docker rm -f "$backup_verify_container" >/dev/null 2>&1
  for path in "${backup_cleanup_paths[@]}"; do [[ -z "$path" ]] || rm -rf -- "$path"; done
  if ((status != 0)); then backup_write_state failed; backup_notify failed; fi
}

backup_lock() {
  exec 9>"$backup_root/.backup.lock"
  flock -n 9 || { echo 'Ya hay un backup o una restauración en curso' >&2; return 1; }
}

backup_require_remote() {
  [[ "$backup_remote" =~ ^[a-zA-Z0-9_-]+:.+/.+ && "$backup_remote" != *$'\n'* && "$backup_remote" != *'/../'* && "$backup_remote" != */.. ]] || { echo 'Configurá BACKUP_RCLONE_REMOTE con bucket y prefijo exclusivos de producción' >&2; return 1; }
  command -v rclone >/dev/null
}

backup_space() {
  local minimum="${1:-${BACKUP_MIN_FREE_BYTES:-536870912}}" location="${2:-$backup_root}"
  python3 - "$location" "$minimum" <<'PY'
import shutil,sys
if not sys.argv[2].isdigit() or shutil.disk_usage(sys.argv[1]).free < int(sys.argv[2]):
 raise SystemExit('No hay espacio suficiente para crear/verificar el backup')
PY
}

backup_snapshot_start() {
  local database="$1"
  coproc BACKUP_SNAPSHOT { trap - EXIT; docker exec -i "$backup_db" psql -X -qAt -v ON_ERROR_STOP=1 -U "$backup_user" -d "$database"; }
  # Bash creates the PID variable for the named coprocess.
  # shellcheck disable=SC2153
  backup_snapshot_pid="$BACKUP_SNAPSHOT_PID"
  backup_snapshot_input="${BACKUP_SNAPSHOT[1]}"
  backup_snapshot_output="${BACKUP_SNAPSHOT[0]}"
  printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n' 1>&"$backup_snapshot_input"
  IFS= read -r -t 60 backup_snapshot <&"$backup_snapshot_output"
  [[ "$backup_snapshot" =~ ^[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9]+$ ]] || { echo 'No se pudo abrir el snapshot PostgreSQL' >&2; return 1; }
}

backup_snapshot_query() {
  docker exec "$backup_db" psql -X -qAt -v ON_ERROR_STOP=1 -U "$backup_user" -d "$PRIMARY_DATABASE_NAME" \
    -c "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET TRANSACTION SNAPSHOT '$backup_snapshot'; $1; COMMIT;"
}

backup_snapshot_finish() {
  printf 'COMMIT;\n\\q\n' 1>&"$backup_snapshot_input"
  wait "$backup_snapshot_pid"
  backup_snapshot_pid=""
  backup_snapshot_input=""
  backup_snapshot_output=""
}

backup_blob_sql='COPY (SELECT id, key, checksum, byte_size, service_name FROM active_storage_blobs ORDER BY key) TO STDOUT WITH CSV HEADER'
backup_counts_sql="SELECT json_build_object('companies',(SELECT count(*) FROM companies),'users',(SELECT count(*) FROM users),'customers',(SELECT count(*) FROM customers),'delivery_orders',(SELECT count(*) FROM delivery_orders),'visits',(SELECT count(*) FROM visits),'driver_sync_operations',(SELECT count(*) FROM driver_sync_operations))"

backup_capture() {
  local work="$1" target="$2" disk_size database_size needed
  [[ -n "${AGE_RECIPIENT:-}" ]] || { echo 'Falta la clave pública AGE_RECIPIENT' >&2; return 1; }
  command -v age >/dev/null
  mkdir -p "$work/media/files" "$work/empty/files"
  backup_stage="space"
  disk_size=0
  [[ ! -d "$backup_storage/files" ]] || disk_size="$(du -sb "$backup_storage/files" | cut -f1)"
  database_size="$(docker exec "$backup_db" psql -X -qAt -v ON_ERROR_STOP=1 -U "$backup_user" -d postgres -c "SELECT pg_database_size('$PRIMARY_DATABASE_NAME') + pg_database_size('$QUEUE_DATABASE_NAME')")"
  [[ "$database_size" =~ ^[0-9]+$ ]] || return 1
  needed=$((disk_size * 3 + database_size * 2 + ${BACKUP_MIN_FREE_BYTES:-536870912}))
  backup_space "$needed"
  backup_stage="primary-dump"
  backup_snapshot_start "$PRIMARY_DATABASE_NAME"
  if ! docker exec "$backup_db" pg_dump -U "$backup_user" -Fc --no-owner --no-privileges --snapshot "$backup_snapshot" "$PRIMARY_DATABASE_NAME" > "$work/primary.dump" 2>/dev/null; then echo 'Falló el dump principal' >&2; return 1; fi
  backup_snapshot_query "$backup_blob_sql" > "$work/blobs.csv"
  backup_snapshot_query "$backup_counts_sql" > "$work/primary-counts.json"
  backup_snapshot_finish
  backup_stage="queue-dump"
  if ! docker exec "$backup_db" pg_dump -U "$backup_user" -Fc --no-owner --no-privileges "$QUEUE_DATABASE_NAME" > "$work/queue.dump" 2>/dev/null; then echo 'Falló el dump de Solid Queue' >&2; return 1; fi
  backup_stage="files"
  python3 "$backup_lib/bundle.py" media-keys "$work/blobs.csv" "$work/media-keys.txt"
  local media_bytes
  media_bytes="$(python3 -c 'import csv,sys; print(sum(int(row["byte_size"]) for row in csv.DictReader(open(sys.argv[1])) if row["service_name"]=="r2"))' "$work/blobs.csv")"
  backup_space "$((media_bytes * 3 + disk_size * 2 + ${BACKUP_MIN_FREE_BYTES:-536870912}))"
  local tar_args=()
  if [[ -d "$backup_storage/files" ]]; then tar_args+=(-C "$backup_storage" files); else tar_args+=(-C "$work/empty" files); fi
  if [[ -s "$work/media-keys.txt" ]]; then
    [[ -n "${BACKUP_MEDIA_REMOTE:-}" ]] || { echo 'Hay adjuntos R2: configurá BACKUP_MEDIA_REMOTE con credenciales de lectura separadas' >&2; return 1; }
    command -v rclone >/dev/null
    rclone copy "$BACKUP_MEDIA_REMOTE" "$work/remote-media" --files-from "$work/media-keys.txt" --checkers 2 --transfers 2 --quiet
    python3 "$backup_lib/bundle.py" arrange-media "$work/blobs.csv" "$work/remote-media" "$work/media" "$backup_storage"
    tar_args+=(-C "$work/media" files)
  fi
  tar -czf "$work/files.tar.gz" "${tar_args[@]}"
  backup_stage="integrity"
  export BACKUP_POSTGRES_VERSION
  BACKUP_POSTGRES_VERSION="$(docker exec "$backup_db" pg_dump --version)"
  python3 "$backup_lib/bundle.py" manifest "$work"
  python3 "$backup_lib/bundle.py" verify "$work" >/dev/null
  backup_stage="encryption"
  local temporary="$target.creating"
  backup_cleanup_paths+=("$temporary")
  tar -C "$work" -cf - primary.dump queue.dump files.tar.gz blobs.csv primary-counts.json manifest.json files.json SHA256SUMS | age -r "$AGE_RECIPIENT" -o "$temporary"
  python3 - "$temporary" "$target" <<'PY'
import os,sys
with open(sys.argv[1],'rb') as stream: os.fsync(stream.fileno())
os.replace(sys.argv[1],sys.argv[2])
fd=os.open(os.path.dirname(sys.argv[2]),os.O_DIRECTORY)
os.fsync(fd);os.close(fd)
PY
}

backup_open_source() {
  local source="$1"
  if [[ -d "$source" ]]; then
    if [[ -f "$source/manifest.txt" && ! -f "$source/manifest.json" ]]; then
      backup_source="$(mktemp -d "$backup_root/.legacy-XXXXXX")"
      backup_cleanup_paths+=("$backup_source")
      "$(dirname "$(dirname "$backup_lib")")/bin/verify-backup" --upgrade-legacy "$source" "$backup_source" >/dev/null
      return
    fi
    backup_source="$(realpath "$source")"
    python3 "$backup_lib/bundle.py" verify "$backup_source" >/dev/null
    return
  fi
  [[ -r "$source" && "$source" == *.tar.age ]] || { echo 'Seleccioná un archivo .tar.age descargado o un directorio v2 verificado' >&2; return 1; }
  [[ -r "${AGE_IDENTITY_FILE:-}" ]] || { echo 'La restauración requiere AGE_IDENTITY_FILE, conservada fuera del VPS' >&2; return 1; }
  [[ $((8#$(stat -c %a "$AGE_IDENTITY_FILE") & 077)) == 0 ]] || { echo 'La clave privada requiere permisos 0600' >&2; return 1; }
  backup_space "$(( $(stat -c %s "$source") * 3 + ${BACKUP_MIN_FREE_BYTES:-536870912} ))"
  backup_stage="decryption"
  backup_source="$(mktemp -d "$backup_root/.restore-XXXXXX")"
  backup_cleanup_paths+=("$backup_source")
  age -d -i "$AGE_IDENTITY_FILE" -o "$backup_source/bundle.tar" "$source"
  python3 "$backup_lib/bundle.py" extract-bundle "$backup_source/bundle.tar" "$backup_source"
  rm "$backup_source/bundle.tar"
  python3 "$backup_lib/bundle.py" verify "$backup_source" >/dev/null
}
