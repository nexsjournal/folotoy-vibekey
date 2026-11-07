# 真机与主机预览共用一份 RGB565 像素数据，构建时展开为只读常量。
set(offline_art "${CMAKE_CURRENT_LIST_DIR}/offline-cat.rgb565")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${offline_art}")
file(READ "${offline_art}" offline_art_hex HEX)
string(REGEX REPLACE "(..)" "0x\\1," offline_art_hex "${offline_art_hex}")
string(REGEX REPLACE "(0x..,0x..,0x..,0x..,0x..,0x..,0x..,0x..,)" "\\1\n" offline_art_hex "${offline_art_hex}")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/ib_offline_art.inc" CONTENT "${offline_art_hex}")
