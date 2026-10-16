#!/usr/bin/env bash
# 把 Passport 烧录工具 esptool 打包进 app/DeviceAssets/Tools(整个目录拷进 app 的 Resources/DeviceAssets)。
# 固件本身不再内置:app 刷写时从官网下载最新固件(见 scripts/package-firmware.sh 与 docs/website.md)。
# esptool 取 Espressif 官方独立版(macOS arm64),只保留 esptool 本体和 LICENSE;已下载过则跳过。
set -euo pipefail
cd "$(dirname "$0")/.."
out="DeviceAssets"
esptool_version="v5.6.0"

# 旧版本把固件也放在这里,清掉,避免被打包进 app。
rm -rf "${out}/Firmware"
mkdir -p "${out}/Tools"

if [[ ! -x "${out}/Tools/esptool" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    curl -fsSL -o "${tmp}/esptool.tar.gz" \
        "https://github.com/espressif/esptool/releases/download/${esptool_version}/esptool-${esptool_version}-macos-arm64.tar.gz"
    tar -xzf "${tmp}/esptool.tar.gz" -C "${tmp}"
    cp "${tmp}/esptool-macos-arm64/esptool" "${out}/Tools/esptool"
    cp "${tmp}/esptool-macos-arm64/LICENSE" "${out}/Tools/LICENSE-esptool"
    chmod +x "${out}/Tools/esptool"
fi
echo "Device assets (esptool ${esptool_version}) ready in app/${out}"
