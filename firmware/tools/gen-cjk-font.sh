#!/usr/bin/env bash
# 生成 SUB / LIST / RESULT 用的简体中文字体(LVGL C 字体),可重复执行。
#
# 来源:Google Noto Sans SC,SIL Open Font License 1.1
#   仓库   https://github.com/google/fonts
#   提交   86aced91de05cd4f96a06838124cca45be337b2b
#   文件   ofl/notosanssc/NotoSansSC[wght].ttf、ofl/notosanssc/OFL.txt
# 字重:Variable Font 固定为 SemiBold(600),让设备侧中文项目 / 会话名更清晰。
# 字符集:GB2312 全部汉字(6763)+ 常用中文标点 + ASCII;默认 14 px、4 bpp、不压缩。
# 生成结果放入 main/fonts/ib_cjk_font_14.c。改字号或字符集后重新运行本脚本。
set -euo pipefail

commit="86aced91de05cd4f96a06838124cca45be337b2b"
base="https://raw.githubusercontent.com/google/fonts/${commit}/ofl/notosanssc"
fw="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
font_size="${CJK_FONT_SIZE:-14}"
font_name="ib_cjk_font_${font_size}"
work="$(mktemp -d "${TMPDIR:-/tmp}/ib-cjk-font.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cd "${work}"

curl -fsSL "${base}/NotoSansSC%5Bwght%5D.ttf" -o NotoSansSC.ttf
curl -fsSL "${base}/OFL.txt" -o OFL.txt
printf '%s  %s\n' \
    a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da NotoSansSC.ttf \
    1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9 OFL.txt | shasum -a 256 -c -

python3 - <<'PY'
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

font = TTFont("NotoSansSC.ttf")
instantiateVariableFont(font, {"wght": 600}).save("NotoSansSC-SemiBold.ttf")
PY

python3 - <<'PY' > cjk-symbols.txt
chars = []
for hi in range(0xA1, 0xF8):
    for lo in range(0xA1, 0xFF):
        try:
            chars.append(bytes([hi, lo]).decode("gb2312"))
        except UnicodeDecodeError:
            pass
extra = "，。！？：；、（）《》“”‘’…—·【】￥「」『』〈〉～"
print("".join(dict.fromkeys(chars + list(extra))), end="")
PY
symbols="$(cat cjk-symbols.txt)"

npx --yes lv_font_conv@1.5.3 --font NotoSansSC-SemiBold.ttf \
    --range 0x20-0x7e --symbols "${symbols}" \
    --size "${font_size}" --bpp 4 \
    --format lvgl --no-compress --no-kerning --lv-include lvgl.h \
    --lv-font-name "${font_name}" \
    --output "${font_name}.c"

cp "${font_name}.c" "${fw}/main/fonts/"
cp OFL.txt "${fw}/main/fonts/LICENSE-noto-sans-sc"
python3 - "${fw}/main/fonts/${font_name}.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").rstrip() + "\n", encoding="utf-8")
PY
ls -lh "${fw}/main/fonts/${font_name}.c"
