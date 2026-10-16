# 第三方组件与许可

本项目代码采用 MIT 许可(见 LICENSE)。下列第三方组件按各自许可使用。

## 随仓库提交

| 组件 | 位置 | 许可 |
| --- | --- | --- |
| folotoy/ai-passport 板级支持包 | `firmware/components/bsp` | MIT(见该目录 LICENSE) |
| Material Icons Round(生成的图标字体) | `firmware/main/icons` | Apache-2.0(见 `LICENSE-material-icons`) |
| stb_image_write | `firmware/tools/ui-preview/third_party` | MIT / Public Domain(见文件末尾) |
| silero-vad 模型 | `app/InputBetter/Resources/silero_vad.onnx` | MIT(snakers4/silero-vad) |

## 编译时获取(不在仓库中)

| 组件 | 方式 | 许可 |
| --- | --- | --- |
| WhisperKit(argmax-oss-swift) | Swift Package | MIT |
| sherpa-onnx / onnxruntime | Swift Package | Apache-2.0 / MIT |
| KeyboardShortcuts | Swift Package | MIT |
| ESP-IDF、LVGL、esp_lvgl_port 等 | ESP-IDF 组件管理器 | Apache-2.0 / MIT |
| esptool 独立版 | `app/scripts/bundle-device-assets.sh` 下载并打包进 app | GPL-2.0(作为独立程序调用,附 LICENSE) |

## 运行时由用户下载

| 模型 | 许可 |
| --- | --- |
| Whisper(argmaxinc/whisperkit-coreml) | MIT |
| SenseVoice Small(sherpa-onnx 转换版) | FunASR 模型许可,使用前请阅读 |
| Apple Speech | 由 macOS 提供 |
