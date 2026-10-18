#!/usr/bin/env bash
# 准备 dmgbuild(固定版本,装在 app/build/tools 下的独立 Python 虚拟环境里,不污染系统),输出可执行文件路径。
# 第一次需要联网从 PyPI 下载;之后直接复用。
set -euo pipefail
cd "$(dirname "$0")/../.."
version="1.6.5"
venv="build/tools/dmgbuild-venv"
bin="${venv}/bin/dmgbuild"
if [[ ! -x "${bin}" ]] || ! "${venv}/bin/pip" show dmgbuild 2>/dev/null | grep -q "^Version: ${version}$"; then
    rm -rf "${venv}"
    python3 -m venv "${venv}" >&2
    "${venv}/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==${version}" >&2
fi
echo "$(pwd)/${bin}"
