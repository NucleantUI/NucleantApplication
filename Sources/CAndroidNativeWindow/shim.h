#pragma once

// ANativeWindow_fromSurface + the ANativeWindow accessors. Pulled in through a
// module map rather than a compiled target: these are NDK headers, already
// present in the Swift Android SDK's sysroot, and libandroid.so is linked
// below.
#include <android/native_window.h>
#include <android/native_window_jni.h>
