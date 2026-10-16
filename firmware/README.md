# InputBetter Passport 固件

FoloToy AI Passport(ESP32-C3、8 MB Flash、ST7789 240×320、三键单 ADC、ES8311 麦克风/扬声器、CW2017 电量计)上的 InputBetter 配套固件。设备是"瘦终端":上报按键原始事件、渲染 Mac 下发的状态、推送麦克风音频。

- 协议:`../docs/protocol.md`(v1)
- 界面:`../docs/device-ui.md`

## 编译

需要 ESP-IDF v5.5.3(`~/esp/esp-idf-v5.5.3`)。

```bash
cd firmware
source ~/esp/esp-idf-v5.5.3/export.sh   # 本机有多个 python 时先 export IDF_PYTHON_ENV_PATH=~/.espressif/python_env/idf5.5_py3.12_env
idf.py set-target esp32c3                # 只需一次
idf.py build
```

校验(主机单元测试 + 编译 + 分区检查):

```bash
tools/validate.sh          # 全部
tools/validate.sh --host   # 只跑主机测试(不需要 ESP-IDF)
```

## 烧录

```bash
../scripts/flash-firmware.sh             # PORT=/dev/cu.usbmodemXXXX 可指定串口
```

脚本会:检查串口没有被 InputBetter / Passport Keys app 或其它程序占用 → 编译 → 该设备(按 MAC)第一次烧录时把整片 8 MB Flash 备份到 `~/esp/passport-backups/passport-<MAC>-flash.bin` → 检查写入地址都在 `cardid` 之前 → 只写 bootloader / 分区表 / 应用,不擦除整片,**不写 `cardid` 分区(0x356000)**。

分区:`nvs 0x9000`、`phy_init 0xf000`、`factory 0x10000 (3 MB)`、`cardid 0x356000 (16 KB,出厂身份数据,只保留不写)`。

## 目录结构

```
firmware/
├── components/bsp/        硬件驱动(源自 folotoy/ai-passport,MIT,见其 LICENSE):显示/LVGL、三键 ADC、ES8311、CW2017、I2C
├── main/
│   ├── main.c             入口:按顺序初始化 BSP 与应用
│   ├── ib_app.*           应用核心:事件队列 + 状态机(在线、状态、按键上报、麦克风、Agent 通知、熄屏、电量、时钟)
│   ├── ib_keys.*          按键过滤(纯逻辑):何时上报、ack、熄屏唤醒
│   ├── ib_links.*         每条链路的在线判断(纯逻辑):15 s 超时、bye、拔线
│   ├── ib_protocol.*      协议(纯逻辑):消息格式化、扁平 JSON 命令解析、行组帧、二进制帧头
│   ├── ib_usb.*           USB Serial/JTAG 链路(与日志共用)
│   ├── ib_ble.*           NimBLE GATT 外设,广播名 InputBetter
│   ├── ib_audio.*         麦克风上行(IMA ADPCM)+ 本地合成提示音
│   ├── ib_adpcm.*         IMA ADPCM 编解码(纯逻辑)
│   ├── ib_clock.*         离线时钟格式化(纯逻辑)
│   ├── ib_ui.*            UI 核心:页面调度、切换动画、逐帧定时器(约 30 fps)、对外接口加锁
│   ├── ib_ui_page.h       页面接口(create / enter / update / frame)
│   ├── ib_ui_gfx.*        配色、缓动、整数三角函数、自绘控件与 lv_draw 封装
│   ├── ib_ui_statusbar.*  顶部状态栏(链路 / 电量 / 录音计时 / LIVE)
│   ├── ib_ui_hints.*      右侧竖排按键提示图标列(三个键的纵坐标常量 IB_HINT_Y_* 在这里调)
│   ├── ib_icons.*         keys 命令的图标 id ↔ 枚举(纯逻辑)
│   ├── icons/             生成的图标字体 ib_icon_font_22.c / ib_icon_font_56.c、图标表 ib_icon_list.h / ib_icon_large_list.h、Apache-2.0 许可证
│   ├── ib_ui_agent.*      Agent 通知层(全屏 / 录音中横幅)
│   └── ib_ui_<页面>.c     offline / idle / rec / proc / done / err / sub / list 各页面
├── tests/                 主机测试(cc 直接编译,不依赖 ESP-IDF)
└── tools/
    ├── validate.sh        测试 + 编译校验
    ├── gen-icon-font.sh   重新生成图标字体(需要 Node.js;上游字体按固定提交下载并校验 SHA-256)
    └── ui-preview/        主机界面预览:离屏渲染各页面 / 动画帧并导出 PNG(见下文)
```

模块之间只通过头文件通信:UI 不知道协议,协议不知道硬件,`ib_app` 负责把它们串起来。

## 界面预览(不用烧录)

```bash
tools/ui-preview/run.sh          # 全部场景 → tools/ui-preview/out/NN_<名称>.png(480x640)
tools/ui-preview/run.sh list     # 只保存文件名含 list 的截图
SCALE=3 tools/ui-preview/run.sh  # 放大 3 倍
```

在 macOS 上用 cmake + clang 编译固件同一份 LVGL 9.5.0(配置直接取固件的 `build/config/sdkconfig.h`)和 `main/ib_ui*.c` 原样代码,虚拟 240×320 RGB565 显示、20 行双缓冲,时间按 5 ms 节拍推进,所以动画第 N 毫秒的画面与真机一致。场景在 `tools/ui-preview/preview_scenarios.c`,只调用 `ib_ui.h` 的公开接口(与 `ib_app` 相同)。第一次使用前需要先执行过一次 `idf.py build`。

## 实现要点

- **日志**:USB 串口与协议共用,默认只输出 WARN 及以上;协议行与音频帧直接整段写入驱动发送环,不会出现半行 JSON。
- **动画**:每个页面用少量"自绘控件"(一个无样式 lv_obj + `LV_EVENT_DRAW_MAIN` 里画图元),逐帧只更新几何参数并重绘该控件区域;切换动画只用 opa / translate,不产生 LVGL 图层缓冲(C3 内存放不下整页图层)。熄屏时暂停逐帧定时器。
- **麦克风**:16 kHz 单声道,每 20 ms 一块 164 字节 IMA ADPCM;USB 每帧 2 块,BLE 每帧 1 块(170 字节,需 MTU ≥ 173)。
- **充电标志**:板上没有充电状态引脚,`chg` 按"插着 USB 主机且电量 < 100%"推断。
