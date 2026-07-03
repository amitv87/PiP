cmake_minimum_required(VERSION 3.13)

SET(CMAKE_BUILD_TYPE "Debug")
SET(CMAKE_BUILD_TYPE "Release")

set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0)

project(PiP)

add_compile_options(-fobjc-arc -Wno-deprecated-declarations -Wno-format)

set(frameworks AVFoundation Cocoa VideoToolbox AudioToolbox CoreMedia QuartzCore OpenGL Metal MetalKit PIP SkyLight ScreenCaptureKit)
list(TRANSFORM frameworks PREPEND "-framework ")

set(AIRPLAY_SUPPORT_ENABLED 1)

file(GLOB_RECURSE pip_src CONFIGURE_DEPENDS "pip/*.m")
add_executable(pip ${pip_src})
target_include_directories(pip PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  pip/priv_headers
)
target_link_libraries(pip PUBLIC -fobjc-link-runtime
  "-F /System/Library/PrivateFrameworks"
  "-F /System/Volumes/Data/Library/Developer/CommandLineTools/SDKs/MacOSX12.3.sdk/System/Library/Frameworks"
  ${frameworks}
)

if(${AIRPLAY_SUPPORT_ENABLED} EQUAL 1)
  enable_language(ASM)
  file(GLOB_RECURSE airplay_src CONFIGURE_DEPENDS "airplay*/*.c")
  # Test programs have their own main(); keep them out of the library.
  list(FILTER airplay_src EXCLUDE REGEX "airplay_sender/fpemu/test_fpemu\\.c$")
  list(FILTER airplay_src EXCLUDE REGEX "airplay_sender/test_mirror_crypto\\.c$")

  # FairPlay snapshot blob: extracted at build time from the doubletake source
  # (Apple's proprietary code — NEVER committed; see airplay_sender/fpemu/README.md).
  set(FPEMU_DIR ${CMAKE_CURRENT_SOURCE_DIR}/airplay_sender/fpemu)
  set(DOUBLETAKE_FPDATA
      "${CMAKE_CURRENT_SOURCE_DIR}/third_party/doubletake/internal/fpemu/fpexchange_data.go"
      CACHE FILEPATH "Path to doubletake fpexchange_data.go for FairPlay blob extraction")
  add_custom_command(
    OUTPUT ${FPEMU_DIR}/fp_blob.bin
    COMMAND python3 ${FPEMU_DIR}/extract_blob.py ${DOUBLETAKE_FPDATA} ${FPEMU_DIR}/fp_blob.bin
    DEPENDS ${FPEMU_DIR}/extract_blob.py
    COMMENT "Extracting FairPlay blob from ${DOUBLETAKE_FPDATA}"
    VERBATIM)
  # fp_blob.S does `.incbin "fp_blob.bin"`, so rebuild it when the blob changes.
  set_source_files_properties(${FPEMU_DIR}/fp_blob.S PROPERTIES
    OBJECT_DEPENDS ${FPEMU_DIR}/fp_blob.bin)

  add_library(airplay ${airplay_src} ${FPEMU_DIR}/fp_blob.S)
  # Give the assembler the include path so `.incbin "fp_blob.bin"` resolves.
  target_include_directories(airplay PRIVATE ${FPEMU_DIR})
  target_link_libraries(pip PUBLIC airplay)
  target_include_directories(pip PRIVATE airplay airplay_sender)
else()
  target_compile_definitions(pip PUBLIC NO_AIRPLAY)
endif()
