import base64
import csv
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bundle", Path(__file__).resolve().parents[2] / "lib/backup/bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundleTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.key = "abcd1234"
        self.data = b"private attachment fixture"
        with (self.folder / "blobs.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["id", "key", "checksum", "byte_size", "service_name"])
            writer.writerow([1, self.key, base64.b64encode(hashlib.md5(self.data).digest()).decode(), len(self.data), "persistent"])
        for name in ("primary.dump", "queue.dump"):
            (self.folder / name).write_bytes(b"dump fixture")
        (self.folder / "primary-counts.json").write_text('{"companies":1}')
        self.storage()
        bundle.manifest(self.folder)

    def storage(self, name=None, data=None, link=None):
        with tarfile.open(self.folder / "files.tar.gz", "w:gz") as archive:
            info = tarfile.TarInfo(name or bundle.blob_path(self.key))
            contents = self.data if data is None else data
            if link:
                info.type = tarfile.SYMTYPE
                info.linkname = link
                archive.addfile(info)
            else:
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))

    def test_valid_round_trip_verifies_contents_and_extracts_only_files(self):
        self.assertEqual(1, bundle.verify(self.folder)["blobs"])
        target = self.folder / "restored"
        target.mkdir()
        bundle.extract_files(self.folder, target)
        self.assertEqual(self.data, (target / bundle.blob_path(self.key)).read_bytes())
        self.assertEqual(0o600, (target / bundle.blob_path(self.key)).stat().st_mode & 0o777)

    def test_missing_or_changed_attachment_prevents_backup_creation(self):
        self.storage(data=b"damaged")
        with self.assertRaisesRegex(ValueError, "attachment"):
            bundle.manifest(self.folder)
        self.storage(name="files/another-key")
        with self.assertRaisesRegex(ValueError, "missing"):
            bundle.manifest(self.folder)

    def test_same_size_corruption_is_detected_from_the_primary_snapshot_checksum(self):
        self.storage(data=b"x" * len(self.data))
        with self.assertRaisesRegex(ValueError, "checksum"):
            bundle.manifest(self.folder)

    def test_unsafe_paths_and_links_never_extract(self):
        for name, link in [("../outside", None), ("/etc/private", None), (bundle.blob_path(self.key), "/etc/private")]:
            with self.subTest(name=name, link=link):
                self.storage(name=name, link=link)
                with self.assertRaises(ValueError):
                    bundle.inspect_files(self.folder, write=True)

    def test_checksum_file_cannot_read_other_paths_or_hide_corruption(self):
        (self.folder / "SHA256SUMS").write_text("0" * 64 + "  ../private\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            bundle.verify(self.folder)
        bundle.manifest(self.folder)
        (self.folder / "primary.dump").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "checksum"):
            bundle.verify(self.folder)

    def test_unknown_or_duplicate_outer_tar_members_are_rejected(self):
        for name in ["../outside", "secret.env", "primary.dump"]:
            with self.subTest(name=name):
                archive_path = self.folder / "outer.tar"
                with tarfile.open(archive_path, "w") as archive:
                    for _ in range(2):
                        info = tarfile.TarInfo(name)
                        info.size = 1
                        archive.addfile(info, io.BytesIO(b"a"))
                target = self.folder / "target"
                target.mkdir(exist_ok=True)
                with self.assertRaises(ValueError):
                    bundle.extract_bundle(archive_path, target)
                for child in target.iterdir():
                    child.unlink()

    def test_catalog_keys_and_unconfigured_storage_services_are_rejected(self):
        text = (self.folder / "blobs.csv").read_text()
        (self.folder / "blobs.csv").write_text(text.replace(self.key, "../../private"))
        with self.assertRaises(ValueError):
            bundle.catalog(self.folder / "blobs.csv")
        (self.folder / "blobs.csv").write_text(text.replace("persistent", "unknown-cloud"))
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            bundle.media_keys(self.folder / "blobs.csv", self.folder / "keys")

    def test_restored_catalog_and_counts_must_match_the_dump_snapshot(self):
        counts = self.folder / "restored-counts.json"
        counts.write_text('{"companies":2}')
        with self.assertRaisesRegex(ValueError, "counts"):
            bundle.compare_restored(self.folder, self.folder / "blobs.csv", counts)

    def test_bounded_expansion_prevents_large_archive_contents(self):
        previous = bundle.MAX_EXPANDED
        bundle.MAX_EXPANDED = 1
        try:
            with self.assertRaises(ValueError):
                bundle.inspect_files(self.folder)
        finally:
            bundle.MAX_EXPANDED = previous

    def test_legacy_conversion_keeps_the_original_recovery_date(self):
        (self.folder / "manifest.txt").write_text("App Repartos backup v1\nUTC: 2020-01-01T03:00:00Z\n")
        names = ["primary.dump", "queue.dump", "files.tar.gz", "manifest.txt"]
        (self.folder / "SHA256SUMS").write_text("".join(f"{bundle.digest(self.folder / name)}  {name}\n" for name in names))
        converted = self.folder / "converted"
        converted.mkdir(mode=0o700)
        bundle.legacy_input(self.folder, converted)
        for name in ("blobs.csv", "primary-counts.json"):
            (converted / name).write_bytes((self.folder / name).read_bytes())
        bundle.manifest(converted)
        metadata = json.loads((converted / "manifest.json").read_text())
        self.assertEqual("2020-01-01T03:00:00+00:00", metadata["created_at"])
        self.assertIn("upgraded_at", metadata)


if __name__ == "__main__":
    unittest.main()
