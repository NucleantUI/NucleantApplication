package org.nucleantui;

import android.content.Context;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

/**
 * The render surface, and the app's input.
 *
 * <p>Ships with NucleantApplication, under a fixed package the way
 * {@code org.libsdl.app.SDLActivity} does — nothing about it is app-specific,
 * and it is the Java half of a contract whose Swift half
 * ({@code AndroidSurfaceBridge}) lives in the same package. Gradle compiles it
 * from there; it is not generated, so edits survive a regenerate.
 *
 * <p>Every callback forwards straight to Swift. The surface itself crosses as
 * an {@code android.view.Surface}; Swift turns it into the
 * {@code ANativeWindow*} that {@code VK_KHR_android_surface} needs.
 */
public class NucleantSurfaceView extends SurfaceView implements SurfaceHolder.Callback {

    public NucleantSurfaceView(Context context) {
        super(context);
        getHolder().addCallback(this);
        // Input goes through this view, so it has to be able to take focus.
        setFocusable(true);
        setFocusableInTouchMode(true);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        NucleantBridge.nucleantSurfaceCreated(holder.getSurface());
        // Only now is there something to render into, so this is the earliest
        // the app can start.
        if (getContext() instanceof NucleantActivity) {
            ((NucleantActivity) getContext()).startAppIfNeeded();
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        NucleantBridge.nucleantSurfaceChanged(width, height);
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        // Blocks until the renderer has stopped touching the window: the
        // Surface is only guaranteed valid until this returns.
        NucleantBridge.nucleantSurfaceDestroyed();
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int index = event.getActionIndex();
        int id = event.getPointerId(index);
        float x = event.getX(index);
        float y = event.getY(index);

        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
                NucleantBridge.nucleantTouchDown(id, x, y);
                break;
            case MotionEvent.ACTION_MOVE:
                // A move event batches every pointer, not just actionIndex.
                for (int i = 0; i < event.getPointerCount(); i++) {
                    NucleantBridge.nucleantTouchMoved(
                        event.getPointerId(i), event.getX(i), event.getY(i));
                }
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                NucleantBridge.nucleantTouchUp(id, x, y);
                break;
            case MotionEvent.ACTION_CANCEL:
                NucleantBridge.nucleantTouchCancelled(id, x, y);
                break;
            default:
                return false;
        }
        return true;
    }

    /**
     * Keys the system owns.
     *
     * <p>Returning true from {@link #onKeyDown} means "handled", and the
     * system then never sees the event — which for BACK means the app cannot
     * be left, and for the volume and HOME keys means the device stops
     * behaving like a device. The app still gets told about them; it just does
     * not get to swallow them.
     */
    private static boolean isSystemKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_HOME:
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_APP_SWITCH:
            case KeyEvent.KEYCODE_VOLUME_UP:
            case KeyEvent.KEYCODE_VOLUME_DOWN:
            case KeyEvent.KEYCODE_VOLUME_MUTE:
            case KeyEvent.KEYCODE_POWER:
                return true;
            default:
                return false;
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        NucleantBridge.nucleantKeyDown(keyCode, event.getUnicodeChar());
        if (isSystemKey(keyCode)) {
            return super.onKeyDown(keyCode, event);
        }
        return true;
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        NucleantBridge.nucleantKeyUp(keyCode, event.getUnicodeChar());
        if (isSystemKey(keyCode)) {
            return super.onKeyUp(keyCode, event);
        }
        return true;
    }
}
