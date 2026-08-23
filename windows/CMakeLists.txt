cmake_minimum_required(VERSION 3.14)
project(bluebubbles_app LANGUAGES CXX)

set(BINARY_NAME "bluebubbles_app")

# CMake reports the ARM64 host processor even when Visual Studio is generating
# an x64 target. Plugins such as ObjectBox use CMAKE_SYSTEM_PROCESSOR to select
# their runtime archive, so normalize it to the requested generator platform.
if(CMAKE_GENERATOR_PLATFORM STREQUAL "x64")
  set(CMAKE_SYSTEM_PROCESSOR "AMD64")
endif()

cmake_policy(SET CMP0063 NEW)

set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Configure build options.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()

set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")

# Flutter library and tool build rules.
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build
add_subdirectory("runner")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# media_kit_libs_windows_video 1.0.10 bundles an isolated debug-runtime
# cluster from its ANGLE archive. None of these files is imported by libmpv,
# ANGLE, the media plugins, or the runner, and the debug files depend on the
# non-redistributable MSVCP140D runtime. Keep them out of release bundles.
set(OPENBUBBLES_UNUSED_MEDIA_RUNTIME_NAMES
  "libc++.dll"
  "zlib.dll"
  "ucrtbased.dll"
  "vccorlib140d.dll"
  "vcruntime140d.dll"
  "vcruntime140_1d.dll"
)
foreach(BUNDLED_LIBRARY IN LISTS PLUGIN_BUNDLED_LIBRARIES)
  get_filename_component(BUNDLED_LIBRARY_NAME "${BUNDLED_LIBRARY}" NAME)
  if(BUNDLED_LIBRARY_NAME IN_LIST OPENBUBBLES_UNUSED_MEDIA_RUNTIME_NAMES)
    list(REMOVE_ITEM PLUGIN_BUNDLED_LIBRARIES "${BUNDLED_LIBRARY}")
  endif()
endforeach()

# The desktop OAuth and in-app WebView plugins link WebView2Loader.dll through
# NuGet targets, but neither declares it as a Flutter bundled library. The
# post-build copy reaches the normal runner directory but not an explicit
# install/package prefix, so add the target-architecture loader directly.
string(TOLOWER "${CMAKE_GENERATOR_PLATFORM}" WEBVIEW2_ARCH_DIRECTORY)
list(APPEND PLUGIN_BUNDLED_LIBRARIES
  "${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/${WEBVIEW2_ARCH_DIRECTORY}/WebView2Loader.dll"
)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
# CMake 3.31 can leave INITIALIZED_TO_DEFAULT false while retaining this
# generated Visual Studio default. Treat only that exact path as the default;
# preserve any explicit custom install prefix.
if(
  CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT
  OR CMAKE_INSTALL_PREFIX STREQUAL "C:/Program Files/${PROJECT_NAME}"
)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

if(
  NOT media_kit_libs_windows_video_portable_evidence_files
  OR NOT media_kit_libs_windows_video_angle_license_directory
)
  message(
    FATAL_ERROR
    "The local architecture-aware media package did not expose its required "
    "portable provenance and license inventory."
  )
endif()
install(
  FILES ${media_kit_libs_windows_video_portable_evidence_files}
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/native-media"
  COMPONENT Runtime
)
install(
  DIRECTORY "${media_kit_libs_windows_video_angle_license_directory}/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/native-media/angle-licenses"
  COMPONENT Runtime
)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
