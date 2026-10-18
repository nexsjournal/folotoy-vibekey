# dmgbuild 配置(release.sh 调用):安装窗口的大小、背景、图标位置。
#   dmgbuild -s scripts/dmg/settings.py -D app=<InputBetter.app> -D background=<background.tiff> "<卷名>" <输出.dmg>
# 图标中心坐标必须与 background.swift 的 appCenter / applicationsCenter 一致。
# Finder 会忽略 .DS_Store 里的路径栏设置而沿用用户自己的偏好,所以背景底部不放任何内容。
import os.path

application = defines["app"]  # noqa: F821  (dmgbuild 注入 defines)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
# 卷图标用 app 自己的图标
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (600, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    appname: (160, 160),
    "Applications": (440, 160),
}
hide_extensions = [appname]
