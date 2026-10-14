# Private Android x64 qualification; no ARM translation or architecture spoofing.
set(ANDROID_ABI "x86_64" CACHE STRING "" FORCE)
set(ANDROID_PLATFORM "android-24" CACHE STRING "" FORCE)
include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")
