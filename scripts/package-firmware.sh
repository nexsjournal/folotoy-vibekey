#!/usr/bin/env bash
# 把 firmware/build 的编译产物整理成官网发布用的固件目录(app 和官网网页刷写都从这里下载):
#   firmware/build/release/
#     manifest.json                     固件清单(版本、构建标识、协议版本、各镜像地址 / 大小 / SHA-256)
#     <version>-<build>/bootloader.bin  镜像放在带版本的目录里,可长缓存;manifest.json 不缓存
#     <version>-<build>/partition-table.bin
#     <version>-<build>/app.bin
#
# 安全约束(见 CLAUDE.md):每个镜像的写入范围都必须在受保护的 cardid 分区(0x356000)之前,否则停止。
# 清单里不放任何 esptool 参数:app 和网页都只按清单里的地址分段写入,flash 模式 / 频率 / 大小保持
# bootloader 镜像头里的值(keep),从不擦除整片 Flash。
#
# 用法:先编译固件(cd firmware && idf.py build),再运行 scripts/package-firmware.sh。
# website/deploy/deploy.sh 会自动调用本脚本。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${root}/firmware/build"
out="${build}/release"
CARDID_START=$((0x356000))

die() { echo "错误:$*" >&2; exit 1; }

[[ -f "${build}/flash_args" ]] || die "firmware/build 不存在,请先编译固件:cd firmware && idf.py build"

# 版本号取固件编译时的 PROJECT_VER(与设备 hello 里上报的 ver 一致)。
version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['project_version'])" "${build}/project_description.json")"
[[ "${version}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "固件版本号 ${version} 含有不能用作目录名的字符"
# 构建标识:esptool 在 app 镜像 0xB0 处写入了 ELF 的 SHA256,取前 4 字节(8 位十六进制),与设备 hello 的 build 一致。
app_bin="${build}/InputBetter-Passport.bin"
build_id="$(xxd -s 0xb0 -l 4 -p "${app_bin}")"
# 协议版本取固件源码里的定义,app 只刷与自己协议版本一致的固件。
proto="$(sed -nE 's/^#define IB_PROTO_VERSION[[:space:]]+([0-9]+).*/\1/p' "${root}/firmware/main/ib_protocol.h")"
[[ -n "${proto}" ]] || die "没能从 ib_protocol.h 读到 IB_PROTO_VERSION"

dir="${version}-${build_id}"
rm -rf "${out}"
mkdir -p "${out}/${dir}"

# 地址与源文件对应 build/flash_args(bootloader 0x0、分区表 0x8000、应用 0x10000)。
images=(
    "0x0 bootloader/bootloader.bin bootloader.bin"
    "0x8000 partition_table/partition-table.bin partition-table.bin"
    "0x10000 InputBetter-Passport.bin app.bin"
)
entries=()
for item in "${images[@]}"; do
    read -r offset src name <<<"${item}"
    grep -qE "^${offset} ${src}$" "${build}/flash_args" || die "${src} 不在 build/flash_args 的 ${offset},分区布局变了,请先核对"
    size="$(stat -f%z "${build}/${src}")"
    (( offset + size <= CARDID_START )) || die "${src} 写入范围 ${offset}+${size} 会覆盖 cardid(0x356000),已停止"
    cp "${build}/${src}" "${out}/${dir}/${name}"
    sha="$(shasum -a 256 "${out}/${dir}/${name}" | awk '{print $1}')"
    entries+=("    {\"offset\": \"${offset}\", \"path\": \"${dir}/${name}\", \"size\": ${size}, \"sha256\": \"${sha}\"}")
done

{
    echo "{"
    echo "  \"name\": \"InputBetter Passport\","
    echo "  \"version\": \"${version}\","
    echo "  \"build\": \"${build_id}\","
    echo "  \"proto\": ${proto},"
    echo "  \"chip\": \"ESP32-C3\","
    echo "  \"flashSize\": \"8MB\","
    echo "  \"images\": ["
    for i in "${!entries[@]}"; do
        if (( i < ${#entries[@]} - 1 )); then echo "${entries[$i]},"; else echo "${entries[$i]}"; fi
    done
    echo "  ]"
    echo "}"
} > "${out}/manifest.json"
python3 -m json.tool "${out}/manifest.json" >/dev/null || die "生成的 manifest.json 不是合法 JSON"

echo "Firmware ${version} (${build_id}, proto ${proto}) packaged in firmware/build/release"
