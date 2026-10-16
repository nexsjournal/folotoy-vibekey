#!/usr/bin/env bash
# 把 Passport 固件和烧录工具打包进 app/DeviceAssets,app 的引导页据此一键刷固件。
#   - 固件:取 firmware/build 的编译产物(没有时先运行 firmware 编译);
#   - esptool:下载 Espressif 官方独立版(macOS arm64),只保留 esptool 本体和 LICENSE。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(cd .. && pwd)"
out="DeviceAssets"
fw_build="${root}/firmware/build"
esptool_version="v5.6.0"

mkdir -p "${out}/Firmware" "${out}/Tools"

# ---- 固件 ----
if [[ ! -f "${fw_build}/flash_args" ]]; then
    echo "firmware/build 不存在,请先编译固件:cd firmware && idf.py build" >&2
    exit 1
fi
cp "${fw_build}/bootloader/bootloader.bin" "${out}/Firmware/bootloader.bin"
cp "${fw_build}/partition_table/partition-table.bin" "${out}/Firmware/partition-table.bin"
cp "${fw_build}/InputBetter-Passport.bin" "${out}/Firmware/app.bin"
# 版本号取固件编译时的 PROJECT_VER(与设备 hello 里上报的 ver 一致)。
version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['project_version'])" "${fw_build}/project_description.json" 2>/dev/null || echo dev)"
# 构建标识:esptool 在 app 镜像 0xB0 处写入了 ELF 的 SHA256,取前 4 字节(8 位十六进制),与设备 hello 的 build 一致。
build="$(xxd -s 0xb0 -l 4 -p "${out}/Firmware/app.bin")"
cat > "${out}/Firmware/manifest.json" <<JSON
{
  "version": "${version}",
  "build": "${build}",
  "flashArgs": ["--flash-mode", "dio", "--flash-freq", "80m", "--flash-size", "8MB"],
  "images": [
    {"offset": "0x0", "file": "bootloader.bin"},
    {"offset": "0x8000", "file": "partition-table.bin"},
    {"offset": "0x10000", "file": "app.bin"}
  ]
}
JSON

# ---- esptool ----
if [[ ! -x "${out}/Tools/esptool" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/esptool.tar.gz" \
        "https://github.com/espressif/esptool/releases/download/${esptool_version}/esptool-${esptool_version}-macos-arm64.tar.gz"
    tar -xzf "${tmp}/esptool.tar.gz" -C "${tmp}"
    cp "${tmp}/esptool-macos-arm64/esptool" "${out}/Tools/esptool"
    cp "${tmp}/esptool-macos-arm64/LICENSE" "${out}/Tools/LICENSE-esptool"
    chmod +x "${out}/Tools/esptool"
    rm -rf "${tmp}"
fi
echo "Device assets ready in app/${out}"
