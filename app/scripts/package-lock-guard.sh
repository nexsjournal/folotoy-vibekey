#!/usr/bin/env bash
# 构建期间保护独立 Swift 包的 Package.resolved。
# Xcode 为本 app 解析 SwiftPM 依赖时,会向本地 AppUpdateKit 包的锁文件写入无关的传递依赖;
# 构建脚本 source 本文件后,无论成功或失败都在退出时恢复原锁定。依赖需要真实更新时,
# 应显式运行 `swift package resolve` 并单独审阅锁文件,而不是让普通构建隐式修改。
set -euo pipefail

package_lock="Packages/AppUpdateKit/Package.resolved"
package_lock_backup="$(mktemp "${TMPDIR:-/tmp}/vibekey-package-lock.XXXXXX")"
cp -p "${package_lock}" "${package_lock_backup}"

restore_package_lock() {
    if [[ -f "${package_lock_backup}" ]]; then
        if ! cmp -s "${package_lock_backup}" "${package_lock}"; then
            cp -p "${package_lock_backup}" "${package_lock}"
        fi
        rm -f "${package_lock_backup}"
    fi
}
trap restore_package_lock EXIT
