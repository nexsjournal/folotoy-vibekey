#!/usr/bin/env bash
# 生成 Passport 界面用的图标字体(LVGL C 字体)与图标表,可重复执行、结果逐字节可复现。
#
# 来源:Google Material Icons(Round 风格),Apache License 2.0
#   仓库   https://github.com/google/material-design-icons
#   提交   49d4db35df873165d6bd6ba09b063c7dafbac2f4(2026-10-09)
#   文件   font/MaterialIconsRound-Regular.otf、font/MaterialIconsRound-Regular.codepoints、LICENSE
#   下载后按下面的 SHA-256 校验,不一致就停止(防止上游改动导致结果漂移)。
# 派生字形:Material 没有向右删除(⌦)图标,用 fontTools 4.60.1(临时 venv,pip 安装锁定版本)把 backspace(⌫)
#   水平镜像成新字形,放在字体没用到的私用区码点 U+F8FC,见下方 DERIVED 表。
# 转换:lv_font_conv 1.5.3(npm,通过 npx 运行;需要 Node.js),4 bpp,不压缩
#   (LVGL 9 默认 LV_USE_FONT_COMPRESSED=0,压缩字体无法显示)。
#
# 一张图标表生成两种字号:
#   22 px  右侧按键提示(keys 命令的协议 id)  → main/icons/ib_icon_font_22.c + main/icons/ib_icon_list.h
#   56 px  页面主图标(IDLE 模式图标等)       → main/icons/ib_icon_font_56.c + main/icons/ib_icon_large_list.h
# 另复制许可证全文到 main/icons/LICENSE-material-icons。
#
# 表格式:"枚举名:协议 id:Material 图标名:字号列表"
#   协议 id 为 "-" 表示不是按键提示图标(只用于页面主图标,不进入 keys 协议)。
#   Material 图标名也可以是 DERIVED 表里的派生字形名。
#   改表后重新运行本脚本;按键提示 id 变化时同步更新 docs/protocol.md。
set -euo pipefail

ICONS=(
    "ENTER:enter:keyboard_return:22"
    "ESC:esc:close:22"
    "UNDO:undo:undo:22"
    "STAB:stab:first_page:22"            # Round 风格没有 keyboard_tab_rtl,用 first_page(|←)表示 Shift-Tab
    "TAB:tab:keyboard_tab:22"
    "SEND:send:send:22"
    "STOP:stop:stop:22"
    "CANCEL:cancel:cancel:22"
    "CHECK:check:check:22"
    "REPEAT:repeat:replay:22"
    "MODE:mode:swap_vert:22"
    "APPS:apps:apps:22,56"
    "MIC:mic:mic:22,56"
    "TRANSLATE:translate:translate:22,56"
    "HIDE:hide:visibility_off:22"
    "UP:up:keyboard_arrow_up:22"
    "DOWN:down:keyboard_arrow_down:22"
    "PLAY:play:play_arrow:22"
    "OPEN:open:open_in_new:22"
    "BKSP:bksp:backspace:22"             # ⌫ 退格
    "DEL:del:backspace_mirrored:22"      # ⌦ 向右删除(派生字形)
    "CC:-:closed_caption:56"             # 字幕模式主图标
)

# 派生字形表:"派生名:码点:来源图标名:变换",变换目前只有 mirror(水平镜像)。
DERIVED=(
    "backspace_mirrored:f8fc:backspace:mirror"
)
FONTTOOLS="fonttools==4.60.1"

COMMIT="49d4db35df873165d6bd6ba09b063c7dafbac2f4"
BASE="https://raw.githubusercontent.com/google/material-design-icons/${COMMIT}"
SHA_OTF="bad85e5454b6288104ce03806c37323bcd8f145e3094e727860173ac8c91062e"
SHA_CODEPOINTS="534fc87caafe6c7529a390fbe5b669c158d560caa5e9358c8e49054b817603d8"
SHA_LICENSE="58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd"
LV_FONT_CONV="lv_font_conv@1.5.3"
BPP=4

fw="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${fw}/main/icons"
command -v npx >/dev/null 2>&1 || { echo "需要 Node.js(npx)来运行 ${LV_FONT_CONV}" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/ib-icon-font.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

fetch() {   # fetch <路径> <期望 sha256>
    local name; name="$(basename "$1")"
    curl -sfL "${BASE}/$1" -o "${work}/${name}"
    local got; got="$(shasum -a 256 "${work}/${name}" | awk '{print $1}')"
    if [[ "${got}" != "$2" ]]; then
        echo "${name} 校验失败:期望 $2,实际 ${got}" >&2
        exit 1
    fi
}
fetch font/MaterialIconsRound-Regular.otf "${SHA_OTF}"
fetch font/MaterialIconsRound-Regular.codepoints "${SHA_CODEPOINTS}"
fetch LICENSE "${SHA_LICENSE}"

# 派生字形:在临时 venv 里用锁定版本的 fontTools 生成 icons.otf(原字体 + 派生字形),之后都用它转换。
font="${work}/MaterialIconsRound-Regular.otf"
if (( ${#DERIVED[@]} > 0 )); then
    python3 -m venv "${work}/venv"
    "${work}/venv/bin/pip" install --quiet --disable-pip-version-check "${FONTTOOLS}"
    "${work}/venv/bin/python" - "${font}" "${work}/icons.otf" "${work}/MaterialIconsRound-Regular.codepoints" "${DERIVED[@]}" <<'PY'
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

src, dst, codepoints_path, *derived = sys.argv[1:]
names = dict(line.split() for line in open(codepoints_path) if line.strip())
font = TTFont(src)
cmap = font.getBestCmap()
glyph_set = font.getGlyphSet()
cff = font["CFF "].cff
top = cff.topDictIndex[0]
char_strings = top.CharStrings
order = font.getGlyphOrder()
for entry in derived:
    name, cp_hex, base, transform = entry.split(":")
    cp = int(cp_hex, 16)
    if cp in cmap:
        sys.exit(f"派生字形码点 U+{cp_hex} 已被字体使用")
    if transform != "mirror":
        sys.exit(f"不支持的变换 {transform}")
    base_glyph = cmap[int(names[base], 16)]
    width, _ = font["hmtx"][base_glyph]
    mirror = (-1, 0, 0, 1, width, 0)
    pen = T2CharStringPen(width, glyph_set)
    glyph_set[base_glyph].draw(TransformPen(pen, mirror))
    charstring = pen.getCharString(private=top.Private, globalSubrs=cff.GlobalSubrs)
    char_strings.charStrings[name] = len(char_strings.charStringsIndex)
    char_strings.charStringsIndex.append(charstring)
    top.charset.append(name)
    order.append(name)
    bounds = BoundsPen(glyph_set)
    glyph_set[base_glyph].draw(TransformPen(bounds, mirror))
    font["hmtx"][name] = (width, int(bounds.bounds[0]) if bounds.bounds else 0)
    for table in font["cmap"].tables:
        if table.isUnicode():
            table.cmap[cp] = name
font.setGlyphOrder(order)
font["maxp"].numGlyphs = len(order)
font.save(dst)
PY
    font="${work}/icons.otf"
fi

codepoint() {   # codepoint <Material 名或派生名> → 十六进制码点
    local cp entry
    for entry in "${DERIVED[@]}"; do
        if [[ "${entry%%:*}" == "$1" ]]; then cut -d: -f2 <<< "${entry}"; return; fi
    done
    cp="$(awk -v n="$1" '$1 == n { print $2; exit }' "${work}/MaterialIconsRound-Regular.codepoints")"
    [[ -n "${cp}" ]] || { echo "找不到图标 $1" >&2; exit 1; }
    echo "${cp}"
}

utf8_escape() {   # utf8_escape <十六进制码点> → C 字符串转义
    python3 -c "import sys; print(''.join('\\\\x%02X' % b for b in chr(int(sys.argv[1], 16)).encode()))" "$1"
}

header() {   # header <文件名> <说明>
    echo "// main/icons/$1: 由 tools/gen-icon-font.sh 生成,请勿手改。"
    echo "// $2"
    echo "// 字形来自 Google Material Icons Round(Apache-2.0,见 LICENSE-material-icons),提交 ${COMMIT};del 由 backspace 水平镜像派生。"
}

mkdir -p "${out_dir}"
small_list="${out_dir}/ib_icon_list.h"
large_list="${out_dir}/ib_icon_large_list.h"
header ib_icon_list.h "按键提示图标表(X-macro):IB_ICON_DEF(枚举名, \"协议 id\", \"UTF-8 字形\", 码点);顺序即 ib_icon_t 枚举顺序(IB_ICON_NONE 之后)。字号 22 px。" > "${small_list}"
header ib_icon_large_list.h "页面主图标表(X-macro):IB_ICON_LARGE_DEF(枚举名, \"UTF-8 字形\", 码点)。字号 56 px。" > "${large_list}"

ranges_22=()
ranges_56=()
for entry in "${ICONS[@]}"; do
    IFS=: read -r enum id material sizes <<< "${entry}"
    cp="$(codepoint "${material}")"
    utf8="$(utf8_escape "${cp}")"
    IFS=, read -ra size_list <<< "${sizes}"
    for size in "${size_list[@]}"; do
        case "${size}" in
        22)
            [[ "${id}" != "-" ]] || { echo "${enum}:22 px 图标必须有协议 id" >&2; exit 1; }
            ranges_22+=("0x${cp}")
            printf 'IB_ICON_DEF(%-10s "%s", %-14s 0x%s)   // %s\n' "${enum}," "${id}" "\"${utf8}\"," "${cp}" "${material}" >> "${small_list}"
            ;;
        56)
            ranges_56+=("0x${cp}")
            printf 'IB_ICON_LARGE_DEF(%-10s %-14s 0x%s)   // %s\n' "${enum}," "\"${utf8}\"," "${cp}" "${material}" >> "${large_list}"
            ;;
        *)
            echo "不支持的字号 ${size}(${enum})" >&2
            exit 1
            ;;
        esac
    done
done

# gen_font <字号> <码点列表...>:生成字体并做可复现处理(去掉临时路径、加来源与许可证说明)。
gen_font() {
    local size="$1"; shift
    local name="ib_icon_font_${size}"
    local range_arg; range_arg="$(IFS=,; echo "$*")"
    npx --yes "${LV_FONT_CONV}" \
        --font "${font}" -r "${range_arg}" \
        --size "${size}" --bpp "${BPP}" --format lvgl --no-compress \
        --lv-include "lvgl.h" --lv-font-name "${name}" \
        -o "${out_dir}/${name}.c"
    python3 - "${out_dir}/${name}.c" "${work}" "${out_dir}" "${COMMIT}" "${name}" <<'PY'
import sys
path, work, out_dir, commit, name = sys.argv[1:6]
src = open(path, encoding="utf-8").read()
src = src.replace(work + "/", "").replace(work, "").replace(out_dir + "/", "main/icons/")
header = (
    "/* main/icons/" + name + ".c: 由 tools/gen-icon-font.sh 生成,请勿手改。\n"
    " * 字形来自 Google Material Icons Round(https://github.com/google/material-design-icons,\n"
    " * 提交 " + commit + "),按 Apache License 2.0 使用,许可证全文见同目录 LICENSE-material-icons。\n"
    " * del(U+F8FC)由 backspace 水平镜像派生(fontTools)。\n"
    " * Copyright Google LLC. Licensed under the Apache License, Version 2.0.\n"
    " */\n"
)
open(path, "w", encoding="utf-8").write(header + src)
PY
}

gen_font 22 "${ranges_22[@]}"
gen_font 56 "${ranges_56[@]}"
cp "${work}/LICENSE" "${out_dir}/LICENSE-material-icons"
echo "已生成 ${out_dir}:ib_icon_font_22.c(${#ranges_22[@]} 个)、ib_icon_font_56.c(${#ranges_56[@]} 个)、ib_icon_list.h、ib_icon_large_list.h"
