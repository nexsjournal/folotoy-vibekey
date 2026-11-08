# VibeKey 发布检查清单

面向公开下载 / 官网发布；本机开发版也必须先过完「代码与版本」和「固件与设备」。

## 1. 版本与内容

- [ ] `app/project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 已递增。
- [ ] `firmware/CMakeLists.txt` 的 `PROJECT_VER` 已递增；固件协议不兼容时同步提升 `IB_PROTO_VERSION`。
- [ ] `docs/changelogs/` 有本次改动的独立记录。
- [ ] `docs/releases/<version>.zh.md` / `.en.md` 已写用户能看懂的更新说明。
- [ ] README、`docs/protocol.md`、`docs/device-ui.md` 与实际行为一致。
- [ ] 没有把开发文案、测试入口、临时 URL、绝对路径、真实 MAC、用户照片或密钥提交到仓库。

## 2. 构建与签名

- [ ] `cd app && ./scripts/test.sh` 通过。
- [ ] `cd firmware && ./tools/validate.sh` 通过（主机测试 + ESP-IDF 构建 + 分区检查）。
- [ ] `scripts/tests/test_flash_layout.py` 通过，`cardid` 仍是 `0x356000/0x4000`。
- [ ] Release 构建使用 Developer ID 签名；公证 Accepted、`stapler` 成功、`spctl` 通过。
- [ ] DMG / appcast / Sparkle 签名完成；官网下载文件的 SHA-256 与本地一致。
- [ ] 官网版配置了更新接口；开源自编译版不显示“检查更新失败”之类的误导提示。

## 3. 固件与设备

- [ ] 官网固件清单的版本 / build / SHA-256 正确；旧 app 能识别“需要先更新 app”。
- [ ] 首次刷写前有整片 8 MB 备份；刷写脚本只写 bootloader / 分区表 / app，不写 `cardid`。
- [ ] 升级路径覆盖：旧固件 → 新固件、新 app → 旧固件、断电 / 拔线中断。
- [ ] 壁纸分区写入失败 / CRC 不符时能回退内置猫图，不影响启动。
- [ ] 电池、充电、低电量、自动息屏在真机各验证一次。

## 4. 功能验收

- [ ] USB / Wi-Fi / BLE 三种链路分别连接、断开、重连；设备 OFFLINE 与 Mac 显示的“最后在线”一致。
- [ ] Mac 睡眠 / 唤醒后设备能自动恢复；USB 插着但 Mac 未运行时提示可理解。
- [ ] 听写、翻译听写、实时字幕各跑一遍；字幕原文 / 译文 / 应用名在设备上可见。
- [ ] 长按上键切模式、长按下键切应用 / 项目 / 会话；中文项目名不显示拼音、不超出屏幕。
- [ ] 超长项目名最多两行，超出部分显示省略号；返回上级和关闭列表行为一致。
- [ ] 壁纸“填充 / 完整”各上传一次；预览包含状态栏、时钟、日期；设备重启后保持。
- [ ] 词汇表可从菜单直接打开；新增词、别名纠正、推荐词追加均生效。

## 5. 权限与隐私

- [ ] 首次启动说明麦克风、辅助功能、屏幕录制（字幕）权限用途；拒绝后有可操作提示。
- [ ] 明确声明：聊天正文不读取、不记录；Agent 只读侧栏 / 窗口标题；壁纸原图只在内存处理。
- [ ] 隐私政策、支持链接、反馈邮箱可访问；崩溃 / 诊断数据默认关闭或明确征得同意。
- [ ] 第三方许可（LVGL、Noto Sans SC、Sparkle、onnxruntime、sherpa-onnx 等）随包或官网提供。

## 6. 发布后

- [ ] 官网首页、下载页、固件页、支持页均为 200；下载按钮指向新版本。
- [ ] `/firmware/manifest.json` 与 appcast 指向同一版本；旧版本仍可回滚。
- [ ] 监控首批用户的崩溃、连接失败、固件刷写失败；保留一键回退说明。
- [ ] 发布记录写入 `docs/changelogs/`，并在 GitHub Release 标注固件兼容版本。
