#!/usr/bin/env bash
# 编译并烧录 InputBetter 固件到通过 USB 连接的 FoloToy AI Passport。
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

root="$(cd "$(dirname "$0")/.." && pwd)"
fw="${root}/firmware"
idf_export="${IDF_EXPORT:-${HOME}/esp/esp-idf-v5.5.3/export.sh}"
backup_dir="${BACKUP_DIR:-${HOME}/esp/passport-backups}"
CARDID_START=$((0x356000))

die() { echo "错误:$*" >&2; exit 1; }

# ---- 串口 ----
port="${PORT:-}"
if [[ -z "${port}" ]]; then
    port="$(ls /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
fi
[[ -n "${port}" ]] || die "没有找到 USB 串口。请打开 Passport 电源,并用支持数据传输的 USB-C 线连接 Mac。"
[[ -e "${port}" ]] || die "串口 ${port} 不存在。"

# InputBetter / Passport Keys app 会以 TIOCEXCL 独占串口;其它程序(串口监视器等)也要先关掉。
for app in InputBetter PassportKeys; do
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

# ---- 检查烧录地址:只允许写 cardid 之前的区域 ----
while read -r addr file; do
    [[ "${addr}" =~ ^0x[0-9a-fA-F]+$ ]] || continue
    size="$(stat -f%z "build/${file}")"
    end=$((addr + size))
    if (( end > CARDID_START )); then
        die "${file} 写入范围 ${addr}+${size} 会覆盖 cardid(0x356000),已停止。"
    fi
done < build/flash_args

# ---- 首次烧录前整片备份 ----
mac="$(python -m esptool --chip esp32c3 -p "${port}" read_mac | awk '/^MAC:/ { print $2; exit }' | tr -d ':')"
[[ -n "${mac}" ]] || die "读取设备 MAC 失败,已停止烧录。"
backup="${backup_dir}/passport-${mac}-flash.bin"
if [[ -f "${backup}" ]]; then
    echo "已有整片备份 ${backup},跳过备份。"
else
    mkdir -p "${backup_dir}"
    echo "首次烧录这台设备,先备份整片 8 MB Flash…"
    python -m esptool --chip esp32c3 -p "${port}" -b 460800 read_flash 0 0x800000 "${backup}.partial"
    actual="$(stat -f%z "${backup}.partial")"
    (( actual == 0x800000 )) || die "备份大小 ${actual} 不是 8 MB,已停止烧录。"
    mv "${backup}.partial" "${backup}"
    echo "已备份整片 Flash:${backup}"
fi

# ---- 烧录(分段写入,不擦除整片)----
cd build
python -m esptool --chip esp32c3 -p "${port}" -b 460800 \
    --before default_reset --after hard_reset write_flash "@flash_args"
echo "烧录完成,设备已重启进入 InputBetter 固件。"
