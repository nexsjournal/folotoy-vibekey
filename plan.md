这款软件的名称叫做InputBetter
可以参考如下项目:
https://github.com/opennookorg/betterwispr
https://github.com/isecret/MemoEcho
第一次进入这个软件的时候,设置麦克风和辅助输入的权限,然后是选择模型(apple speech,SenseVoice,wishper相关模型，暂不支持在线asr模型)然后下载,然后是设置说话输入的快捷键和LLM翻译相关的API和模型
核心功能：
1、按下快捷键转录麦克风声音，然后输入到当前用户聚焦的输入框 (可以使用/Users/xiaoyi/dev/passport-keys中硬件作为操作输入设备，我会插上这个设备，硬件上的交互界面你来设计)
2、选择某个窗口，然后转录这个窗口的声音，像字幕一样显示（比如选择chrome，chrome里面正在播放youtueb，就在屏幕下显示一个实时半透明的字幕条，可以拖动）
要求：
1、界面简洁，交互设置都简单
2、转录文字准确，性能好