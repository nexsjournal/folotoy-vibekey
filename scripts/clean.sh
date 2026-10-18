#!/usr/bin/env bash
# 删除本仓库所有编译 / 测试 / 打包产物,恢复到"刚检出"的状态(本机凭据与配置文件不动)。
#
#   ./scripts/clean.sh                 删除全部产物(含需要联网重新下载的 esptool 与 ESP-IDF 托管组件)
#   ./scripts/clean.sh --keep-downloads 保留 app/DeviceAssets(esptool)与 firmware/managed_components,离线时用
#   ./scripts/clean.sh --dry-run        只列出会删除什么,不删
#
# 删除的内容(都在 .gitignore 里,不会碰到受版本管理的文件):
#   app/build/                         build.sh / test.sh / release.sh 的 DerivedData、InputBetter.app、DMG、dmgbuild 虚拟环境
#   app/InputBetter.xcodeproj/         XcodeGen 生成的工程(build.sh / test.sh 会重新生成)
#   app/DeviceAssets/                  bundle-device-assets.sh 下载的 esptool(--keep-downloads 保留)
#   app/Packages/AppUpdateKit/.build/  swift test 的产物
#   firmware/build/                    idf.py build 产物(含 release/ 固件清单与镜像)
#   firmware/managed_components/       ESP-IDF 组件管理器下载的依赖(--keep-downloads 保留;dependencies.lock 保留)
#   firmware/sdkconfig(.old)           由 sdkconfig.defaults 重新生成
#   firmware/tools/ui-preview/build|out 主机预览程序与截图
#   .DS_Store                          Finder 残留
# 不删除:app/Config/*.local.*、website/deploy/private/(本机凭据)、.claude/、源码与文档。
set -euo pipefail
cd "$(dirname "$0")/.."

keep_downloads=0
dry_run=0
for arg in "$@"; do
    case "${arg}" in
        --keep-downloads) keep_downloads=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数:${arg}" >&2; exit 2 ;;
    esac
done

targets=(
    app/build
    app/InputBetter.xcodeproj
    app/Packages/AppUpdateKit/.build
    firmware/build
    firmware/sdkconfig
    firmware/sdkconfig.old
    firmware/tools/ui-preview/build
    firmware/tools/ui-preview/out
)
if [[ ${keep_downloads} -eq 0 ]]; then
    targets+=(app/DeviceAssets firmware/managed_components)
fi

# 只删除存在的目标;每一项都必须是 git 忽略的路径,防止误删受版本管理的文件。
removed=0
for t in "${targets[@]}"; do
    [[ -e "${t}" ]] || continue
    if ! git check-ignore -q "${t}"; then
        echo "跳过 ${t}:不在 .gitignore 里,不敢删" >&2
        continue
    fi
    size="$(du -sh "${t}" 2>/dev/null | cut -f1)"
    if [[ ${dry_run} -eq 1 ]]; then
        echo "将删除 ${t} (${size})"
    else
        rm -rf "${t}"
        echo "已删除 ${t} (${size})"
    fi
    removed=$((removed + 1))
done

# Finder 残留(排除 .git 内部)。
while IFS= read -r -d '' f; do
    if [[ ${dry_run} -eq 1 ]]; then echo "将删除 ${f}"; else rm -f "${f}"; fi
done < <(find . -name .DS_Store -not -path './.git/*' -print0)

if [[ ${removed} -eq 0 ]]; then echo "没有需要清理的产物。"; fi
if [[ ${dry_run} -eq 0 ]]; then
    echo "清理完成。重新编译:cd app && ./scripts/build.sh;cd firmware && ./tools/validate.sh"
fi
