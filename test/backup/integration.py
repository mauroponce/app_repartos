#!/usr/bin/env python3
"""Real local age/rclone/PostgreSQL round trip; never uses production databases."""
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
LOCK = open("/tmp/app-repartos-backup-integration.lock", "w")
fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
for executable in ("age", "age-keygen", "rclone", "docker"):
    if not shutil.which(executable):
        raise SystemExit(f"Missing {executable}; see docs/backups_r2.md")


def command(args, env=None, success=True):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=600)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected exit for {args[0:2]}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


alerts = []
class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        alerts.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), AlertHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
with tempfile.TemporaryDirectory(prefix="app-repartos-backup-test-") as temporary:
    work = Path(temporary)
    try:
        fixture = command(["docker", "compose", "exec", "-T", "-e", "RAILS_ENV=test", "web", "bin/rails", "runner", "test/backup/fixtures.rb"])
        data = json.loads(fixture.strip().splitlines()[-1])
        command(["age-keygen", "-o", str(work / "recovery-key")])
        (work / "recovery-key").chmod(0o600)
        recipient = command(["age-keygen", "-y", str(work / "recovery-key")]).strip()
        storage, remote, media = work / "storage", work / "remote/production", work / "media"
        remote.mkdir(parents=True)
        media.mkdir()
        for row in data["files"]:
            key = row["key"]
            target = storage / f"files/{key[:2]}/{key[2:4]}/{key}" if row["service"] == "persistent" else media / key
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(row["data"])
        config = work / "rclone.conf"
        config.write_text("[fixture]\ntype = local\n")
        env = {**os.environ, "BACKUP_DIR": str(work / "backups"), "APP_STORAGE_DIR": str(storage),
               "POSTGRES_CONTAINER": "app_repartos-db-1", "POSTGRES_ADMIN_USER": "repartos",
               "PRIMARY_DATABASE_NAME": data["primary"], "QUEUE_DATABASE_NAME": data["queue"],
               "AGE_RECIPIENT": recipient, "AGE_IDENTITY_FILE": str(work / "recovery-key"),
               "RCLONE_CONFIG": str(config), "BACKUP_RCLONE_REMOTE": f"fixture:{remote}",
               "BACKUP_MEDIA_REMOTE": f"fixture:{media}", "BACKUP_APP_VERSION": "technical-test-only",
               "BACKUP_KEEP": "1", "BACKUP_ALERT_WEBHOOK": f"http://127.0.0.1:{server.server_port}/"}
        output = command(["bin/vps-backup"], env)
        assert "externo cifrado y verificado" in output
        root = work / "backups"
        state = json.loads((root / "last-external.json").read_text())
        encrypted = root / state["file"]
        assert encrypted.read_bytes().startswith(b"age-encryption.org/v1")
        assert (remote / encrypted.name).read_bytes() == encrypted.read_bytes()
        assert all(path.name.endswith(".tar.age") for path in remote.iterdir())
        assert not list(root.glob(".creating-*"))
        command(["bin/check-backup"], env)
        assert encrypted.name in command(["bin/backup-remote", "list"], env)
        fetched = work / "downloaded.tar.age"
        command(["bin/backup-remote", "fetch", encrypted.name, str(fetched)], env)
        report = command(["bin/verify-backup", str(fetched)], env)
        result = json.loads(report.strip().splitlines()[-1])
        assert result["status"] == "verified" and result["storage"]["blobs"] == 2
        assert result["primary_counts"]["companies"] == 1
        assert result["primary_counts"]["users"] == 1
        command(["bin/vps-restore", str(fetched)], env, success=False)
        # Exercise the separately guarded destructive command ONLY against our
        # two disposable fixture databases and temporary storage directory.
        restore_env = {**env, "RESTORE_MAINTENANCE": "1", "RESTORE_CONFIRM": f"{data['primary']}:{data['queue']}", "RESTORE_STORAGE_SERVICE": "persistent"}
        command(["bin/vps-restore", str(fetched)], restore_env)
        assert len(list(storage.rglob("*backupfixture*"))) == 2
        recovery_state = command(["docker", "compose", "exec", "-T", "db", "psql", "-X", "-qAt", "-U", "repartos", "-d", data["primary"], "-v", "ON_ERROR_STOP=1", "-c",
                                  "SELECT (SELECT count(*) FROM sessions), (SELECT count(*) FROM driver_locations), (SELECT count(*) FROM users WHERE location_sharing_enabled), (SELECT min(location_consent_version) FROM users), (SELECT count(*) FROM users WHERE location_deactivated_at IS NOT NULL)"])
        assert recovery_state.strip() == "0|0|0|2|1", recovery_state
        prepared = work / "prepared"
        command(["bin/backup-remote", "prepare", str(fetched), str(prepared)], env)
        assert (prepared / "primary.dump").exists()
        legacy, upgraded = work / "legacy-v1", work / "upgraded-v2"
        legacy.mkdir(mode=0o700)
        upgraded.mkdir(mode=0o700)
        for name in ("primary.dump", "queue.dump", "files.tar.gz"):
            shutil.copyfile(prepared / name, legacy / name)
        (legacy / "manifest.txt").write_text("App Repartos backup v1\n")
        names = ["primary.dump", "queue.dump", "files.tar.gz", "manifest.txt"]
        (legacy / "SHA256SUMS").write_text("".join(f"{hashlib.sha256((legacy / name).read_bytes()).hexdigest()}  {name}\n" for name in names))
        command(["bin/verify-backup", "--upgrade-legacy", str(legacy), str(upgraded)], env)
        assert json.loads((upgraded / "manifest.json").read_text())["format"] == 2
        damaged = work / "damaged.tar.age"
        content = bytearray(fetched.read_bytes())
        content[-1] ^= 1
        damaged.write_bytes(content)
        command(["bin/verify-backup", str(damaged)], env, success=False)
        assert not list(root.glob(".restore-*"))
        local_file = next(storage.rglob("abcdbackupfixturelocal001"))
        original = local_file.read_bytes()
        local_file.unlink()
        count = len(list(remote.iterdir()))
        command(["bin/vps-backup"], env, success=False)
        assert len(list(remote.iterdir())) == count
        assert json.loads((root / "last-run.json").read_text())["status"] == "failed"
        command(["bin/check-backup"], env, success=False)
        local_file.write_bytes(original)
        failed_env = {**env, "BACKUP_RCLONE_REMOTE": "missing-remote:private/production"}
        command(["bin/vps-backup"], failed_env, success=False)
        assert json.loads((root / "last-external.json").read_text())["file"] == encrypted.name
        command(["bin/vps-backup"], {**env, "AGE_RECIPIENT": "invalid-recipient"}, success=False)
        assert json.loads((root / "last-run.json").read_text())["stage"] == "encryption"
        command(["bin/vps-backup"], {**env, "BACKUP_MIN_FREE_BYTES": "999999999999999"}, success=False)
        assert json.loads((root / "last-run.json").read_text())["stage"] == "space"
        old = remote / "backup-20200101T000000Z-000000000000.tar.age"
        shutil.copyfile(fetched, old)
        os.utime(old, (time.time() - 40 * 86400,) * 2)
        untouched = remote.parent / "unrelated.tar.age"
        untouched.write_text("unrelated prefix")
        command(["bin/vps-backup"], env)
        assert not old.exists() and untouched.exists()
        assert len(list(root.glob("backup-*.tar.age"))) == 1
        stale = json.loads((root / "last-external.json").read_text())
        missing = work / "temporarily-missing.tar.age"
        (remote / stale["file"]).rename(missing)
        command(["bin/check-backup"], env, success=False)
        missing.rename(remote / stale["file"])
        stale["at"] = "2020-01-01T00:00:00+00:00"
        (root / "last-external.json").write_text(json.dumps(stale))
        command(["bin/check-backup"], env, success=False)
        assert alerts and all(set(row) == {"application", "status", "action", "stage", "at"} for row in alerts)
        assert not list(root.glob(".creating-*")) and not list(root.glob(".restore-*"))
        print(json.dumps({"status": "passed", "encryption": "real-age", "remote": "rclone-local-fixture (not R2)",
                          "database_restore": "two isolated PostgreSQL 18 databases", "blobs_verified": 2,
                          "checks": ["round-trip", "catalog-and-files", "restore-guards", "guarded-restore-on-disposable-targets", "restore-revokes-sessions-and-gps", "legacy-v1-recovery", "corruption", "missing-file", "failed-upload", "encryption-failure", "space", "missing-remote", "staleness", "retention", "webhook", "temporary-cleanup"]}))
    finally:
        server.shutdown()
        for database in ("app_repartos_backup_test", "app_repartos_backup_queue_test"):
            subprocess.run(["docker", "compose", "exec", "-T", "db", "dropdb", "-U", "repartos", "--if-exists", "--force", database], cwd=ROOT, capture_output=True)
