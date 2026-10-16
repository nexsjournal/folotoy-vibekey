cmake_minimum_required(VERSION 3.16)

# hello 消息里的 "ver" 取自应用描述;固定版本号,不随 git describe 变化。
set(PROJECT_VER "0.1.0")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(InputBetter-Passport)
