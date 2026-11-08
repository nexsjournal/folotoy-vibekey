"""刷写前布局检查的边界和拒绝路径;不连接设备。"""
import importlib.util
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "verify-flash-layout.py"
spec = importlib.util.spec_from_file_location("verify_flash_layout", SCRIPT)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


def entry(name, kind, subtype, offset, size):
    return struct.pack("<HBBII16sI", 0x50AA, kind, subtype, offset, size, name.encode(), 0)


def with_md5(entries):
    return entries + b"\xeb\xeb" + b"\xff" * 14 + hashlib.md5(entries).digest()


class FlashLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name)
        (self.build / "bootloader").mkdir()
        (self.build / "partition_table").mkdir()
        (self.build / "bootloader/bootloader.bin").write_bytes(b"x" * 0x4000)
        (self.build / "VibeKey-Passport.bin").write_bytes(b"x" * 0x1000)
        self.table = self.build / "partition_table/partition-table.bin"
        self.table.write_bytes(with_md5(b"".join([
            entry("nvs", 1, 2, 0x9000, 0x6000),
            entry("phy_init", 1, 1, 0xf000, 0x1000),
            entry("factory", 0, 0, 0x10000, 0x300000),
            entry("wallpaper", 1, 0x40, 0x310000, 0x30000),
            entry("cardid", 1, 2, 0x356000, 0x4000),
        ])))
        self.args = self.build / "flash_args"
        self.valid_args = "--flash_mode dio --flash_freq 80m --flash_size 8MB\n0x0 bootloader/bootloader.bin\n0x10000 VibeKey-Passport.bin\n0x8000 partition_table/partition-table.bin\n"
        self.args.write_text(self.valid_args)

    def test_expected_layout_is_accepted(self):
        layout.verify(self.build)

    def test_unexpected_argument_or_address_is_rejected(self):
        for contents in (self.valid_args + "--erase-all\n", self.valid_args.replace("0x10000", "0x356000")):
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                self.args.write_text(contents)
                layout.verify(self.build)

    def test_overlapping_erased_sector_is_rejected(self):
        with (self.build / "bootloader/bootloader.bin").open("wb") as f:
            f.truncate(0x8001)
        with self.assertRaises(ValueError):
            layout.verify(self.build)

    def test_changed_identity_or_extra_partition_is_rejected(self):
        original = self.table.read_bytes()
        entries = original[:-32]
        for table in (with_md5(entries.replace(struct.pack("<I", 0x356000), struct.pack("<I", 0x357000))),
                      with_md5(entries + entry("extra", 1, 2, 0x35a000, 0x1000)),
                      original[:-1] + bytes([original[-1] ^ 1])):
            with self.subTest(table=table[-32:]), self.assertRaises(ValueError):
                self.table.write_bytes(table)
                layout.verify(self.build)

    def test_symlink_to_external_image_is_rejected(self):
        app = self.build / "VibeKey-Passport.bin"
        app.unlink()
        app.symlink_to(SCRIPT)
        with self.assertRaises(ValueError):
            layout.verify(self.build)

    def test_original_backup_requires_matching_nonoverlapping_cardid(self):
        backup = self.build / "original.bin"
        table = self.table.read_bytes()
        with backup.open("wb") as f:
            f.truncate(0x800000)
            f.seek(0x8000)
            f.write(table)
        layout.verify_backup(backup)
        entries = table[:-32] + entry("overlap", 1, 2, 0x355000, 0x2000)
        with backup.open("r+b") as f:
            f.seek(0x8000)
            f.write(with_md5(entries))
        with self.assertRaises(ValueError):
            layout.verify_backup(backup)


if __name__ == "__main__":
    unittest.main()
