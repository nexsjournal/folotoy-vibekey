#!/usr/bin/env python3
"""根据编译器提取的字符串(*.stringsdata)和 Localization/en.json 生成 String Catalog。

用法(先编译一次 Debug,让编译器提取字符串):
    ./scripts/update-strings.sh
- 源语言是简体中文,键即中文原文;英文翻译放在 Localization/en.json(按界面语境翻译)。
- 缺少翻译的键会列出来并以非 0 退出,提醒补充 en.json。
"""
import glob
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
derived = root / "build/DerivedData/Build/Intermediates.noindex/InputBetter.build/Debug/InputBetter.build/Objects-normal/arm64"
en = json.loads((root / "Localization/en.json").read_text(encoding="utf-8"))

keys = set()
for f in glob.glob(str(derived / "*.stringsdata")):
    data = json.loads(Path(f).read_text(encoding="utf-8"))
    for entry in data.get("tables", {}).get("Localizable", []):
        keys.add(entry["key"])
if not keys:
    sys.exit("没有找到提取的字符串,请先编译 Debug(SWIFT_EMIT_LOC_STRINGS=YES)")

cjk = re.compile(r"[一-鿿]")
strings, missing = {}, []
for key in sorted(keys):
    if not key.strip():
        continue
    entry = {}
    if cjk.search(key):
        if key in en:
            entry["localizations"] = {"en": {"stringUnit": {"state": "translated", "value": en[key]}}}
        else:
            missing.append(key)
    else:
        # 品牌名、URL、设备上的英文等,两种语言一样。
        entry["shouldTranslate"] = False
    strings[key] = entry

catalog = {"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}
out = root / "InputBetter/Localizable.xcstrings"
out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
unused = sorted(set(en) - keys)
print(f"{len(strings)} 条字符串写入 {out.relative_to(root)}")
if unused:
    print(f"en.json 里有 {len(unused)} 条已不再使用:", *unused, sep="\n  ")
if missing:
    print(f"缺少英文翻译 {len(missing)} 条:", *missing, sep="\n  ")
    sys.exit(1)
