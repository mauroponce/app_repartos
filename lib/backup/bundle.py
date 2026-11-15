#!/usr/bin/env python3
"""Bounded, path-safe backup validation. No production connections or secrets."""
import base64
import csv
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
from datetime import datetime, timezone

FILES = {"primary.dump", "queue.dump", "files.tar.gz", "blobs.csv", "primary-counts.json", "manifest.json", "files.json"}
KEY = re.compile(r"[A-Za-z0-9_-]{1,255}\Z")
MAX_FILES = int(os.environ.get("BACKUP_MAX_FILES", "200000"))
MAX_EXPANDED = int(os.environ.get("BACKUP_MAX_EXPANDED_BYTES", str(1024 ** 4)))
MAX_METADATA = 64 * 1024 ** 2


def fail(message):
    raise ValueError(message)


def json_file(path):
    if path.stat().st_size > MAX_METADATA:
        fail("Metadata exceeds 64 MiB")
    with path.open() as stream:
        return json.load(stream)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or "\x00" in name:
        fail("Unsafe archive path")
    return str(path)


def catalog(path):
    if path.stat().st_size > MAX_METADATA:
        fail("Blob catalog exceeds 64 MiB")
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ["id", "key", "checksum", "byte_size", "service_name"]:
            fail("Invalid blob catalog columns")
        rows = {}
        for row in reader:
            key = row["key"]
            if not KEY.fullmatch(key) or key in rows or not row["byte_size"].isdigit():
                fail("Invalid or duplicate blob key/size")
            if int(row["byte_size"]) > MAX_EXPANDED:
                fail("Blob exceeds restore limit")
            rows[key] = row
            if len(rows) > MAX_FILES:
                fail("Too many blobs")
        return rows


def blob_path(key):
    return f"files/{key[:2]}/{key[2:4]}/{key}"


def inspect_files(folder, write=False):
    expected = {blob_path(key): row for key, row in catalog(folder / "blobs.csv").items()}
    actual = {}
    total, entries = 0, 0
    with tarfile.open(folder / "files.tar.gz", "r|gz") as archive:
        for member in archive:
            entries += 1
            if entries > MAX_FILES * 4:
                fail("Too many archive entries")
            name = safe_name(member.name)
            if not (name == "files" or name.startswith("files/")):
                fail("Only Active Storage files may be archived")
            if member.isdir():
                continue
            if not member.isfile() or name in actual:
                fail("Links, special files or duplicate files are not accepted")
            total += member.size
            if total > MAX_EXPANDED or len(actual) >= MAX_FILES:
                fail("Archive exceeds restore limit")
            sha, md5 = hashlib.sha256(), hashlib.md5(usedforsecurity=False)
            size = 0
            source = archive.extractfile(member)
            while chunk := source.read(1024 ** 2):
                sha.update(chunk)
                md5.update(chunk)
                size += len(chunk)
            if size != member.size:
                fail("Truncated storage file")
            if name in expected:
                row = expected[name]
                if size != int(row["byte_size"]):
                    fail("An attachment size does not match the database snapshot")
                if row["checksum"] and base64.b64encode(md5.digest()).decode() != row["checksum"]:
                    fail("An attachment checksum does not match the database snapshot")
            actual[name] = {"sha256": sha.hexdigest(), "bytes": size}
    if expected.keys() - actual.keys():
        fail("An attachment referenced by the database snapshot is missing")
    if write:
        (folder / "files.json").write_text(json.dumps(actual, sort_keys=True) + "\n")
    elif json_file(folder / "files.json") != actual:
        fail("Storage contents do not match the file manifest")
    return {"files": len(actual), "bytes": total, "blobs": len(expected)}


def manifest(folder):
    storage = inspect_files(folder, write=True)
    result = {"format": 2, "created_at": datetime.now(timezone.utc).isoformat(),
              "app_version": os.environ.get("BACKUP_APP_VERSION", "unknown"),
              "postgres_version": os.environ.get("BACKUP_POSTGRES_VERSION", "unknown"),
              "primary_database": os.environ.get("PRIMARY_DATABASE_NAME", "app_repartos_production"),
              "queue_database": os.environ.get("QUEUE_DATABASE_NAME", "app_repartos_production_queue"),
              "consistency": "primary-and-blob-catalog-shared-snapshot; queue-independent; files-verified-non-atomic",
              "primary_counts": json_file(folder / "primary-counts.json"), "storage": storage}
    if (folder / "legacy-source.json").exists():
        result["upgraded_at"] = result["created_at"]
        result["created_at"] = json_file(folder / "legacy-source.json")["created_at"]
        result["source_format"] = 1
    (folder / "manifest.json").write_text(json.dumps(result, sort_keys=True) + "\n")
    (folder / "SHA256SUMS").write_text("".join(f"{digest(folder / name)}  {name}\n" for name in sorted(FILES)))


def verify(folder):
    checksum_file = folder / "SHA256SUMS"
    if checksum_file.is_symlink() or not checksum_file.is_file() or checksum_file.stat().st_size > 4096:
        fail("Invalid checksum file")
    seen = set()
    for line in checksum_file.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([a-zA-Z0-9_.-]+)", line)
        if not match or match[2] not in FILES or match[2] in seen:
            fail("Invalid checksum entry")
        seen.add(match[2])
        path = folder / match[2]
        if path.is_symlink() or not path.is_file() or digest(path) != match[1]:
            fail("Bundle checksum mismatch")
    if seen != FILES or json_file(folder / "manifest.json").get("format") != 2:
        fail("Unsupported or incomplete backup")
    result = inspect_files(folder)
    if result != json_file(folder / "manifest.json")["storage"]:
        fail("Inconsistent storage manifest")
    return result


def extract_bundle(source, destination):
    seen, size = set(), 0
    with tarfile.open(source, "r|") as archive:
        for member in archive:
            name = safe_name(member.name)
            if name not in FILES | {"SHA256SUMS"} or name in seen or not member.isfile():
                fail("Unexpected or unsafe bundle member")
            seen.add(name)
            size += member.size
            if size > MAX_EXPANDED:
                fail("Bundle exceeds restore limit")
            with (destination / name).open("xb") as target:
                shutil.copyfileobj(archive.extractfile(member), target, 1024 ** 2)
    if seen != FILES | {"SHA256SUMS"}:
        fail("Incomplete encrypted bundle")


def extract_files(folder, destination):
    # Validate every file/checksum before touching the destination.
    verify(folder)
    if destination.is_symlink() or any(destination.iterdir()):
        fail("Storage extraction requires an empty private directory")
    with tarfile.open(folder / "files.tar.gz", "r|gz") as archive:
        for member in archive:
            name = safe_name(member.name)
            target = destination / name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with target.open("xb") as stream:
                    shutil.copyfileobj(archive.extractfile(member), stream, 1024 ** 2)
                target.chmod(0o600)


def media_keys(source, output):
    rows = catalog(source)
    disk_services = os.environ.get("BACKUP_DISK_SERVICE_NAMES", "persistent,local").split(",")
    if any(row["service_name"] not in disk_services + ["r2"] for row in rows.values()):
        fail("Unsupported storage service; configure its backup source explicitly")
    output.write_text("".join(key + "\n" for key, row in rows.items() if row["service_name"] == "r2"))


def arrange_media(source, remote_files, destination, local_storage=None):
    for key, row in catalog(source).items():
        if row["service_name"] != "r2":
            continue
        origin, target = remote_files / key, destination / blob_path(key)
        if origin.is_symlink() or not origin.is_file() or target.exists():
            fail("Missing or unsafe media mirror")
        local = local_storage / blob_path(key) if local_storage else None
        if local and local.exists():
            if local.is_symlink() or not local.is_file() or digest(local) != digest(origin):
                fail("Local and remote copies of an attachment disagree")
            # An earlier recovery may already have materialized the same R2
            # object on Disk. Archive it once, verified against the catalog.
            origin.unlink()
            continue
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.move(origin, target)


def compare_restored(folder, restored_catalog, restored_counts):
    if catalog(folder / "blobs.csv") != catalog(restored_catalog):
        fail("Restored blob catalog does not match its dump snapshot")
    if json_file(folder / "primary-counts.json") != json_file(restored_counts):
        fail("Restored business counts do not match the primary snapshot")


def legacy_input(source, destination):
    """Read-only compatibility for the original local v1 backups."""
    expected = {"primary.dump", "queue.dump", "files.tar.gz", "manifest.txt"}
    if destination.is_symlink() or any(destination.iterdir()):
        fail("Legacy upgrade requires an empty private directory")
    checksum_file = source / "SHA256SUMS"
    if checksum_file.is_symlink() or checksum_file.stat().st_size > 4096:
        fail("Invalid legacy checksum file")
    seen = set()
    for line in checksum_file.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([a-zA-Z0-9_.-]+)", line)
        if not match or match[2] not in expected or match[2] in seen:
            fail("Invalid legacy checksum entry")
        path = source / match[2]
        if path.is_symlink() or not path.is_file() or digest(path) != match[1]:
            fail("Legacy checksum mismatch")
        seen.add(match[2])
    if seen != expected:
        fail("Incomplete legacy backup")
    original_time = None
    if (source / "manifest.txt").stat().st_size <= 4096:
        text = (source / "manifest.txt").read_text()
        match = re.search(r"^UTC: (.+)$", text, re.MULTILINE)
        if match:
            try:
                parsed = datetime.fromisoformat(match[1].replace("Z", "+00:00"))
                if parsed.tzinfo:
                    original_time = parsed.astimezone(timezone.utc).isoformat()
            except ValueError:
                pass
    (destination / "legacy-source.json").write_text(json.dumps({"created_at": original_time}) + "\n")
    for name in ("primary.dump", "queue.dump"):
        shutil.copyfile(source / name, destination / name)
    # The original archive included the storage root itself and sometimes map
    # caches. Preserve Active Storage only; catalog validation after the
    # disposable restore must account for every referenced attachment.
    total, count = 0, 0
    names = set()
    with tarfile.open(source / "files.tar.gz", "r|gz") as original, tarfile.open(destination / "files.tar.gz", "w:gz") as target:
        for member in original:
            name = safe_name(member.name)
            total += member.size
            count += 1
            if total > MAX_EXPANDED or count > MAX_FILES * 4 or not (member.isfile() or member.isdir()):
                fail("Unsafe or oversized legacy archive")
            if not (name == "files" or name.startswith("files/")):
                continue
            if member.isfile() and name in names:
                fail("Duplicate legacy file")
            names.add(name)
            member.name = name
            target.addfile(member, original.extractfile(member) if member.isfile() else None)


def main(args):
    command, *paths = args
    paths = [Path(path) for path in paths]
    if command == "manifest":
        manifest(*paths)
    elif command == "verify":
        print(json.dumps(verify(*paths)))
    elif command == "extract-bundle":
        extract_bundle(*paths)
    elif command == "extract-files":
        extract_files(*paths)
    elif command == "media-keys":
        media_keys(*paths)
    elif command == "arrange-media":
        arrange_media(*paths)
    elif command == "compare-restored":
        compare_restored(*paths)
    elif command == "legacy-input":
        legacy_input(*paths)
    else:
        fail("Unknown backup validation command")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, OSError, csv.Error, tarfile.TarError) as error:
        # Avoid leaking commercial values, paths or metadata in monitoring logs.
        print(f"Backup validation failed ({type(error).__name__}): {str(error) if isinstance(error, ValueError) else 'invalid or inaccessible backup data'}", file=sys.stderr)
        sys.exit(1)
