#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_PASSWORD:?Missing application database password}"
psql --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 --set=app_password="$DATABASE_PASSWORD" <<'SQL'
CREATE ROLE repartos WITH LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE app_repartos_production OWNER repartos;
CREATE DATABASE app_repartos_production_queue OWNER repartos;
REVOKE ALL ON DATABASE app_repartos_production FROM PUBLIC;
REVOKE ALL ON DATABASE app_repartos_production_queue FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE app_repartos_production TO repartos;
GRANT CONNECT, TEMPORARY ON DATABASE app_repartos_production_queue TO repartos;
SQL
