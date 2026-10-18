# InputBetter Passport 协议 v1

Passport 固件(`firmware/`)与 InputBetter macOS app(`app/`)之间的通信协议。设备是"瘦终端":所有状态由 Mac 决定,设备只上报按键、渲染 Mac 下发的状态,并在需要时推送麦克风音频。

## 链路

| 链路 | 设备侧 | Mac 侧 |
| --- | --- | --- |
| USB | ESP32-C3 USB Serial/JTAG(CDC) | `/dev/cu.usbmodem*`,VID `0x303A`;115200 raw、`TIOCEXCL`、关 HUPCL;打开后先清 RTS 再清 DTR(避免复位芯片) |
| BLE | NimBLE GATT 外设,广播名 `InputBetter`,无配对 | CoreBluetooth central |

USB 与 ESP-IDF 日志共用通道:Mac 只从 `{"t":` 处开始解析一行,其余内容忽略。USB 优先,检测到 USB 设备握手成功后断开 BLE;USB 断开后回到 BLE 扫描。

BLE GATT:

| 项 | UUID | 属性 |
| --- | --- | --- |
| Service | `B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Primary,UUID 放在广播包里 |
| Events(设备 → Mac,JSON 行) | `B5E10002-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Notify |
| Commands(Mac → 设备,JSON 行) | `B5E10003-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Write / Write Without Response |
| Audio In(设备 → Mac,二进制帧) | `B5E10004-5A6C-4E8B-9F2D-7C3A1E0B4D21` | Notify |

一次写入/通知可能只包含半行,两端都按 `\n` 重新组帧。

## 文本消息

JSON Lines:每条消息是一行扁平 UTF-8 JSON 对象,以 `\n` 结尾,单行最长 511 字节。设备只解析扁平对象:字符串值、非负整数值;未知字段忽略,未知命令整条丢弃。设备屏幕只显示 ASCII,`msg`、`engine`、`app` 等字段由 Mac 先转成 ASCII,最长 23 字节。

### 设备 → Mac

| 类型 | 示例 | 说明 |
| --- | --- | --- |
| hello | `{"t":"hello","fw":"inputbetter","proto":1,"ver":"0.1.0","build":"a506a8bb","boot":"9f3a21c4"}` | 回复 `hello` 命令。`build` 是固件 ELF 文件 SHA-256 的前 8 位小写十六进制(esptool 把它写进镜像,设备用 `esp_app_get_elf_sha256()` 读出),等于 `shasum -a 256 firmware/build/InputBetter-Passport.elf` 的前 8 位,也等于 `InputBetter-Passport.bin` 文件偏移 `0xB0` 起 4 个字节的十六进制;Mac 用它判断设备固件是否与官网最新固件(`/firmware/manifest.json` 的 `build`)一致 |
| key | `{"t":"key","k":"ok","e":"down","seq":12,"boot":"9f3a21c4"}` | 按键原始事件。`k`:`ok`/`up`/`down`;`e`:`down`(按下瞬间)/`up`(松开)/`long`(按住 1 秒)。该次按压用于关闭 agent 通知时附加 `"ack":1`(同一次按压的 down/up/long 都带) |
| bat | `{"t":"bat","soc":87,"mv":4012,"chg":0}` | `hello` 之后及每 60 秒;读不到为 `-1`;`chg` 是否在充电(读不到为 0) |
| pong | `{"t":"pong"}` | 回复 `ping` |

- `seq` 本次上电后单调递增;`boot` 是每次上电随机生成的 8 位十六进制。Mac 用 `(boot, seq)` 去重。
- 设备只在 Mac 在线时发送 `key`。Mac 离线时设备显示时钟,按键只用于点亮屏幕;熄屏时的那次按压只点亮屏幕,不上报。
- `chg`:板子没有充电状态引脚,固件按"USB 主机在线且电量 < 100"推断。
- 在线状态按链路分别记录:任一合法命令都会让该链路在线;Mac 不发 `bye` 直接断开 BLE 时,只要 USB 还在通信,设备保持在线。
- BLE 音频帧 170 字节且不拆包,MTU 需 ≥ 173(macOS 默认协商结果满足)。

### Mac → 设备

| 命令 | 示例 | 设备行为 |
| --- | --- | --- |
| hello | `{"cmd":"hello"}` | 回复 `hello` + `bat`,链路标记为在线 |
| ping | `{"cmd":"ping"}` | 回复 `pong`。Mac 每 5 秒发送;设备 15 秒没收到任何命令即视为离线 |
| bye | `{"cmd":"bye"}` | Mac 退出前发送,设备立即显示离线 |
| config | `{"cmd":"config","mic":1,"engine":"Whisper Turbo","screen_off":60,"clock":1789097696,"sound":1}` | `mic`:1 表示听写音源是 Passport 麦克风(OK 键按下的瞬间设备就开始推送音频,不用等 `mic` 命令);`engine`:主页底部显示的引擎名;`screen_off`:空闲多少秒熄屏,0 为永不;`clock`:Mac 本地时间(Unix 秒 + 时区偏移);`sound`:开始/结束提示音。字段都可选 |
| state | `{"cmd":"state","st":"rec","mode":"dict","msg":""}` | 切换设备界面。`st` 见下表;`mode`:`dict`(听写)/`tr`(翻译听写)/`sub`(字幕);`msg`:可选短文本(如 `Copied`、`No input`、应用名) |
| level | `{"cmd":"level","v":42}` | 0..100 的音量电平,`rec`/`sub` 状态下 Mac 约每 60 ms 发送一次,驱动动画 |
| mic | `{"cmd":"mic","on":1}` | 开/关麦克风上行。链路断开(bye、超时、拔线)时设备自动停止 |
| keys | `{"cmd":"keys","up":"enter","down":"esc","ok":"mic"}` | 屏幕右侧、贴着三个实体键显示的提示**图标**,值为图标 id(ASCII,区分大小写),随模式与用户映射变化;字段可选(没出现的键保持不变),空字符串或未知 id 隐藏该键的提示(不会让整条命令失效)。固定 id 集合:`enter`(回车)、`esc`(Esc)、`undo`(撤销)、`stab`(Shift-Tab)、`tab`(Tab)、`send`(⌘↩ 发送)、`stop`(停止)、`cancel`(取消)、`check`(确认)、`repeat`(重来)、`mode`(切换模式)、`apps`(应用切换器)、`mic`(说话)、`translate`(翻译)、`hide`(隐藏)、`up` / `down`(上 / 下移动)、`play`(开始)、`open`(打开)、`bksp`(⌫ 退格)、`del`(⌦ 向后删除)。旧固件不认识 `bksp` / `del`,会隐藏该提示。图标来自 Material Icons Round(`del` 由 backspace 水平镜像派生) |
| agent | `{"cmd":"agent","ev":"done","msg":"Claude Code"}` | 编程 Agent 通知(vibe coding):`ev` 为 `done`(任务完成)/ `input`(等待你确认或输入)/ `clear`(撤销通知);`msg` 为来源名。设备弹出全屏通知层并播放提示音(`input` 每 20 秒提醒一次),任意键或 `clear` 关闭;关闭通知的这次按键**不**再触发其他动作,但仍上报 `key` 事件,`ev` 字段附加 `"ack":1` |

| list | `{"cmd":"list","title":"SWITCH APP","sel":2,"n":7,"top":0,"i0":"Ghostty","i1":"Chrome","i2":"Xcode","i3":"Finder","i4":"Mail","i5":"Notes"}` | 列表页内容(如应用切换器),选中项由 Mac 维护,设备只显示。`n`(总项数)与 `sel`(选中项绝对序号)必填,均为 0..65535,`n>0` 时要求 `sel<n`、`top<n`,否则整条丢弃;`top` 为 `i0` 在完整列表里的序号(缺省 0,用于滚动条);`title` 可选;`i0`..`i5` 为最多 6 个可见行(ASCII,最长 23 字节,可缺行),`i6` 及以后忽略。每次选中或滚动变化都重发整条 |

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

握手成功后 Mac 立即下发 `config` 和当前 `state`;之后状态变化时下发 `state`,设置变化时下发 `config`,每 5 分钟重发 `config` 校准时钟。

### 按键语义(由 Mac 解释,默认"Vibe Coding"映射,上下键动作可在 Mac 设置里改)

| 按键 | idle(dict / tr) | rec | sub 模式 / 字幕运行中 |
| --- | --- | --- | --- |
| OK down/up | 按住超过 300 ms 为按住说话(松开结束);短按为开始(再短按结束) | 结束 | 开始 / 停止字幕 |
| up 短按 | 回车(发送 prompt) | — | 开关本场字幕的翻译(与字幕条「译」菜单同一开关) |
| down 短按 | Esc(打断 Agent) | — | 收起 / 展开 Mac 上的字幕条(字幕条就是底部状态条的展开形态) |
| up long | 切换模式 dict → tr → sub(循环) | — | 切换模式 |
| down long | 默认打开「切换应用」列表(可在 设置 › Passport › 按键 改成其他动作) | 取消本次录音 | — |

模式 `sub` 下按 OK 开始字幕,字幕应用为 Mac 设置里最后选择的应用。设备收到 `agent` 通知时,第一次按键只用于关闭通知(上报的 `key` 带 `"ack":1`,Mac 忽略其动作)。**录音中**通知只显示为顶部横幅、不拦截按键(否则松开 OK 结束录音会被当成关闭通知);离开录音页后横幅转为全屏通知层,下一次按键才带 ack 关闭它。

设备端麦克风时序(config `mic=1`):在线、IDLE 或 SUB 页且非 sub 模式时 OK 按下立即开麦;收到 `mic on:0`、state 变为 done/err、本地开麦 600 ms 后仍收到 idle / sub、2 秒内没收到 `rec`、或该链路断开时停止。rec → proc 时继续推流,等 `mic on:0`(Mac 要录完尾音),最多 500 ms。`mic on:1` 在发命令的链路上开麦。

`sub` 状态:Mac 只要在运行字幕(且没在听写、没打开列表)就发 `sub`,`mode` 为设备当前模式(不一定是 `sub`);按键含义按 `mode` 区分,由 `keys` 命令给出对应的提示图标。done / err 自动返回时,设备回到最近一次 idle / sub 的页面、模式和 `msg`。

## 二进制帧

帧头 6 字节 `FF FE type seq len_lo len_hi`,后跟 `len`(1..1024)字节负载。`0xFF`/`0xFE` 不会出现在 UTF-8 文本中,所以帧可以夹在 JSON 行甚至日志行中间,接收方在帧结束后继续拼接被打断的文本行;第二字节不是 `0xFE` 或长度非法时丢弃 `0xFF` 并重新同步。`seq` 为 0..255 循环计数,用于统计丢帧。

| type | 方向 | 负载 |
| --- | --- | --- |
| `0x02` | 设备 → Mac | 1~2 块 IMA ADPCM。每块 164 字节 = 4 字节头(int16 LE 预测值、uint8 步长索引、uint8 保留)+ 160 字节(320 个 4 bit 样本,低半字节在前)= 20 ms,16 kHz 单声道,块自包含。USB 上混在串口字节流里,每帧 2 块;BLE 上由 Audio In 通知,每帧 1 块 |
