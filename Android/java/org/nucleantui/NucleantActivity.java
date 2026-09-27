package org.nucleantui;

import android.app.Activity;
import android.os.Bundle;
import android.view.Choreographer;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;


/**
 * The Activity a Nucleant app runs in.
 *
 * <p>Ships with NucleantApplication under a fixed package, the way
 * {@code org.libsdl.app.SDLActivity} does. An app does not generate or compile
 * any of this — ksproject emits a {@code MainActivity extends NucleantActivity}
 * whose whole body is {@link #startApp(String)}, and points the manifest at it.
 * Override any of the protected hooks to do more.
 *
 * <p>Startup is three steps. {@code System.loadLibrary} brings in
 * libNucleantMain.so — the app, its dependencies and the JNI bridge, linked
 * together by the Main Swift Package. {@link NucleantSurfaceView} hands over an
 * {@code android.view.Surface} as soon as one exists. Then
 * {@code nucleantRunMain} starts the app against it.
 *
 * <p>The order matters: the Swift side builds its Vulkan surface from the
 * window it is given, so the app is not started until a surface has arrived.
 */
public abstract class NucleantActivity extends Activity {

    static {
        // Order is load-bearing: the Swift runtime links libc++_shared, and
        // Android ships no system copy, so it has to be resolvable first.
        System.loadLibrary("c++_shared");
        System.loadLibrary("NucleantMain");
    }

    private NucleantSurfaceView surfaceView;
    private boolean started = false;
    private long lastFrameNanos = 0;

    /**
     * Copy the Swift packages' resource bundles out of the APK.
     *
     * <p>They are read by path rather than through {@link android.content.res.AssetManager} — the Swift side has no handle to one
     * — so they have to exist as real files. Unpacked into {@code getFilesDir()},
     * which is what {@code nucleantRunMain} is given and what the Swift code
     * resolves resources against.
     */
    private void unpackResources() {
        try {
            copyAssetTree("", getFilesDir());
        } catch (Exception e) {
            android.util.Log.e("nucleant", "unpacking resources failed", e);
        }
    }

    private void copyAssetTree(String path, java.io.File destRoot) throws Exception {
        String[] children = getAssets().list(path);
        if (children == null || children.length == 0) {
            // A leaf: list() returns empty for files.
            java.io.File out = new java.io.File(destRoot, path);
            java.io.File parent = out.getParentFile();
            if (parent != null) {
                parent.mkdirs();
            }
            try (java.io.InputStream in = getAssets().open(path);
                 java.io.OutputStream os = new java.io.FileOutputStream(out)) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
            }
            return;
        }
        for (String child : children) {
            String next = path.isEmpty() ? child : path + "/" + child;
            copyAssetTree(next, destRoot);
        }
    }

    /**
     * The frame source.
     *
     * <p>An ordinary Android render loop: ask Choreographer for the next
     * vsync, draw, ask again. Frames therefore arrive on the UI thread, which
     * is what the Swift renderer expects — it is the process main thread, and
     * the whole app now lives in this process rather than behind an
     * interpreter that needed a thread of its own.
     */
    private final Choreographer.FrameCallback frameCallback =
        new Choreographer.FrameCallback() {
            @Override
            public void doFrame(long frameTimeNanos) {
                if (!started) {
                    return;
                }
                double dt = lastFrameNanos == 0
                    ? 0.0
                    : (frameTimeNanos - lastFrameNanos) / 1_000_000_000.0;
                lastFrameNanos = frameTimeNanos;
                NucleantBridge.nucleantDrawFrame(dt);
                Choreographer.getInstance().postFrameCallback(this);
            }
        };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        unpackResources();

        surfaceView = new NucleantSurfaceView(this);
        setContentView(surfaceView);

        // Fullscreen, and no system bars.
        //
        // The app draws its own chrome — a navigation bar with a back button
        // of its own — so the status bar is not just redundant, it is in the
        // way: edge-to-edge is the default from API 35, and the app's top row
        // would otherwise render *underneath* the status bar. Visible, and
        // unpressable, because the system owns those pixels for touch.
        //
        // Hidden rather than inset around: insetting works, but it gives the
        // display's top and bottom strips away to bars the app has no use for.
        // The bars stay available on a swipe, which is what
        // BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE means.
        //
        // After setContentView, not before: the controller belongs to the
        // window's DecorView, and that does not exist until there is content
        // in it — asking earlier throws.
        WindowInsetsController insets = getWindow().getInsetsController();
        if (insets != null) {
            insets.hide(WindowInsets.Type.systemBars());
            insets.setSystemBarsBehavior(
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    /**
     * Start the app against the surface that now exists.
     *
     * <p>The one thing this class cannot do for itself: {@code nucleantRunMain}
     * is generated into the <em>app's</em> Swift target, and jextract emits Java
     * only for the module its plugin is attached to — so the class holding it is
     * named after that target and is not visible from here. The generated
     * {@code MainActivity} overrides this with a one-line call to it.
     *
     * @param appPath the unpacked asset directory, which is where the Swift side
     *     resolves resource bundles from.
     * @return the app's exit status; 0 on success.
     */
    protected abstract int startApp(String appPath);

    /**
     * Start the app, once, now that there is something to draw into.
     *
     * <p>Called on the UI thread and deliberately not moved off it: the Swift
     * entry point asserts main-actor isolation, and Android's UI thread is the
     * process main thread. It is safe to block the looper for the length of
     * this call because it returns as soon as the app has started — the render
     * loop runs on a thread of its own, driven by Choreographer.
     */
    void startAppIfNeeded() {
        if (started) {
            return;
        }
        started = true;
        // Before the app starts: the first layout needs it, and it is the one
        // display property that has to cross from Java.
        NucleantBridge.nucleantSetDisplayScale(
            getResources().getDisplayMetrics().density);
        startApp(getFilesDir().getAbsolutePath());
        // Only now: the callback checks `started`, and the first frame must
        // not land before the app has a window to draw into.
        Choreographer.getInstance().postFrameCallback(frameCallback);
        // onResume() has already been and gone by now — Android resumes the
        // Activity before it creates the surface — so the app missed it. Tell
        // it again, or the render loop is never started: the Swift side latches
        // "running" on the first active(1) and ignores later ones.
        NucleantBridge.nucleantOnResume();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Only once the app exists. The first onResume() of the process runs
        // before the surface — and therefore before the app — so forwarding it
        // then would latch the render loop's "running" flag with nothing to
        // draw; startAppIfNeeded() sends it instead.
        if (started) {
            NucleantBridge.nucleantOnResume();
            lastFrameNanos = 0;
            Choreographer.getInstance().postFrameCallback(frameCallback);
        }
    }

    @Override
    protected void onPause() {
        // Stop asking for frames. The callback re-posts itself, so nothing
        // else ends the loop — and a backgrounded app that keeps drawing is
        // not merely wasteful: Android kills a cached process for the binder
        // traffic it generates ("excessive binder traffic during cached").
        Choreographer.getInstance().removeFrameCallback(frameCallback);
        NucleantBridge.nucleantOnPause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        // Belt and braces: onPause always precedes onDestroy, but the flag is
        // what the callback itself checks, and this Activity's death must not
        // leave a frame request outstanding.
        started = false;
        Choreographer.getInstance().removeFrameCallback(frameCallback);
        NucleantBridge.nucleantOnDestroy();
        super.onDestroy();
    }
}
