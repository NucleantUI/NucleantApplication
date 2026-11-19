package org.nucleantui;

import android.content.Context;
import android.graphics.Insets;
import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.Selection;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowInsets;
import android.view.WindowInsetsAnimation;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.util.List;

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
        followInsets();
    }

    // ── Keyboard height and safe area ────────────────────────────────────────

    /**
     * What covers the window, sent to Swift as it changes: the soft keyboard,
     * from the window's bottom edge up, and the system bars and the display
     * cutout at its edges, the safe area. In pixels, from the window's
     * insets.
     *
     * <p>The window keeps its size under all of them (see
     * {@link NucleantActivity#onCreate}); the app lays itself out clear of
     * them instead. From API 30, which has the insets by type.
     */
    private void followInsets() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return;
        }
        setOnApplyWindowInsetsListener((view, insets) -> {
            applyInsets(insets);
            return insets;
        });
        setWindowInsetsAnimationCallback(new KeyboardAnimation());
    }

    /** The keyboard height Swift was last sent, in pixels. */
    private int keyboardHeight = 0;
    /** Where the window's insets last had the keyboard: where it is, or where an animation is taking it. */
    private int keyboardTarget = 0;
    /**
     * The keyboard is moving. Its new height is sent when the animation
     * starts, with the animation's duration, rather than when the insets
     * change, which is before it.
     */
    private boolean keyboardAnimating = false;
    /**
     * The animation has no duration: the keyboard follows a gesture, such as
     * Back pulling it down, so its height is sent on every frame of it.
     */
    private boolean keyboardFollowing = false;

    private void applyInsets(WindowInsets insets) {
        Insets safeArea = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
        NucleantBridge.nucleantSetSafeAreaInsets(safeArea.left, safeArea.top, safeArea.right, safeArea.bottom);
        keyboardTarget = insets.getInsets(WindowInsets.Type.ime()).bottom;
        if (!keyboardAnimating) {
            sendKeyboardHeight(keyboardTarget, 0);
        }
    }

    private void sendKeyboardHeight(int height, double duration) {
        if (height == keyboardHeight) {
            return;
        }
        keyboardHeight = height;
        NucleantBridge.nucleantSetKeyboardHeight(height, duration);
    }

    /**
     * The keyboard coming up or going down. The system calls these in order:
     * {@code onPrepare}, then the window's insets as they will be at the end,
     * then {@code onStart}, {@code onProgress} for every frame, and
     * {@code onEnd}.
     */
    private final class KeyboardAnimation extends WindowInsetsAnimation.Callback {
        KeyboardAnimation() {
            super(DISPATCH_MODE_STOP);
        }

        private boolean movesKeyboard(WindowInsetsAnimation animation) {
            return (animation.getTypeMask() & WindowInsets.Type.ime()) != 0;
        }

        @Override
        public void onPrepare(WindowInsetsAnimation animation) {
            if (movesKeyboard(animation)) {
                keyboardAnimating = true;
            }
        }

        @Override
        public WindowInsetsAnimation.Bounds onStart(WindowInsetsAnimation animation, WindowInsetsAnimation.Bounds bounds) {
            if (movesKeyboard(animation)) {
                long duration = animation.getDurationMillis();
                if (duration > 0) {
                    sendKeyboardHeight(keyboardTarget, duration / 1000.0);
                } else {
                    keyboardFollowing = true;
                }
            }
            return bounds;
        }

        @Override
        public WindowInsets onProgress(WindowInsets insets, List<WindowInsetsAnimation> running) {
            if (keyboardFollowing) {
                sendKeyboardHeight(insets.getInsets(WindowInsets.Type.ime()).bottom, 0);
            }
            return insets;
        }

        @Override
        public void onEnd(WindowInsetsAnimation animation) {
            if (!movesKeyboard(animation)) {
                return;
            }
            keyboardAnimating = false;
            keyboardFollowing = false;
            // Where it ended up: a gesture let go of halfway puts it back.
            WindowInsets insets = getRootWindowInsets();
            if (insets != null) {
                keyboardTarget = insets.getInsets(WindowInsets.Type.ime()).bottom;
            }
            sendKeyboardHeight(keyboardTarget, 0);
        }
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

        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            tappedSinceLastFrame = true;
        }
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
        if (textInput != null) {
            textInput.mirrorKey(keyCode, event.getUnicodeChar());
        }
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

    // ── Soft keyboard ────────────────────────────────────────────────────────

    /** {@code AndroidSurfaceHost.TextInputKind}: what the focused view takes. */
    private static final int TEXT_NONE = 0;
    private static final int TEXT_MULTI_LINE = 2;

    private int textInputKind = TEXT_NONE;
    private boolean tappedSinceLastFrame = false;
    /** The live connection, while the keyboard has one. */
    private TextInput textInput;

    /**
     * Show, switch or hide the soft keyboard for what the focused view takes.
     *
     * <p>Called by the Activity after every frame with what the Swift side
     * wants — asked rather than told, as {@code nucleantFirstFrameRendered}
     * is: jextract generates only the Java to Swift direction, and the poll
     * runs on the thread that decided, right after it decided.
     *
     * <p>A tap while a text field already has the keys shows the keyboard
     * again — Back hides it without the field losing focus — and starts a
     * fresh connection, since the tap may have moved the caret out from under
     * whatever the keyboard was composing.
     */
    void setTextInputKind(int kind) {
        boolean tapped = tappedSinceLastFrame;
        tappedSinceLastFrame = false;
        InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm == null) {
            return;
        }
        if (kind == textInputKind) {
            if (kind != TEXT_NONE && tapped) {
                imm.restartInput(this);
                imm.showSoftInput(this, 0);
            }
            return;
        }
        textInputKind = kind;
        if (kind == TEXT_NONE) {
            textInput = null;
            imm.hideSoftInputFromWindow(getWindowToken(), 0);
            // Drop the connection too, so nothing the keyboard still has in
            // flight lands in a field that no longer has the keys.
            imm.restartInput(this);
        } else {
            requestFocus();
            // A new connection for the new kind: its EditorInfo decides the
            // keyboard's action key.
            imm.restartInput(this);
            imm.showSoftInput(this, 0);
        }
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return textInputKind != TEXT_NONE;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        if (textInputKind == TEXT_NONE) {
            return null;
        }
        boolean multiLine = textInputKind == TEXT_MULTI_LINE;
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT
            | (multiLine ? InputType.TYPE_TEXT_FLAG_MULTI_LINE : 0);
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN
            | EditorInfo.IME_FLAG_NO_EXTRACT_UI
            | (multiLine ? EditorInfo.IME_ACTION_NONE : EditorInfo.IME_ACTION_DONE);
        // The keyboard's copy starts empty, with the caret in it.
        outAttrs.initialSelStart = 0;
        outAttrs.initialSelEnd = 0;
        textInput = new TextInput(multiLine);
        return textInput;
    }

    /**
     * The soft keyboard's edits, as the key presses the Swift side takes.
     *
     * <p>The field's text lives in Swift. The keyboard works on a copy of what
     * it typed since the field was tapped — {@link #getEditable()}, which the
     * base class edits for every call — and each change to that copy is
     * replayed as presses: arrows to the edit, Backspace over what it removed,
     * the characters it added. Those are the presses the text views already
     * take from a hardware keyboard.
     *
     * <p>The copy is what lets the keyboard's own features work: a suggestion
     * or an autocorrection replaces the word before the caret, which the
     * keyboard finds by reading it back. A tap starts a new connection (see
     * {@link #setTextInputKind}), so the copy only ever has to agree with the
     * field from the caret's position since the last tap.
     */
    private final class TextInput extends BaseInputConnection {
        private final boolean multiLine;
        private int batchDepth = 0;
        private String batchText;
        private int batchCaret;

        TextInput(boolean multiLine) {
            super(NucleantSurfaceView.this, true);
            this.multiLine = multiLine;
        }

        @Override
        public boolean beginBatchEdit() {
            if (batchDepth++ == 0) {
                batchText = getEditable().toString();
                batchCaret = Selection.getSelectionEnd(getEditable());
            }
            return true;
        }

        @Override
        public boolean endBatchEdit() {
            if (batchDepth > 0 && --batchDepth == 0) {
                replay(batchText, batchCaret);
            }
            return batchDepth > 0;
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            return edit(() -> super.commitText(text, newCursorPosition));
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            return edit(() -> super.setComposingText(text, newCursorPosition));
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            return edit(() -> super.deleteSurroundingText(beforeLength, afterLength));
        }

        @Override
        public boolean deleteSurroundingTextInCodePoints(int beforeLength, int afterLength) {
            return edit(() -> super.deleteSurroundingTextInCodePoints(beforeLength, afterLength));
        }

        @Override
        public boolean setSelection(int start, int end) {
            return edit(() -> super.setSelection(start, end));
        }

        /** Done on a one-line field: submit, and put the keyboard away. */
        @Override
        public boolean performEditorAction(int actionCode) {
            press(KeyEvent.KEYCODE_ENTER, '\n');
            if (!multiLine) {
                InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) {
                    imm.hideSoftInputFromWindow(getWindowToken(), 0);
                }
            }
            return true;
        }

        /** Backspace, Enter and the like, which keyboards send as key events. */
        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                mirrorKey(event.getKeyCode(), event.getUnicodeChar());
                NucleantBridge.nucleantKeyDown(event.getKeyCode(), event.getUnicodeChar());
            } else if (event.getAction() == KeyEvent.ACTION_UP) {
                NucleantBridge.nucleantKeyUp(event.getKeyCode(), event.getUnicodeChar());
            }
            return true;
        }

        /**
         * A key that reached the field some other way — a hardware keyboard,
         * or a key event from this one — applied to the copy too, so the two
         * stay in step. Not replayed: the key itself is on its way to Swift.
         */
        void mirrorKey(int keyCode, int unicodeChar) {
            Editable text = getEditable();
            int caret = caret();
            switch (keyCode) {
                case KeyEvent.KEYCODE_DEL:
                    if (caret > 0) {
                        text.delete(text.length() == 0 ? 0 : Character.offsetByCodePoints(text, caret, -1), caret);
                    }
                    break;
                case KeyEvent.KEYCODE_FORWARD_DEL:
                    if (caret < text.length()) {
                        text.delete(caret, Character.offsetByCodePoints(text, caret, 1));
                    }
                    break;
                case KeyEvent.KEYCODE_DPAD_LEFT:
                    Selection.setSelection(text, caret > 0 ? Character.offsetByCodePoints(text, caret, -1) : 0);
                    break;
                case KeyEvent.KEYCODE_DPAD_RIGHT:
                    Selection.setSelection(text, caret < text.length() ? Character.offsetByCodePoints(text, caret, 1) : caret);
                    break;
                case KeyEvent.KEYCODE_MOVE_HOME:
                    Selection.setSelection(text, 0);
                    break;
                case KeyEvent.KEYCODE_MOVE_END:
                    Selection.setSelection(text, text.length());
                    break;
                default:
                    if (unicodeChar != 0 && (unicodeChar != '\n' || multiLine)) {
                        text.insert(caret, new String(Character.toChars(unicodeChar)));
                    } else {
                        return;
                    }
            }
            removeComposingSpans(text);
            reportSelection();
        }

        private String snapshot() {
            return getEditable().toString();
        }

        private int caret() {
            return Math.max(0, Selection.getSelectionEnd(getEditable()));
        }

        /**
         * One of the keyboard's calls, as a batch of its own: the base class
         * batches its edits internally too, and however they nest, the change
         * is replayed once, when the outermost batch ends.
         */
        private boolean edit(java.util.function.BooleanSupplier call) {
            beginBatchEdit();
            boolean done = call.getAsBoolean();
            endBatchEdit();
            return done;
        }

        /**
         * Bring the field from {@code before} (caret at {@code caretBefore}) to
         * the copy as it is now: one changed span, found between the common
         * prefix and suffix, typed over.
         */
        private void replay(String before, int caretBefore) {
            String after = snapshot();
            int caretAfter = caret();
            int prefix = 0;
            int max = Math.min(before.length(), after.length());
            while (prefix < max && before.charAt(prefix) == after.charAt(prefix)) {
                prefix++;
            }
            int suffix = 0;
            while (suffix < max - prefix
                && before.charAt(before.length() - 1 - suffix) == after.charAt(after.length() - 1 - suffix)) {
                suffix++;
            }
            // Never split a surrogate pair at either edge.
            if (prefix > 0 && Character.isHighSurrogate(before.charAt(prefix - 1))) {
                prefix--;
            }
            if (suffix > 0 && Character.isLowSurrogate(after.charAt(after.length() - suffix))) {
                suffix--;
            }
            int removedEnd = before.length() - suffix;
            int insertedEnd = after.length() - suffix;
            if (prefix < removedEnd || prefix < insertedEnd) {
                moveCaret(before, caretBefore, removedEnd);
                for (int i = Character.codePointCount(before, prefix, removedEnd); i > 0; i--) {
                    press(KeyEvent.KEYCODE_DEL, 0);
                }
                for (int i = prefix; i < insertedEnd; ) {
                    int codePoint = Character.codePointAt(after, i);
                    i += Character.charCount(codePoint);
                    if (codePoint == '\n') {
                        press(KeyEvent.KEYCODE_ENTER, '\n');
                    } else {
                        press(KeyEvent.KEYCODE_UNKNOWN, codePoint);
                    }
                }
                moveCaret(after, insertedEnd, caretAfter);
            } else {
                moveCaret(after, caretBefore, caretAfter);
            }
            reportSelection();
        }

        /** Arrow presses taking the field's caret from {@code from} to {@code to}. */
        private void moveCaret(String text, int from, int to) {
            from = Math.min(Math.max(from, 0), text.length());
            to = Math.min(Math.max(to, 0), text.length());
            if (to > from) {
                for (int i = Character.codePointCount(text, from, to); i > 0; i--) {
                    press(KeyEvent.KEYCODE_DPAD_RIGHT, 0);
                }
            } else if (to < from) {
                for (int i = Character.codePointCount(text, to, from); i > 0; i--) {
                    press(KeyEvent.KEYCODE_DPAD_LEFT, 0);
                }
            }
        }

        /** The keyboard tracks the caret through these, as it would an EditText's. */
        private void reportSelection() {
            InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm == null) {
                return;
            }
            Editable text = getEditable();
            imm.updateSelection(NucleantSurfaceView.this,
                Selection.getSelectionStart(text), Selection.getSelectionEnd(text),
                getComposingSpanStart(text), getComposingSpanEnd(text));
        }

        private void press(int keyCode, int unicodeChar) {
            NucleantBridge.nucleantKeyDown(keyCode, unicodeChar);
            NucleantBridge.nucleantKeyUp(keyCode, unicodeChar);
        }
    }
}
