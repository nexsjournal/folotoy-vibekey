#!/usr/bin/env python3
"""核对实际写入镜像、擦除扇区和身份分区;不连接设备、不修改文件。"""
import argparse
import hashlib
from pathlib import Path
import shlex
import struct
import sys

SECTOR = 0x1000
CARDID = 0x356000
CARDID_SIZE = 0x4000
EXPECTED = {
    0x0: ("bootloader/bootloader.bin", 0x8000),
    0x8000: ("partition_table/partition-table.bin", 0x10000),
    0x10000: ("VibeKey-Passport.bin", CARDID),
}
OPTIONS = ["--flash_mode", "dio", "--flash_freq", "80m", "--flash_size", "8MB"]


def parse_table(table: bytes) -> dict:
    # ESP-IDF 分区表以 32 字节记录编码,必须带有效 MD5。
    entries = {}
    end = None
    for pos in range(0, len(table) - 31, 32):
        magic, kind, subtype, offset, size, label, flags = struct.unpack_from("<HBBII16sI", table, pos)
        if magic != 0x50AA:
            end = pos
            break
        key = label.split(b"\0", 1)[0].decode("ascii")
        if key in entries:
            raise ValueError("分区名重复")
        entries[key] = (kind, subtype, offset, size, flags)
    if end is None or table[end:end + 16] != b"\xeb\xeb" + b"\xff" * 14 or \
            table[end + 16:end + 32] != hashlib.md5(table[:end]).digest():
        raise ValueError("分区表 MD5 无效")
    return entries


def verify_backup(backup: Path) -> None:
    if backup.stat().st_size != 0x800000:
        raise ValueError("原设备备份不是 8 MB")
    with backup.open("rb") as f:
        f.seek(0x8000)
        entries = parse_table(f.read(0xC00))
    if entries.get("cardid", ())[:4] != (1, 2, CARDID, CARDID_SIZE):
        raise ValueError("原设备身份分区不匹配")
    for name, (_, _, offset, size, _) in entries.items():
        if name != "cardid" and offset < CARDID + CARDID_SIZE and offset + size > CARDID:
            raise ValueError("原设备分区与身份分区重叠")


def verify(build: Path) -> None:
    build = build.resolve(strict=True)
    args = shlex.split((build / "flash_args").read_text())
    if args[:len(OPTIONS)] != OPTIONS:
        raise ValueError("flash_args 参数与预期不一致")
    parts = args[len(OPTIONS):]
    if len(parts) != 2 * len(EXPECTED):
        raise ValueError("镜像数量不正确")
    found = {}
    for addr, name in zip(parts[::2], parts[1::2]):
        offset = int(addr, 0)
        if offset not in EXPECTED or offset in found or name != EXPECTED[offset][0]:
            raise ValueError("写入地址或镜像名称不匹配")
        file = (build / name).resolve(strict=True)
        if build not in file.parents or not file.is_file():
            raise ValueError("镜像路径不在构建目录内")
        size = file.stat().st_size
        erase_end = (offset + size + SECTOR - 1) // SECTOR * SECTOR
        if size <= 0 or offset % SECTOR or erase_end > EXPECTED[offset][1]:
            raise ValueError("镜像的扇区擦除范围越界")
        found[offset] = file
    if set(found) != set(EXPECTED):
        raise ValueError("缺少必要镜像")

    entries = parse_table(found[0x8000].read_bytes())
    expected_partitions = {
        "nvs": (1, 2, 0x9000, 0x6000, 0),
        "phy_init": (1, 1, 0xf000, 0x1000, 0),
        "factory": (0, 0, 0x10000, 0x300000, 0),
        "wallpaper": (1, 0x40, 0x310000, 0x30000, 0),
        "cardid": (1, 2, CARDID, CARDID_SIZE, 0),
    }
    if entries != expected_partitions:
        raise ValueError("分区表与受保护布局不匹配")
    factory = entries["factory"]
    if found[0x10000].stat().st_size > factory[3]:
        raise ValueError("应用镜像超出 factory 分区")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build", type=Path)
    parser.add_argument("--backup", type=Path)
    args = parser.parse_args()
    try:
        verify(args.build)
        if args.backup:
            verify_backup(args.backup)
    except (OSError, ValueError, UnicodeError, struct.error) as exc:
        print(f"烧录布局检查失败: {exc}", file=sys.stderr)
        return 1
    print("烧录布局检查通过:擦除范围不覆盖身份分区")
    return 0


if __name__ == "__main__":
    sys.exit(main())
