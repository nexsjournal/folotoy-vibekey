# VibeKey Passport 协议 v1

Passport 固件(`firmware/`)与 VibeKey macOS app(`app/`)之间的通信协议。设备是"瘦终端":所有状态由 Mac 决定,设备只上报按键、渲染 Mac 下发的状态,并在需要时推送麦克风音频。

## 链路

| 链路 | 设备侧 | Mac 侧 |
| --- | --- | --- |
| USB | ESP32-C3 USB Serial/JTAG(CDC) | `/dev/cu.usbmodem*`,VID `0x303A`;115200 raw、`TIOCEXCL`、关 HUPCL;打开后先清 RTS 再清 DTR(避免复位芯片) |
| BLE | NimBLE GATT 外设,广播名 `VibeKey`,无配对 | CoreBluetooth central |
| Wi-Fi | 2.4 GHz STA；TCP 8765，TLS 1.2 ECDHE-PSK-ChaCha20-Poly1305 | Network.framework；USB 配对的多组 `fb-<随机值>.local`，mDNS `_folobutton._tcp` |

USB 与 ESP-IDF 日志共用通道:Mac 只从 `{"t":` 处开始解析一行,其余内容忽略。链路优先级为 USB > Wi-Fi > BLE。Wi-Fi 在 USB 连接期间也可完成握手待机；USB 断开后重发缓存的 config/state/keys/mic 并切换 Wi-Fi。C3 无 PSRAM，为保证录音 DMA 和 TLS 的内存，设备有配网记录时只启用 Wi-Fi，无配网时启用 BLE；两种无线模式在重启边界切换，Wi-Fi 模式不会同时广播 BLE。按键只接收当前活动链路，之后再按 boot/seq 去重；音频也按活动链路过滤。

### USB 配网与局域网传输

Mac 设置 › Passport › Wi-Fi 无线连接中填写网络名与密码。仅已握手 USB 接受 `{"cmd":"wifi","op":"add","ssid":"<SSID>","password":"<密码>","host":"fb-<随机值>","psk":"<64位十六进制随机密钥>"}`，以换行结尾，总长小于 512 字节。SSID 按 UTF-8 计 1–32 字节；密码为空（开放网络）或 8–63 字节；不允许 NUL。此命令单独经 cJSON 解析，不经过屏幕文本的 ASCII 归一化。没有 `op` 的旧命令按 `add` 处理。

设备最多保存 4 个网络，每组的 host 与 PSK 独立；同一 SSID 再次 `add` 时覆盖原记录并设为当前网络。普通 NVS 的 `ib_wifi/networks` 保存 `version=2 + count + active + networks[]`，不改 cardid；旧 `ib_wifi/config`（version 1）在首次启动时迁移，成功后删除旧键。

| 网络控制命令 | 行为 |
| --- | --- |
| `{"cmd":"wifi","op":"add",...}` | 仅 USB：新增/覆盖网络并设为当前，重启 Wi-Fi 栈 |
| `{"cmd":"wifi","op":"select","ssid":"Office"}` | USB / Wi-Fi / BLE：切换当前网络，重启无线栈 |
| `{"cmd":"wifi","op":"remove","ssid":"Office"}` | USB / Wi-Fi / BLE：删除网络；若删的是当前项则选择剩余第一项 |
| `{"cmd":"wifi","op":"list"}` | 仅 USB：返回网络列表，不重启 |
| `{"cmd":"wifi","op":"ble"}` | USB / Wi-Fi / BLE：保留配网记录，手动重启到 BLE 单栈；插回 USB 不自动回 Wi-Fi |
| `{"cmd":"wifi","op":"clear"}` 或 `{"clear":1}` | 仅 USB：清除全部网络，重启恢复 BLE |

Mac 生成 32 字节随机 PSK，仅通过 USB 交给设备。Mac 私有 CredentialStore 保存网络数组（SSID + host + PSK）；旧版单条 host/key 首次读取时自动迁移。设备只向 USB 上报 `{"t":"wifi","stage":"connecting|ready|auth_error|not_found|config_error|network_error|server_error","host":"fb-<随机值>","ip":"<局域网地址或空>","ssid":"<SSID>","active":0,"count":2}`，不返回密码或密钥。`stage:"list"` 另带 `networks:[{"ssid":"Home","host":"fb-home","active":0},...]`。USB hello 也会补发当前状态；可附加 `heap` 空闲堆字节数用于诊断，界面不展示该实现细节。初始化失败时返回 network_error，不保留虚假的 connecting。`ready` 表示设备获得 IP；Mac 的 Wi-Fi `hello` 握手完成才显示无线可用。

长按 ▲ 约 1 秒切换听写、翻译、字幕模式；不松手继续到约 2.5 秒打开本地网络列表。蓝牙模式或完全离线时也可长按 ▼ 直接打开该列表，最后一项 `USE BLUETOOTH` 可直接重启到 BLE 单栈；短按 OK 写入 NVS active 后重启。蓝牙在线时选择 Wi-Fi（包括当前首选项）会清除蓝牙模式并重启到 Wi-Fi；Wi-Fi 离线时选择当前网络也会重试。只有 Wi-Fi 链路实际在线且选择当前网络时才直接关闭菜单。Wi-Fi 正常在线时长按 ▼ 仍保留给 Agent 导航。这条路径不经过 Mac 协议。Mac 会同时尝试本机保存的所有 `host.local` 以及最近学到的局域网地址，第一个 TLS 握手成功的即当前网络；手机热点屏蔽 mDNS 时仍可走地址回退。

TLS 使用 USB 配对 PSK 验证双方并加密，无需云端。加密流内部沿用现有 JSON Lines 与 FF FE ADPCM 帧；2 个 ADPCM 块一帧，同 USB。断线自动重连并重发状态；心跳和超时策略与 USB 相同。局域网需允许设备间访问与 mDNS，访客隔离网络不适用；Mac 需运行且未锁屏，系统询问本地网络权限时允许 VibeKey。跨互联网连接不在本次范围内。

Wi-Fi TLS 的按键、心跳等控制消息与 ADPCM 帧各有独立的有界队列；每帧发送前优先取控制消息，音频队列满时只丢音频。TLS 握手完成后使用非阻塞收发，暂时不可写时保留原帧和偏移，连续 8 秒无写入进度才主动重连。服务端握手有 5 秒超时，另有 6 秒看门狗强制关闭残留半连接，避免旧客户端占住唯一 TLS 服务；接受的连接启用 TCP_NODELAY。Wi-Fi 重新关联后会关闭旧 TLS 会话。Wi-Fi 启动时关闭无线省电以减少空闲后的按键延迟，代价是更高的耗电。断开后按 1→2→4→8 秒退避重连，取得 IP 后复位；状态额外上报 `rssi`，供 App 判断热点信号强度。

BLE GATT:

| 项 | UUID | 属性 |
| --- | --- | --- |
| Service | `B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Primary,UUID 放在广播包里 |
| Events(设备 → Mac,JSON 行) | `B5E10002-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Notify |
| Commands(Mac → 设备,JSON 行) | `B5E10003-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Write / Write Without Response |
| Audio In(设备 → Mac,二进制帧) | `B5E10004-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Notify |

一次写入/通知可能只包含半行,两端都按 `\n` 重新组帧。

## 文本消息

JSON Lines:每条消息是一行扁平 UTF-8 JSON 对象,以 `\n` 结尾,单行最长 511 字节。设备只解析扁平对象:字符串值、非负整数值;未知字段忽略,未知命令整条丢弃。`state` / `keys` 的屏幕文本仍由 Mac 转成 ASCII、最长 23 字节;`list` 的 `title` / `i0..i5` 和字幕 `caption` 的 `app` / `src` / `dst` 保留 UTF-8(`list` 每项 ≤47 字节,`app` ≤48 字节,`src` / `dst` 各 ≤180 字节)。

### 设备 → Mac

| 类型 | 示例 | 说明 |
| --- | --- | --- |
| hello | `{"t":"hello","fw":"vibekey","proto":1,"ver":"0.1.0","build":"a506a8bb","boot":"9f3a21c4"}` | 回复 `hello` 命令。`build` 是固件 ELF 文件 SHA-256 的前 8 位小写十六进制(esptool 把它写进镜像,设备用 `esp_app_get_elf_sha256()` 读出),等于 `shasum -a 256 firmware/build/VibeKey-Passport.elf` 的前 8 位,也等于 `VibeKey-Passport.bin` 文件偏移 `0xB0` 起 4 个字节的十六进制;Mac 用它判断设备固件是否与官网最新固件(`/firmware/manifest.json` 的 `build`)一致 |
| key | `{"t":"key","k":"ok","e":"down","seq":12,"boot":"9f3a21c4"}` | 按键原始事件。`k`:`ok`/`up`/`down`;`e`:`down`(按下瞬间)/`up`(松开)/`long`(按住 1 秒)。该次按压用于关闭 agent 通知时附加 `"ack":1`(同一次按压的 down/up/long 都带) |
| bat | `{"t":"bat","soc":87,"mv":4012,"chg":0}` | `hello` 之后及每 60 秒;读不到为 `-1`;`chg` 是否在充电(读不到为 0);判定为已充满时 `soc` 报 100、`chg` 为 0,`mv` 始终是实测电压 |
| pong | `{"t":"pong"}` | 回复 `ping` |
| wake | `{"t":"wake"}` | OFFLINE 页按 OK 时发送，请求 Mac 重新握手。USB/BLE 都可用时各发一次；Mac 收到后重置该链路握手状态并重发 `hello`，设备回 `hello` 后补发 `config` / `state` / `keys` |
| wallpaper | `{"t":"wallpaper","ok":1,"p":"start"}` | 离线页背景上传的阶段回执。`p`:`start`(分区擦除完成)/ `done`(整图校验并写入成功)/ `clear`(恢复默认成功);`ok=0` 表示该阶段失败。只有 `start` / `done` / `clear` 会回,分块不回执 |

- `seq` 本次上电后单调递增;`boot` 是每次上电随机生成的 8 位十六进制。Mac 用 `(boot, seq)` 去重。
- `fw` 新固件为 `vibekey`;0.1.7 及更早固件仍是上游的 `inputbetter`,Mac 两种都接受,不需要先刷机才能升级 app。
- 设备只在 Mac 在线时发送 `key`。Mac 离线时设备显示时钟,按键点亮屏幕;OK 额外发送 `wake` 请求重连,其余按键不上报。
- `chg`:板子没有充电状态引脚,固件按"USB 主机在位且电量 < 100"推断。CW2017 是纯电压模型电量计,SOC 在恒压段会饱和在 9x%(实测卡在 94%)到不了 100,所以另加"已充满"判定(固件 0.1.3 起,`main/ib_charge.*`):USB 在位、`soc ≥ 90` 且 `mv ≥ 4150` 持续 10 分钟 → 视为已充满,`soc` 报 100、`chg=0`。已充满后只在 `mv < 4100`(50 mV 回差)或 `soc < 90` 时清除,与 USB 是否在位无关(Mac 睡眠时 SOF 停止但仍在充电;真拔线后电池静置电压 ≥ 4.10 V 本来就是满的,等电压掉下去再回到实际读数,避免 100 → 94 跳变)。某次读数失败(`-1`)不改变判定。阈值是经验值,待实测调整。
- 在线状态按链路分别记录:任一合法命令都会让该链路在线;Mac 不发 `bye` 直接断开 BLE 时,只要 USB 还在通信,设备保持在线。
- USB 拔线检测有 1 s 去抖(固件 0.1.3 起):ESP-IDF 的 `usb_serial_jtag_is_connected()` 只是"约 4 ms 没收到 USB SOF 帧就判断开",Mac 睡眠 / 总线挂起时会短暂误报。设备要连续 1 s 读到不在位(期间也没收到 USB 命令)才清除 USB 链路;插线则立即在位。
- 全部链路都离线时设备切到离线时钟页、停麦、关闭 Agent 通知,但**保留 Mac 最后下发的 `state`**(`st` / `mode` / `msg`);恢复在线后直接回到对应页面(done / err 这类短暂结果页在离线时收拢为最近一次 idle / sub 的常驻页;列表内容作废,等 Mac 重发 `list`)。Mac 重新握手时仍会重发 `config` / `state` / `keys`。设备重启后状态从 idle 开始。
- BLE 音频帧 170 字节且不拆包,MTU 需 ≥ 173(macOS 默认协商结果满足)。

### Mac → 设备

| 命令 | 示例 | 设备行为 |
| --- | --- | --- |
| hello | `{"cmd":"hello"}` | 回复 `hello` + `bat`,链路标记为在线 |
| ping | `{"cmd":"ping"}` | 回复 `pong`。Mac 每 5 秒发送;设备 15 秒没收到任何命令即视为离线 |
| bye | `{"cmd":"bye"}` | Mac 退出前发送,设备立即显示离线 |
| config | `{"cmd":"config","mic":1,"engine":"Whisper Turbo","screen_off":60,"clock":1789097696,"sound":1}` | `mic`:1 表示听写音源是 Passport 麦克风(OK 键按下的瞬间设备就开始推送音频,不用等 `mic` 命令);`engine`:主页底部显示的引擎名;`screen_off`:空闲多少秒熄屏,0 为永不(改变后按新值立即生效);`clock`:Mac 本地时间(Unix 秒 + 时区偏移);`sound`:开始/结束提示音。字段都可选 |
| state | `{"cmd":"state","st":"rec","mode":"dict","msg":""}` | 切换设备界面。`st` 见下表;`mode`:`dict`(听写)/`tr`(翻译听写)/`sub`(字幕);`msg`:可选短文本(如 `Copied`、`No input`、应用名) |
| level | `{"cmd":"level","v":42}` | 0..100 的音量电平,`rec`/`sub` 状态下 Mac 约每 60 ms 发送一次,驱动动画 |
| mic | `{"cmd":"mic","on":1}` | 开/关麦克风上行。链路断开(bye、超时、拔线)时设备自动停止 |
| keys | `{"cmd":"keys","up":"enter","down":"esc","ok":"mic"}` | 屏幕右侧、贴着三个实体键显示的提示**图标**,值为图标 id(ASCII,区分大小写),随模式与用户映射变化;字段可选(没出现的键保持不变),空字符串或未知 id 隐藏该键的提示(不会让整条命令失效)。固定 id 集合:`enter`(回车)、`esc`(Esc)、`undo`(撤销)、`stab`(Shift-Tab)、`tab`(Tab)、`send`(⌘↩ 发送)、`stop`(停止)、`cancel`(取消)、`check`(确认)、`repeat`(重来)、`mode`(切换模式)、`apps`(应用切换器)、`mic`(说话)、`translate`(翻译)、`hide`(隐藏)、`up` / `down`(上 / 下移动)、`play`(开始)、`open`(打开)、`bksp`(⌫ 退格)、`del`(⌦ 向后删除)。旧固件不认识 `bksp` / `del`,会隐藏该提示。图标来自 Material Icons Round(`del` 由 backspace 水平镜像派生) |
| agent | `{"cmd":"agent","ev":"done","msg":"Claude Code"}` | 编程 Agent 通知(vibe coding):`ev` 为 `done`(任务完成)/ `input`(等待你确认或输入)/ `clear`(撤销通知);`msg` 为来源名或 `OK OPEN <项目名>`。设备弹出全屏通知层并播放提示音(`input` 每 20 秒提醒一次),任意键或 `clear` 关闭;按键仍上报 `key` 并附加 `"ack":1`。短按 OK 可由 Mac 解释为打开绑定会话 |

| list | `{"cmd":"list","title":"SWITCH APP","sel":2,"n":7,"top":0,"i0":"Ghostty","i1":"Chrome","i2":"Xcode","i3":"Finder","i4":"Mail","i5":"Notes"}` | 列表页内容(如应用切换器),选中项由 Mac 维护,设备只显示。`n`(总项数)与 `sel`(选中项绝对序号)必填,均为 0..65535,`n>0` 时要求 `sel<n`、`top<n`,否则整条丢弃;`top` 为 `i0` 在完整列表里的序号(缺省 0,用于滚动条);`title` 可选;`i0`..`i5` 为最多 6 个可见行(UTF-8,每项 ≤47 字节,可缺行),`i6` 及以后忽略。固件用 12 px SemiBold 中文字库显示中文项目 / 会话名,超出宽度时末尾显示 `..`。每次选中或滚动变化都重发整条 |
| usage | `{"cmd":"usage","uapp":"CODEX","utoday":"43,051,522","uweek":"43,051,522","utotal":"4,938,713,816","utab":0,"uquota":1,"uleft":7,"ureset":"4D 1H","u5quota":1,"u5left":63,"u5reset":"2H 10M","uplan":"PLUS","ucredit":0,"u1l":"5H LEFT","u1v":"63%","u1p":63,"u1d":"5H RESET 2H 10M","u2l":"WEEK LEFT","u2v":"7%","u2p":7,"u2d":"WEEK RESET 4D 1H","ufl":"PLAN PLUS","ufr":"CREDITS 0","uready":1}` | Agent 用量首页。`uapp` / `utoday` / `uweek` / `utotal` 为 ASCII(数字由 Mac 格式化);`utab` 0/1/2 = 今日/本周/累计;`uquota` / `u5quota` 省略表示对应额度接口不可用;`uleft` / `u5left` 为剩余百分比;`u1l/u1v/u1p/u1d`、`u2l/u2v/u2p/u2d` 是两行通用信息(标签/值/可选百分比进度/可选行说明),`udetail` 是无分项说明时的通用中间行,`ufl/ufr` 是底部两段;旧固件可继续使用 `ureset/uplan/ucredit`。`uready=0` 显示 `READING USAGE...`。字段均可选,但至少要带 `uapp` / `uready` / 一个 token 字段 |
| caption | `{"cmd":"caption","app":"ego lite","src":"今天讲一下 Passport 的字幕","dst":"Today we'll talk about Passport subtitles","live":0}` | SUB 页的 UTF-8 字幕。`app` 为应用名(优先于 `state.msg`);`src` / `dst` 为原文 / 译文,各最多 180 字节,Mac 只发最新内容的末尾;`live=1` 表示末句还在变化,译文用略暗颜色。字段可选,空字符串清空对应内容。旧固件忽略该命令 |
| wallpaper | `{"cmd":"wallpaper","size":153600,"crc":3735928559}`<br>`{"cmd":"wallpaper","off":288,"d":"..."}`<br>`{"cmd":"wallpaper","fin":1}`<br>`{"cmd":"wallpaper","clear":1}` | 离线页背景。`start` 必须同时有 `size` / `crc`,设备先擦除独立分区再回 `p:"start"`;随后按 `off` 递增发送每块 288 字节的 Base64(`d`,编码后 384 字符);`fin=1` 时校验总长度与 CRC32,写入头后回 `p:"done"` 并重启。`clear=1` 只擦除头部并重启回内置猫图。只建议经 USB / Wi-Fi 上传；BLE 太慢 |

壁纸分区为 `wallpaper,data,0x40,0x310000,0x30000`,不碰 `cardid`。内容为 16 字节头(`VKW1` + 小端 size + CRC32 + 保留)+ 240×320 RGB565 小端、行优先像素(153600 字节)。头最后写入；启动时 magic / 大小 / CRC 任一不符就回退固件内置猫图。CRC 是标准 IEEE 802.3(reflected `0xEDB88320`,init/xorout `0xFFFFFFFF`),与 Mac 端 `CRC32.checksum` 一致。

`st` 取值:

| st | 含义 |
| --- | --- |
| `idle` | 空闲,显示 `mode` 对应的模式卡片 |
| `rec` | 正在录音 / 听写 |
| `proc` | 识别或 LLM 处理中。此时按键不可用:Mac 仍下发 OK 的 `mic` 提示,设备把提示列画成禁用色,按下 OK 只给出"不可用"反馈、不开麦;Mac 也忽略这时的 OK(上一句处理完之前不开始新的一句) |
| `done` | 已输入;设备约 1.2 秒后自行回到 idle 动画(Mac 随后也会发 `idle`) |
| `err` | 失败,`msg` 为原因;约 2 秒后自行回到 idle |
| `sub` | 字幕运行中,`msg` 为应用名 |
| `list` | 列表页。设备收到 `st:"list"` **且**收到过 `list` 命令(先后不限)才显示列表页;切到其它 `st` 即离开,旧列表作废(下次需重发 `list`)。列表页上按键仍按原样上报 `key` 事件,上下移动与确认都由 Mac 解释 |
| `usage` | Agent 用量首页。切到该 `st` 前 Mac 先发 `usage` 数据;设备显示 Token 数和两行 Agent 元数据(Codex 是 5 小时 / 每周额度,其他 Agent 是会话数、上下文、模型等)。短按 OK 由 Mac 转成 `idle`(READY),长按 OK 直接开始录音,短按上下切 Tab |

握手成功后 Mac 立即下发 `config` 和当前 `state`;之后状态变化时下发 `state`,设置变化时下发 `config`,每 5 分钟重发 `config` 校准时钟。

**屏幕点亮与熄灭**(固件 0.1.3 起):只有用户动作或需要用户看的变化才点亮屏幕——按键、收到 `state`、`agent` 通知(`input` 每 20 秒提醒时)、链路由离线变在线。`config` 是设置同步 / 定期校时,**不**点亮屏幕(否则熄屏后每 5 分钟会自己亮一次)。`rec` / `proc` / `sub` 且在线时屏幕常亮;其余时间距最近一次点亮超过 `screen_off` 秒熄屏。

在线听写或翻译模式的 READY / USAGE 页熄屏时，OK 同时点亮屏幕并按当前页正常处理，按住可直接说话；其余页面和上下键首次按压只点亮屏幕。

### 按键语义(由 Mac 解释,默认"Vibe Coding"映射,上下键动作可在 Mac 设置里改)

| 按键 | idle(dict / tr) | rec | sub 模式 / 字幕运行中 |
| --- | --- | --- | --- |
| OK down/up | 按住说话、松开结束;短于 250 ms 取消本次录音 | 结束 | 开始 / 停止字幕 |
| up 短按 | 默认读取并绑定当前 Codex 输入框中的手动／语音草稿，再核对全文后点击“发送”;可改成普通快捷键 | — | 开关本场字幕的翻译(与字幕条「译」菜单同一开关) |
| down 短按 | 默认核对当前 Codex 任务正在运行后点击“停止”;可改成普通快捷键 | — | 收起 / 展开 Mac 上的字幕条(字幕条就是底部状态条的展开形态) |
| up long | 切换模式 dict → tr → sub(循环) | — | 切换模式 |
| up extra long | 打开网络 / 蓝牙列表 | — | 打开网络 / 蓝牙列表 |
| down long | 默认打开「切换应用」列表(可在 设置 › Passport › 按键 改成其他动作) | 取消本次录音 | — |

模式 `sub` 下按 OK 开始字幕,字幕应用为 Mac 设置里最后选择的应用。设备收到 `agent` 通知时,第一次按键关闭通知(上报的 `key` 带 `"ack":1`)。若为带来源会话的 Codex 完成卡,同一次 OK 短按的松开事件也会打开原对话;录音需要另一次长按。**录音中**通知只显示为顶部横幅、不拦截按键(否则松开 OK 结束录音会被当成关闭通知);离开录音页后横幅转为全屏通知层,下一次按键才带 ack 关闭它。

设备端麦克风时序(config `mic=1`):在线、IDLE 或 SUB 页且非 sub 模式时 OK 按下立即开麦;收到 `mic on:0`、state 变为 done/err、本地开麦 600 ms 后仍收到 idle / sub、2 秒内没收到 `rec`、或该链路断开时停止。rec → proc 时继续推流,等 `mic on:0`(Mac 要录完尾音),最多 500 ms。`mic on:1` 在发命令的链路上开麦。

`sub` 状态:Mac 只要在运行字幕(且没在听写、没打开列表)就发 `sub`,`mode` 为设备当前模式(不一定是 `sub`);按键含义按 `mode` 区分,由 `keys` 命令给出对应的提示图标。done / err 自动返回时,设备回到最近一次 idle / sub 的页面、模式和 `msg`。

## 二进制帧

帧头 6 字节 `FF FE type seq len_lo len_hi`,后跟 `len`(1..1024)字节负载。`0xFF`/`0xFE` 不会出现在 UTF-8 文本中,所以帧可以夹在 JSON 行甚至日志行中间,接收方在帧结束后继续拼接被打断的文本行;第二字节不是 `0xFE` 或长度非法时丢弃 `0xFF` 并重新同步。`seq` 为 0..255 循环计数,用于统计丢帧。

| type | 方向 | 负载 |
| --- | --- | --- |
| `0x02` | 设备 → Mac | 1~2 块 IMA ADPCM。每块 164 字节 = 4 字节头(int16 LE 预测值、uint8 步长索引、uint8 保留)+ 160 字节(320 个 4 bit 样本,低半字节在前)= 20 ms,16 kHz 单声道,块自包含。USB/Wi-Fi 共用字节流解帧,每帧 2 块;BLE 上由 Audio In 通知,每帧 1 块 |

开发分支不再提供或执行旧版 `approve`("1 + Enter")映射,旧设置会退回无动作;这不代表设备审批已经实现。
