//
//  Thread.swift
//  Dispatch (WebAssembly)
//
//  WASI's Foundation leaves `Thread` out: a wasm32-wasip1 module runs on the
//  page's one thread. This answers the question code written for the other
//  platforms asks of it before reaching for `DispatchQueue.main` — "am I on
//  the main thread?" — for that one thread.
//
#if os(WASI)

public enum Thread {
    public static var isMainThread: Bool { true }
}
#endif
