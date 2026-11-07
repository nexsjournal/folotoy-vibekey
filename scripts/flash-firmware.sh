#!/usr/bin/env bash
# 编译并烧录 VibeKey 固件到通过 USB 连接的 FoloToy AI Passport。
#
# 安全约束(见 CLAUDE.md):
#   - 第一次给某台设备烧录前,把整片 8 MB Flash 备份到 ~/esp/passport-backups/passport-<MAC>-flash.bin,
#     可用于恢复原固件。备份含设备身份数据(cardid 分区),不要上传或分享。
#   - 只分段写 bootloader(0x0)、分区表(0x8000)、应用(0x10000),不擦除整片 Flash,
#     绝不写受保护的 cardid 分区(0x356000)。写之前逐项检查 build/flash_args 里的地址。
#
# 可选环境变量:
#   PORT=/dev/cu.usbmodemXXXX   指定串口(默认取第一个 /dev/cu.usbmodem*)
#   IDF_EXPORT=...              ESP-IDF v5.5.3 的 export.sh(默认 ~/esp/esp-idf-v5.5.3/export.sh)
#   BACKUP_DIR=...              备份目录(默认 ~/esp/passport-backups)
#   SKIP_BUILD=1                跳过编译,直接烧录现有 build/
set -euo pipefail
umask 077

root="$(cd "$(dirname "$0")/.." && pwd)"
fw="${root}/firmware"
idf_export="${IDF_EXPORT:-${HOME}/esp/esp-idf-v5.5.3/export.sh}"
backup_dir="${BACKUP_DIR:-${HOME}/esp/passport-backups}"

die() { echo "错误:$*" >&2; exit 1; }

# ---- 串口 ----
port="${PORT:-}"
if [[ -z "${port}" ]]; then
    port="$(ls /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
fi
[[ -n "${port}" ]] || die "没有找到 USB 串口。请打开 Passport 电源,并用支持数据传输的 USB-C 线连接 Mac。"
[[ -e "${port}" ]] || die "串口 ${port} 不存在。"

# VibeKey / Passport Keys app 会以 TIOCEXCL 独占串口;其它程序(串口监视器等)也要先关掉。
for app in VibeKey PassportKeys; do
    if pgrep -xq "${app}"; then
        die "${app} app 正在运行并可能独占串口,请先退出它再烧录。"
    fi
done
if command -v lsof >/dev/null 2>&1; then
    users="$(lsof -t "${port}" 2>/dev/null || true)"
    if [[ -n "${users}" ]]; then
        echo "以下进程正在使用 ${port}:" >&2
        lsof "${port}" >&2 || true
        die "请先关闭占用串口的程序。"
    fi
fi

# ---- ESP-IDF ----
[[ -f "${idf_export}" ]] || die "找不到 ${idf_export},请先安装 ESP-IDF v5.5.3。"
if [[ -z "${IDF_PYTHON_ENV_PATH:-}" ]]; then
    # export.sh 按 PATH 里的 python3 找虚拟环境;本机有多个 python 时直接指向已安装的环境。
    env_dir="$(ls -d "${HOME}"/.espressif/python_env/idf5.5_py*_env 2>/dev/null | head -n 1 || true)"
    [[ -n "${env_dir}" ]] && export IDF_PYTHON_ENV_PATH="${env_dir}"
fi
# shellcheck disable=SC1090
source "${idf_export}" >/dev/null
idf.py --version | grep -q "v5.5.3" || die "需要 ESP-IDF v5.5.3,当前为 $(idf.py --version)。"

# ---- 编译 ----
cd "${fw}"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    idf.py build
fi
[[ -f build/flash_args ]] || die "build/flash_args 不存在,请先编译。"

# ---- 校验写入列表、擦除扇区和分区表 ----
python3 "${root}/scripts/verify-flash-layout.py" build || die "镜像布局不安全,已停止烧录。"
image_hashes="$(shasum -a 256 build/flash_args build/bootloader/bootloader.bin build/partition_table/partition-table.bin build/VibeKey-Passport.bin)"

# ---- 首次烧录前整片备份 ----
# 写入前始终停留在下载模式,避免原固件在身份检查之间启动并修改 NVS。
mac="$(python -m esptool --chip esp32c3 -p "${port}" --after no_reset read_mac | awk '/^MAC:/ { print $2; exit }' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "${mac}" =~ ^[0-9a-fA-F]{12}$ ]] || die "读取设备标识失败,已停止烧录。"
backup="${backup_dir}/passport-${mac}-flash.bin"
mkdir -p "${backup_dir}"
flash_info="$(python -m esptool --chip esp32c3 -p "${port}" --after no_reset flash_id)"
[[ "${flash_info}" == *"Detected flash size: 8MB"* ]] || die "未能确认设备是 8 MB Flash,已停止烧录。"
if [[ -f "${backup}" ]]; then
    [[ -f "${backup}.sha256" ]] || die "已有备份缺少校验文件,请先核实原始备份。"
else
    [[ ! -e "${backup}.partial" ]] || die "发现未完成的备份,请先核实。"
    echo "首次烧录这台设备,先备份整片 8 MB Flash…"
    python -m esptool --chip esp32c3 -p "${port}" -b 460800 --after no_reset read_flash 0 0x800000 "${backup}.partial"
    actual="$(stat -f%z "${backup}.partial")"
    (( actual == 0x800000 )) || die "备份大小 ${actual} 不是 8 MB,已停止烧录。"
    mv "${backup}.partial" "${backup}"
    shasum -a 256 "${backup}" > "${backup}.sha256"
fi
actual="$(stat -f%z "${backup}")"
(( actual == 0x800000 )) || die "备份大小不是 8 MB,已停止烧录。"
expected_sha="$(awk 'NR == 1 { print $1 }' "${backup}.sha256")"
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || die "备份校验文件无效,已停止烧录。"
actual_sha="$(shasum -a 256 "${backup}" | awk '{ print $1 }')"
[[ "${actual_sha}" == "${expected_sha}" ]] || die "备份校验失败,已停止烧录。"
python3 "${root}/scripts/verify-flash-layout.py" build --backup "${backup}" || die "原设备分区不匹配,已停止烧录。"
echo "整片备份已校验。"

# ---- 烧录(分段写入,不擦除整片)----
# 备份和写入之间若设备被换掉,不能将一个设备的备份当作另一个设备的恢复依据。
current_mac="$(python -m esptool --chip esp32c3 -p "${port}" --after no_reset read_mac | awk '/^MAC:/ { print $2; exit }' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "${current_mac}" == "${mac}" ]] || die "设备身份发生变化,已停止烧录。"
python3 "${root}/scripts/verify-flash-layout.py" build --backup "${backup}" || die "写入前布局检查失败。"
current_hashes="$(shasum -a 256 build/flash_args build/bootloader/bootloader.bin build/partition_table/partition-table.bin build/VibeKey-Passport.bin)"
[[ "${current_hashes}" == "${image_hashes}" ]] || die "检查期间固件镜像发生变化,已停止烧录。"
cd build
python -m esptool --chip esp32c3 -p "${port}" -b 460800 \
    --before default_reset --after hard_reset write_flash "@flash_args"
echo "烧录完成,设备已重启进入 VibeKey 固件。"
