cmake_minimum_required(VERSION 3.13)

project(PiP)

add_compile_options(-fobjc-arc -Wno-deprecated-declarations -Wno-format)

set(frameworks Cocoa VideoToolbox AudioToolbox CoreMedia QuartzCore OpenGL Metal MetalKit PIP SkyLight)
list(TRANSFORM frameworks PREPEND "-framework ")

set(AIRPLAY_SUPPORT_ENABLED 1)

file(GLOB_RECURSE pip_src CONFIGURE_DEPENDS "pip/*.m")
add_executable(pip ${pip_src})
target_include_directories(pip PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(pip PUBLIC -fobjc-link-runtime "-F /System/Library/PrivateFrameworks" ${frameworks})

if(${AIRPLAY_SUPPORT_ENABLED} EQUAL 1)
  file(GLOB_RECURSE airplay_src CONFIGURE_DEPENDS "airplay/*.c")
  add_library(airplay ${airplay_src})
  target_link_libraries(pip PUBLIC airplay)
  target_include_directories(pip PRIVATE airplay)
else()
  target_compile_definitions(pip PUBLIC NO_AIRPLAY)
endif()
