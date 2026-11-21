cmake_minimum_required(VERSION 3.22)
project(raildev VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL3 REQUIRED IMPORTED_TARGET sdl3)
pkg_check_modules(SDL3_TTF REQUIRED IMPORTED_TARGET sdl3-ttf)
pkg_check_modules(SDL3_IMAGE REQUIRED IMPORTED_TARGET sdl3-image)

include(FetchContent)
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG        v1.91.8
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(imgui)

add_library(imgui_sdl3 STATIC
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_demo.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdl3.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_sdlrenderer3.cpp
)
target_include_directories(imgui_sdl3 PUBLIC
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
)
target_link_libraries(imgui_sdl3 PUBLIC PkgConfig::SDL3)

add_library(raildev_core STATIC
    src/core/Camera2D.cpp
    src/core/SimClock.cpp
    src/map/CityFootprint.cpp
    src/map/EuropeMap.cpp
    src/map/EuropeData.cpp
    src/track/TrackGraph.cpp
)
target_include_directories(raildev_core PUBLIC src)
target_compile_options(raildev_core PRIVATE -Wall -Wextra -Wpedantic)

add_executable(raildev
    src/main.cpp
    src/ui/MapRenderer.cpp
    src/ui/HudOverlay.cpp
)
target_include_directories(raildev PRIVATE src)
target_compile_options(raildev PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(raildev PRIVATE
    raildev_core
    imgui_sdl3
    PkgConfig::SDL3
    PkgConfig::SDL3_TTF
    PkgConfig::SDL3_IMAGE
)

enable_testing()
add_executable(raildev_tests
    tests/test_core.cpp
)
target_include_directories(raildev_tests PRIVATE src)
target_compile_options(raildev_tests PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(raildev_tests PRIVATE raildev_core)
add_test(NAME raildev_unit_tests COMMAND raildev_tests)

add_executable(export_map
    src/tools/export_map.cpp
)
target_include_directories(export_map PRIVATE src)
target_compile_options(export_map PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(export_map PRIVATE raildev_core)
