package org.nucleantui;

import android.app.Activity;
import android.content.res.Configuration;
import android.os.Build;
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

    // AndroidSurfaceHost.ActivityState, as nucleantSetActivityState takes it.
    private static final int ACTIVITY_STOPPED = 0;
    private static final int ACTIVITY_STARTED = 1;
    private static final int ACTIVITY_RESUMED = 2;

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
                // The frame may have moved the keys to or from a text field:
                // the soft keyboard follows. Asked rather than told — see
                // NucleantSurfaceView.setTextInputKind.
                surfaceView.setTextInputKind(NucleantBridge.nucleantTextInputKind());
                // And the screen on top may want the system bars otherwise.
                followSystemBars();
                Choreographer.getInstance().postFrameCallback(this);
            }
        };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Before the app starts, so its first frame is already in the right
        // scheme.
        NucleantBridge.nucleantSetNightMode(isNightMode(getResources().getConfiguration()));

        unpackResources();

        surfaceView = new NucleantSurfaceView(this);
        setContentView(surfaceView);

        // Below API 30 (R) there is none of what follows: no insets by type,
        // no insets controller. There the window stays where the system puts
        // it, between its bars, the app is told no safe area and no keyboard
        // height, and the bars stay shown whatever it asks.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return;
        }

        // The window keeps its size whatever covers it (the system bars, the
        // display cutout, the soft keyboard). The surface view is told what
        // does, from the window's insets, and the app lays itself out clear
        // of it. Edge to edge is the default from API 35; asked for here so
        // API 30 to 34 do the same. ADJUST_RESIZE is what reports the
        // keyboard as an inset, rather than panning the window up under it.
        getWindow().setDecorFitsSystemWindows(false);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);

        // The system bars are shown, over the window's edges, and the app
        // lays itself out clear of them. It hides them when it asks — see
        // followSystemBars. A hidden bar comes back for a moment on a swipe in
        // from the edge, which is what BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        // means.
        //
        // After setContentView, not before: the controller belongs to the
        // window's DecorView, and that does not exist until there is content
        // in it — asking earlier throws.
        WindowInsetsController insets = getWindow().getInsetsController();
        if (insets != null) {
            insets.setSystemBarsBehavior(
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    /** Whether the bars have been set from what the app asks yet. */
    private boolean systemBarsSet = false;
    private boolean statusBarHidden = false;
    private boolean navigationBarHidden = false;
    private boolean lightSystemBars = false;

    /**
     * Hide or show the status bar and the navigation bar as the app asks,
     * with icons drawn for the window under them: dark over a light one.
     *
     * <p>Asked after every frame, like the soft keyboard, and changed only
     * when the answer is new. The first answer is applied whole, whatever the
     * theme started the bars as. Nothing below API 30 (see onCreate): the
     * bars stay as the system has them.
     */
    private void followSystemBars() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return;
        }
        boolean statusBar = NucleantBridge.nucleantStatusBarHidden();
        boolean navigationBar = NucleantBridge.nucleantNavigationBarHidden();
        boolean light = NucleantBridge.nucleantLightSystemBars();
        if (systemBarsSet && statusBar == statusBarHidden
                && navigationBar == navigationBarHidden && light == lightSystemBars) {
            return;
        }
        WindowInsetsController controller = getWindow().getInsetsController();
        if (controller == null) {
            return;
        }
        if (!systemBarsSet || statusBar != statusBarHidden) {
            if (statusBar) {
                controller.hide(WindowInsets.Type.statusBars());
            } else {
                controller.show(WindowInsets.Type.statusBars());
            }
        }
        if (!systemBarsSet || navigationBar != navigationBarHidden) {
            if (navigationBar) {
                controller.hide(WindowInsets.Type.navigationBars());
            } else {
                controller.show(WindowInsets.Type.navigationBars());
            }
        }
        if (!systemBarsSet || light != lightSystemBars) {
            int lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            controller.setSystemBarsAppearance(light ? lightBars : 0, lightBars);
        }
        systemBarsSet = true;
        statusBarHidden = statusBar;
        navigationBarHidden = navigationBar;
        lightSystemBars = light;
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

    /**
     * Dark mode switched, among other things. The manifest lists {@code uiMode}
     * in {@code configChanges}, so the Activity is told rather than recreated.
     */
    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        NucleantBridge.nucleantSetNightMode(isNightMode(newConfig));
    }

    private static boolean isNightMode(Configuration config) {
        return (config.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    /**
     * On screen again, or for the first time: inactive until resumed. The
     * window's phase follows {@code onStart}, {@code onResume},
     * {@code onPause} and {@code onStop}, which go to the Swift side whether
     * or not the app has started — it starts from wherever the Activity is.
     */
    @Override
    protected void onStart() {
        super.onStart();
        NucleantBridge.nucleantSetActivityState(ACTIVITY_STARTED);
    }

    @Override
    protected void onResume() {
        super.onResume();
        NucleantBridge.nucleantSetActivityState(ACTIVITY_RESUMED);

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
        // Still on screen, not in front: inactive.
        NucleantBridge.nucleantSetActivityState(ACTIVITY_STARTED);
        super.onPause();
    }

    /** Off screen: the background. */
    @Override
    protected void onStop() {
        NucleantBridge.nucleantSetActivityState(ACTIVITY_STOPPED);
        super.onStop();
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
