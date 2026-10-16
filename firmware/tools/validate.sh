#!/usr/bin/env bash
# 固件校验:主机单元测试 + (可选)ESP-IDF 编译与分区检查。
#
# 用法:tools/validate.sh [--all|--host|--firmware]   默认 --all
#   --host      只编译运行 tests/ 下的主机测试(纯 C 模块:协议、ADPCM、时钟、按键过滤、链路)
#   --firmware  只做 idf.py build,并检查分区表里 cardid 仍在 0x356000/0x4000、应用镜像放得下
# 环境变量:IDF_EXPORT(默认 ~/esp/esp-idf-v5.5.3/export.sh)、CC(默认 cc)
set -euo pipefail

mode="${1:---all}"
fw="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${fw}"

run_host() {
    local out
    out="$(mktemp -d "${TMPDIR:-/tmp}/ib-host-tests.XXXXXX")"
    trap 'rm -rf "${out}"' RETURN
    local cflags=(-std=c11 -Wall -Wextra -Werror -Imain -Itests)
    "${CC:-cc}" "${cflags[@]}" tests/test_ib_protocol.c main/ib_protocol.c main/ib_icons.c -o "${out}/protocol"
    "${CC:-cc}" "${cflags[@]}" tests/test_ib_adpcm.c main/ib_adpcm.c -lm -o "${out}/adpcm"
    "${CC:-cc}" "${cflags[@]}" tests/test_ib_clock.c main/ib_clock.c -o "${out}/clock"
    "${CC:-cc}" "${cflags[@]}" tests/test_ib_keys.c main/ib_keys.c main/ib_links.c -o "${out}/keys"
    "${out}/protocol"
    "${out}/adpcm"
    "${out}/clock"
    "${out}/keys"
    echo "Host tests: PASS"
}

activate_idf() {
    if command -v idf.py >/dev/null 2>&1; then return 0; fi
    local export_sh="${IDF_EXPORT:-${HOME}/esp/esp-idf-v5.5.3/export.sh}"
    # export.sh 用 PATH 里的 python3 找虚拟环境;本机若有多个 python,直接指向已安装的环境。
    if [[ -z "${IDF_PYTHON_ENV_PATH:-}" ]]; then
        local env
        env="$(ls -d "${HOME}"/.espressif/python_env/idf5.5_py*_env 2>/dev/null | head -n 1 || true)"
        [[ -n "${env}" ]] && export IDF_PYTHON_ENV_PATH="${env}"
    fi
    # shellcheck disable=SC1090
    source "${export_sh}" >/dev/null
}

run_firmware() {
    activate_idf
    idf.py build
    # cardid 是出厂身份数据:分区表必须保持 0x356000 / 0x4000。
    if ! grep -Eq '^cardid,[[:space:]]*data,[[:space:]]*nvs,[[:space:]]*0x356000,[[:space:]]*0x4000' partitions.csv; then
        echo "ERROR: partitions.csv 中 cardid 分区被改动" >&2
        return 1
    fi
    if ! grep -Eq '^factory,[[:space:]]*app,[[:space:]]*factory,[[:space:]]*0x10000,[[:space:]]*0x300000' partitions.csv; then
        echo "ERROR: factory 分区必须为 0x10000 / 0x300000" >&2
        return 1
    fi
    local size
    size="$(stat -f%z build/InputBetter-Passport.bin 2>/dev/null || stat -c%s build/InputBetter-Passport.bin)"
    if (( size > 0x300000 )); then
        echo "ERROR: 应用镜像 ${size} 字节超过 factory 分区" >&2
        return 1
    fi
    echo "Firmware build: PASS (app ${size} bytes)"
}

case "${mode}" in
    --all) run_host; run_firmware ;;
    --host) run_host ;;
    --firmware) run_firmware ;;
    *) echo "Usage: $0 [--all|--host|--firmware]" >&2; exit 2 ;;
esac
