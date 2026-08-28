# This file is a part of media_kit (https://github.com/media-kit/media-kit).
# The OpenBubbles fork replaces opaque native downloads with pinned,
# independently verified native inputs.

cmake_minimum_required(VERSION 3.14)

option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)
option(
  MEDIA_KIT_NATIVE_MEDIA_OFFLINE
  "Refuse network access while resolving the pinned libmpv archive."
  OFF
)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

if(
  CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64"
  OR CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64"
  OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$"
)
  set(MEDIA_KIT_NATIVE_ARCH "arm64")
elseif(
  CMAKE_GENERATOR_PLATFORM STREQUAL "x64"
  OR CMAKE_VS_PLATFORM_NAME STREQUAL "x64"
  OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64|X86_64)$"
)
  set(MEDIA_KIT_NATIVE_ARCH "x64")
else()
  message(
    FATAL_ERROR
    "media_kit_libs_windows_video supports only Windows x64 and ARM64. "
    "Generator platform='${CMAKE_GENERATOR_PLATFORM}', "
    "VS platform='${CMAKE_VS_PLATFORM_NAME}', "
    "system processor='${CMAKE_SYSTEM_PROCESSOR}'."
  )
endif()

set(
  MEDIA_KIT_OFFICIAL_ANGLE_ROOT
  ""
  CACHE PATH
  "Path to a verified official-source ANGLE bundle."
)
set(
  MEDIA_KIT_LIBMPV_ARCHIVE
  ""
  CACHE FILEPATH
  "Optional offline path to the pinned libmpv archive."
)
if(NOT MEDIA_KIT_LIBMPV_ARCHIVE AND DEFINED ENV{MEDIA_KIT_LIBMPV_ARCHIVE})
  set(MEDIA_KIT_LIBMPV_ARCHIVE "$ENV{MEDIA_KIT_LIBMPV_ARCHIVE}")
endif()

if(NOT MEDIA_KIT_OFFICIAL_ANGLE_ROOT)
  if(DEFINED ENV{MEDIA_KIT_OFFICIAL_ANGLE_ROOT})
    set(MEDIA_KIT_OFFICIAL_ANGLE_ROOT "$ENV{MEDIA_KIT_OFFICIAL_ANGLE_ROOT}")
  else()
    set(
      MEDIA_KIT_OFFICIAL_ANGLE_ROOT
      "${CMAKE_CURRENT_SOURCE_DIR}/native/${MEDIA_KIT_NATIVE_ARCH}/angle"
    )
  endif()
endif()

find_program(MEDIA_KIT_POWERSHELL NAMES pwsh REQUIRED)
set(
  MEDIA_KIT_NATIVE_CACHE
  "${CMAKE_BINARY_DIR}/obnm/${MEDIA_KIT_NATIVE_ARCH}"
)
set(
  MEDIA_KIT_GENERATED_CMAKE
  "${MEDIA_KIT_NATIVE_CACHE}/native-media.cmake"
)
set(
  MEDIA_KIT_RESOLUTION_JSON
  "${MEDIA_KIT_NATIVE_CACHE}/native-media-resolution.json"
)

set(
  MEDIA_KIT_PREPARE_COMMAND
  "${MEDIA_KIT_POWERSHELL}"
  -NoLogo
  -NoProfile
  -NonInteractive
  -ExecutionPolicy
  Bypass
  -File
  "${CMAKE_CURRENT_SOURCE_DIR}/../tool/prepare_native_media.ps1"
  -Architecture
  "${MEDIA_KIT_NATIVE_ARCH}"
  -AngleBundleRoot
  "${MEDIA_KIT_OFFICIAL_ANGLE_ROOT}"
  -CacheRoot
  "${MEDIA_KIT_NATIVE_CACHE}"
  -GeneratedCmakePath
  "${MEDIA_KIT_GENERATED_CMAKE}"
  -CompatibilityRoot
  "${CMAKE_BINARY_DIR}"
  -ResolutionPath
  "${MEDIA_KIT_RESOLUTION_JSON}"
)
if(MEDIA_KIT_LIBMPV_ARCHIVE)
  list(
    APPEND MEDIA_KIT_PREPARE_COMMAND
    -LibmpvArchivePath
    "${MEDIA_KIT_LIBMPV_ARCHIVE}"
  )
endif()
if(MEDIA_KIT_NATIVE_MEDIA_OFFLINE)
  list(APPEND MEDIA_KIT_PREPARE_COMMAND -Offline)
endif()

execute_process(
  COMMAND ${MEDIA_KIT_PREPARE_COMMAND}
  RESULT_VARIABLE MEDIA_KIT_PREPARE_RESULT
  OUTPUT_VARIABLE MEDIA_KIT_PREPARE_OUTPUT
  ERROR_VARIABLE MEDIA_KIT_PREPARE_ERROR
  COMMAND_ECHO STDOUT
)
if(NOT MEDIA_KIT_PREPARE_RESULT EQUAL 0)
  message(
    FATAL_ERROR
    "Native media verification failed closed.\n"
    "stdout:\n${MEDIA_KIT_PREPARE_OUTPUT}\n"
    "stderr:\n${MEDIA_KIT_PREPARE_ERROR}"
  )
endif()
if(NOT EXISTS "${MEDIA_KIT_GENERATED_CMAKE}")
  message(FATAL_ERROR "Native media verifier did not generate its CMake input.")
endif()
include("${MEDIA_KIT_GENERATED_CMAKE}")

set(
  MEDIA_KIT_NATIVE_MEDIA_PROVENANCE
  "${CMAKE_CURRENT_SOURCE_DIR}/../provenance/native-dependencies.json"
)
set(
  MEDIA_KIT_NATIVE_MEDIA_NOTICES
  "${CMAKE_CURRENT_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
)
set(
  MEDIA_KIT_NATIVE_MEDIA_ANGLE_LICENSES
  "${MEDIA_KIT_OFFICIAL_ANGLE_ROOT}/licenses"
)
set(
  MEDIA_KIT_NATIVE_MEDIA_PORTABLE_EVIDENCE_FILES
  "${MEDIA_KIT_NATIVE_MEDIA_PACKAGE_EVIDENCE}"
  "${MEDIA_KIT_NATIVE_MEDIA_ANGLE_MANIFEST}"
  "${MEDIA_KIT_NATIVE_MEDIA_LIBMPV_MANIFEST}"
  "${MEDIA_KIT_NATIVE_MEDIA_PROVENANCE}"
  "${MEDIA_KIT_NATIVE_MEDIA_NOTICES}"
)
foreach(
  MEDIA_KIT_NATIVE_MEDIA_REQUIRED_FILE
  IN LISTS MEDIA_KIT_NATIVE_MEDIA_PORTABLE_EVIDENCE_FILES
)
  if(NOT EXISTS "${MEDIA_KIT_NATIVE_MEDIA_REQUIRED_FILE}")
    message(
      FATAL_ERROR
      "Required native-media package evidence is missing: "
      "${MEDIA_KIT_NATIVE_MEDIA_REQUIRED_FILE}"
    )
  endif()
endforeach()
if(NOT IS_DIRECTORY "${MEDIA_KIT_NATIVE_MEDIA_ANGLE_LICENSES}")
  message(
    FATAL_ERROR
    "Required ANGLE license inventory is missing: "
    "${MEDIA_KIT_NATIVE_MEDIA_ANGLE_LICENSES}"
  )
endif()

set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")
add_library(
  ${PLUGIN_NAME}
  SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(
  ${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${MEDIA_KIT_LIBMPV_DLL}"
  ${MEDIA_KIT_ANGLE_RUNTIME_LIBRARIES}
  PARENT_SCOPE
)
set(
  media_kit_libs_windows_video_portable_evidence_files
  ${MEDIA_KIT_NATIVE_MEDIA_PORTABLE_EVIDENCE_FILES}
  PARENT_SCOPE
)
set(
  media_kit_libs_windows_video_angle_license_directory
  "${MEDIA_KIT_NATIVE_MEDIA_ANGLE_LICENSES}"
  PARENT_SCOPE
)
