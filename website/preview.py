#!/usr/bin/env python3
"""本地预览官网:不用部署,直接看 website/site 的效果。

做的事和 deploy.sh 的组装步骤一致,只是不落盘:
  - 把页面里的 {{VERSION}} {{SIZE}} {{SHA256}} {{DMG_URL}} 换成 app/build/release 里最新 DMG 的实际值
    (还没有 DMG 时用占位值,链接指向线上);
  - /download/ 映射到 app/build/release,/firmware/ 映射到 firmware/build/release;
  - 全部响应 no-store,改完文件刷新就能看到。

用法:website/preview.py [--port 8788] [--open]
注意:网页刷写需要 Web Serial,本地 http://127.0.0.1 算安全上下文,但串口设备在本机,行为和线上一致。
"""
from __future__ import annotations

import argparse
import hashlib
import mimetypes
import os
import sys
import webbrowser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "website" / "site"
RELEASE = ROOT / "app" / "build" / "release"
FIRMWARE = ROOT / "firmware" / "build" / "release"


def latest_dmg() -> Path | None:
    """按修改时间取最新的 InputBetter-*.dmg。"""
    files = sorted(RELEASE.glob("InputBetter-*.dmg"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def replacements() -> dict[str, str]:
    dmg = latest_dmg()
    if not dmg:
        return {
            "VERSION": "0.0.0",
            "SIZE": "— MB",
            "SHA256": "本地预览（还没有构建安装包）",
            "DMG_URL": "https://input.0os.io/",
        }
    version = dmg.name.removeprefix("InputBetter-").removesuffix(".dmg")
    size = dmg.stat().st_size
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    return {
        "VERSION": version,
        "SIZE": f"{size / 1_000_000:.0f} MB",
        "SHA256": digest,
        "DMG_URL": f"/download/{dmg.name}",
    }


class PreviewHandler(SimpleHTTPRequestHandler):
    """静态文件 + 占位符替换 + /download /firmware 映射。"""

    def __init__(self, *args, values: dict[str, str], **kwargs):
        self.values = values
        super().__init__(*args, directory=str(SITE), **kwargs)

    def log_message(self, fmt, *args):  # 只保留错误,别刷屏
        if str(args[1] if len(args) > 1 else "")[:1] in {"4", "5"}:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def resolve(self) -> Path | None:
        path = unquote(urlparse(self.path).path)
        if path in ("", "/"):
            return SITE / "index.html"
        if path.startswith("/download/"):
            name = Path(path).name
            candidate = RELEASE / name
            return candidate if candidate.is_file() else None
        if path.startswith("/firmware/"):
            rel = Path(*[p for p in path.split("/") if p][1:])
            candidate = (FIRMWARE / rel).resolve()
            try:
                candidate.relative_to(FIRMWARE.resolve())
            except ValueError:
                return None
            return candidate if candidate.is_file() else None
        candidate = (SITE / path.lstrip("/")).resolve()
        try:
            candidate.relative_to(SITE.resolve())
        except ValueError:
            return None
        if candidate.is_dir():
            candidate = candidate / "index.html"
        return candidate if candidate.is_file() else None

    def send(self, include_body: bool) -> None:
        target = self.resolve()
        if target is None:
            self.send_error(404, "Not found")
            return
        suffix = target.suffix.lower()
        body = target.read_bytes()
        # 页面与页面脚本里的占位符要替换;vendor 里的第三方库原样返回
        if suffix in {".html", ".js"} and "vendor" not in target.parts:
            text = body.decode("utf-8")
            for key, value in self.values.items():
                text = text.replace("{{%s}}" % key, value)
            body = text.encode("utf-8")
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if suffix in {".html", ".js", ".css", ".json"}:
            ctype += "; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        self.send(True)

    def do_HEAD(self):
        self.send(False)


def main() -> None:
    parser = argparse.ArgumentParser(description="本地预览 InputBetter 官网")
    parser.add_argument("--port", type=int, default=8788, help="端口,默认 8788")
    parser.add_argument("--open", action="store_true", help="启动后打开浏览器")
    args = parser.parse_args()

    values = replacements()
    dmg = latest_dmg()
    if dmg:
        print(f"安装包: {dmg.name} ({values['SIZE']})")
    else:
        print("安装包: 没有找到 app/build/release/InputBetter-*.dmg,下载链接指向线上")
    if not FIRMWARE.is_dir():
        print("固件:   没有找到 firmware/build/release,网页刷写会显示没有固件")

    handler = partial(PreviewHandler, values=values)
    with ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        url = f"http://127.0.0.1:{args.port}/"
        print(f"预览:   {url}  (Ctrl+C 结束)")
        if args.open:
            webbrowser.open(url)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")


if __name__ == "__main__":
    main()
