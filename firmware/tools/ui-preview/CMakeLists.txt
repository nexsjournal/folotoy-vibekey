# tools/ui-preview: 在 macOS 上离屏渲染 Passport 屏幕并导出 PNG,用于审阅 / 迭代界面设计。
#
# - LVGL:直接编译固件同一份 managed_components/lvgl__lvgl(9.5.0),配置取自固件的 sdkconfig.h
#   (见 shim/preview_kconfig.h),字体、颜色深度与真机一致。
# - 界面代码:原样编译 firmware/main 的 ib_ui*.c、ib_icons.c 与 icons/ib_icon_font_22.c,不做任何修改;
#   只用 shim/ 里的极小替身代替 bsp_display.h(LVGL 锁)、esp_log.h、esp_err.h。
# - PNG:third_party/stb_image_write.h(nothings/stb 提交 2c980bb59875b0d32144a71867fbdebb2f77cd20,
#   v1.16,public domain / MIT 双许可,许可证见文件末尾)。
# 用法见 run.sh。
cmake_minimum_required(VERSION 3.16)
project(ib_ui_preview C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

get_filename_component(FW_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(LVGL_DIR "${FW_DIR}/managed_components/lvgl__lvgl")
set(SDKCONFIG_DIR "${FW_DIR}/build/config")
set(UI_DIR "${FW_DIR}/main")

if(NOT EXISTS "${LVGL_DIR}/lvgl.h")
    message(FATAL_ERROR "找不到 ${LVGL_DIR};先在 firmware/ 下执行一次 idf.py build(或 reconfigure)拉取依赖")
endif()
if(NOT EXISTS "${SDKCONFIG_DIR}/sdkconfig.h")
    message(FATAL_ERROR "找不到 ${SDKCONFIG_DIR}/sdkconfig.h;先在 firmware/ 下执行一次 idf.py build")
endif()

# ---- LVGL(主机静态库)----
file(GLOB_RECURSE LVGL_SOURCES CONFIGURE_DEPENDS "${LVGL_DIR}/src/*.c")
add_library(lvgl_host STATIC ${LVGL_SOURCES})
target_include_directories(lvgl_host PUBLIC
    "${LVGL_DIR}"
    "${LVGL_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/shim"
    "${SDKCONFIG_DIR}")
target_compile_definitions(lvgl_host PUBLIC
    LV_CONF_KCONFIG_EXTERNAL_INCLUDE="preview_kconfig.h"
    LV_LVGL_H_INCLUDE_SIMPLE)
target_compile_options(lvgl_host PRIVATE -w -O2)   # 第三方代码:不在这里追究告警

# ---- 固件界面代码 + 预览驱动 ----
set(UI_SOURCES
    "${UI_DIR}/ib_ui.c"
    "${UI_DIR}/ib_ui_gfx.c"
    "${UI_DIR}/ib_ui_statusbar.c"
    "${UI_DIR}/ib_ui_hints.c"
    "${UI_DIR}/ib_ui_agent.c"
    "${UI_DIR}/ib_ui_offline.c"
    "${UI_DIR}/ib_ui_idle.c"
    "${UI_DIR}/ib_ui_rec.c"
    "${UI_DIR}/ib_ui_proc.c"
    "${UI_DIR}/ib_ui_done.c"
    "${UI_DIR}/ib_ui_err.c"
    "${UI_DIR}/ib_ui_sub.c"
    "${UI_DIR}/ib_ui_list.c"
    "${UI_DIR}/ib_icons.c"
    "${UI_DIR}/icons/ib_icon_font_22.c"
    "${UI_DIR}/icons/ib_icon_font_56.c")

add_executable(ib_ui_preview
    preview_host.c
    preview_scenarios.c
    preview_main.c
    ${UI_SOURCES})
target_include_directories(ib_ui_preview PRIVATE
    "${UI_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_link_libraries(ib_ui_preview PRIVATE lvgl_host m)
target_compile_options(ib_ui_preview PRIVATE -Wall -Wextra -O1)
# 固件代码按 gcc 编写;clang 额外的这两类提示不影响行为,单独关掉,其余告警照常显示。
target_compile_options(ib_ui_preview PRIVATE -Wno-missing-field-initializers -Wno-unused-parameter)
