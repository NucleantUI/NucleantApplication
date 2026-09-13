#pragma once

// AChoreographer is Android's vsync callback — the counterpart of
// CADisplayLink on Apple platforms — and ALooper is the queue it delivers on.
// Neither is exposed by the Swift Android SDK's `Android` module, which covers
// bionic (dlfcn, pthreads, ...) rather than the platform APIs in libandroid.
#include <android/choreographer.h>
#include <android/looper.h>
