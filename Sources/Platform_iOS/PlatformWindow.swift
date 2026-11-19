//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(iOS)
import NucleantWindow
import UIKit
import QuartzCore

/// The iOS counterpart to macOS's `PlatformWindow`: a `UIWindow` hosting a
/// `VulkanView` through a root view controller. Mirrors macOS exactly — the
/// window itself owns the display link and overrides touch handling directly,
/// forwarding straight to `win_delegate` with no closure/callback indirection.
/// Kept generic (not existential) for the same reason as macOS — `NucleantWindow`
/// has an associated `Node`, so a concrete `WindowBase` type is needed to call
/// its members.
public final class PlatformWindow<WindowBase>: UIWindow, UIWindowSceneDelegate
    where WindowBase: NucleantWindow & WindowTouchDelegate {

    public var on_close: (() -> Void)?

    /// Strongly-held by the owner; we only reference
    /// it weakly so the window doesn't retain its delegate.
    ///
    /// Told the phase the window is in as soon as it is set: a window can be
    /// built while its scene, or the app, is not active yet — or in the
    /// background, for an app launched there — and no notification would
    /// say so until the next change.
    public weak var win_delegate: WindowBase? {
        didSet { enter(currentPhase) }
    }

    private let vulkanView: VulkanView
    private let rootVC: UIViewController

    /// What the on-screen keyboard types into, while text is entered.
    private let textInputView = TextInputView<WindowBase>()

    private var displayLink: CADisplayLink?

    /// Per-window stable touch ids: UIKit hands out UITouch objects, not
    /// indices, so map each active touch to a small integer for the lifetime
    /// of its sequence.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0

    /// The Metal layer to hand to `VulkanRenderEngine(metalLayer:)`.
    public var metalLayer: CAMetalLayer { vulkanView.metalLayer }

    public override init(frame: CGRect) {
        let view = VulkanView(frame: frame)
        self.vulkanView = view
        let vc = UIViewController()
        self.rootVC = vc
        super.init(frame: frame)
        vc.view = view
        self.rootViewController = vc
        addTextInputView()
        startDisplayLink()
        followPhases(of: nil)
        followKeyboard()
    }

    /// Attaches to a real `UIWindowScene` instead of a bare frame — this is
    /// what makes the window track Stage Manager resizing automatically
    /// (the OS keeps a scene-owned window's frame in step with
    /// `windowScene.coordinateSpace.bounds`); a frame-only window never
    /// resizes on its own.
    public override init(windowScene: UIWindowScene) {
        let bounds = windowScene.coordinateSpace.bounds
        let view = VulkanView(frame: bounds)
        self.vulkanView = view
        let vc = UIViewController()
        self.rootVC = vc
        super.init(windowScene: windowScene)
        self.frame = bounds
        vc.view = view
        self.rootViewController = vc
        addTextInputView()
        startDisplayLink()
        followPhases(of: windowScene)
        followKeyboard()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        let screen = windowScene.screen
        let rect = screen.bounds
        let scale = screen.scale
        win_delegate?.on_size(w: rect.width * scale, h: rect.height * scale)
    }

    // MARK: - Resize

    /// Report the content area (the render surface), not any status-bar
    /// inset — the root widget fills the content, matching present's
    /// contentRect. The layer's drawableSize follows via VulkanView; this
    /// drives the widget-tree relayout. Mirrors macOS's `windowDidResize`.
    public override func layoutSubviews() {
        super.layoutSubviews()
        win_delegate?.on_size(w: Double(bounds.width), h: Double(bounds.height))
        // The keyboard where it was, over a window of another size.
        updateKeyboardHeight(duration: 0, curve: .linear)
    }

    // MARK: - Phase

    private enum Phase { case active, inactive, background }

    /// The phase `win_delegate` was last told. A window starts out active.
    private var phase = Phase.active

    /// The phase of the window's scene as UIKit has it now. A window made
    /// without one is given a scene of UIKit's own, standing for its screen.
    private var currentPhase: Phase {
        switch windowScene?.activationState {
        case .foregroundActive: return .active
        case .foregroundInactive: return .inactive
        case .background: return .background
        // No scene, or not connected yet: the notifications that follow tell.
        default: return phase
        }
    }

    /// The phases go as the scene's: active while it is in use, inactive
    /// while it is still on screen but not in use — the app switcher, a
    /// call, Control Center — and the background once it is off screen.
    /// UIKit posts each change, for each scene and for the app as a whole.
    /// A window made from its scene follows that scene's, so the windows of
    /// two scenes side by side each go their own way; a window made from a
    /// frame — an app with no scene manifest — follows the app's.
    ///
    /// Out of sight is the background as soon as UIKit says so: GPU work
    /// submitted after that is refused, and logged, by iOS.
    private func followPhases(of scene: UIWindowScene?) {
        let center = NotificationCenter.default
        if let scene {
            center.addObserver(self, selector: #selector(becameActive(_:)), name: UIScene.didActivateNotification, object: scene)
            center.addObserver(self, selector: #selector(resigningActive(_:)), name: UIScene.willDeactivateNotification, object: scene)
            center.addObserver(self, selector: #selector(enteredBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: scene)
            center.addObserver(self, selector: #selector(enteringForeground(_:)), name: UIScene.willEnterForegroundNotification, object: scene)
        } else {
            center.addObserver(self, selector: #selector(becameActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(resigningActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(enteredBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(enteringForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        }
    }

    @objc private func becameActive(_ notification: Notification) { enter(.active) }
    @objc private func resigningActive(_ notification: Notification) { enter(.inactive) }
    @objc private func enteredBackground(_ notification: Notification) { enter(.background) }
    /// Coming back is inactive first: on screen, not in use until it is active.
    @objc private func enteringForeground(_ notification: Notification) { enter(.inactive) }

    private func enter(_ phase: Phase) {
        guard phase != self.phase, let win_delegate else { return }
        self.phase = phase
        switch phase {
        case .active: win_delegate.on_phase_active()
        case .inactive: win_delegate.on_phase_inactive()
        case .background: win_delegate.on_phase_background()
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(cadlTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// The previous tick's display-link timestamp.
    private var lastTickTimestamp: CFTimeInterval?

    /// The time since the previous tick, from the link's own vsync
    /// timestamps — a missed refresh counts in the next frame's Δt, as on
    /// macOS (`Platform_MacOS.swift`). The first tick gets one refresh.
    @objc private func cadlTick(_ link: CADisplayLink) {
        let dt = lastTickTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTickTimestamp = link.timestamp
        repeatHeldKey(at: link.timestamp)
        win_delegate?.onFrame(dt)
    }

    // MARK: - Keys

    /// The window takes the hardware keyboard's presses whenever no text is
    /// being entered, so keys reach the delegate with nothing focused too.
    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeKey() {
        super.becomeKey()
        takeKeys()
    }

    /// The modifier keys held as of the last key press or release, from
    /// its event: `keyDown`/`keyUp` carry none, and a delegate reading this
    /// while one is delivered gets that press's. Empty while text from the
    /// on-screen keyboard is delivered.
    public private(set) var keyModifierFlags: UIKeyModifierFlags = []

    /// The key pressed last and still held, and when it repeats next.
    /// UIKit reports a press once, however long it is held, so the window
    /// repeats it itself from the display link, as macOS's key repeat does.
    private var heldKey: (keyCode: UInt16, characters: String?, next: CFTimeInterval)?

    private static var keyRepeatDelay: CFTimeInterval { 0.4 }
    private static var keyRepeatInterval: CFTimeInterval { 0.08 }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = pressKeys(presses, with: event)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = releaseKeys(presses, with: event)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = releaseKeys(presses, with: event)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Tell the delegate of each key in `presses` going down; the presses
    /// with no key (a remote's buttons), for UIKit.
    func pressKeys(_ presses: Set<UIPress>, with event: UIPressesEvent?) -> Set<UIPress> {
        if let event { keyModifierFlags = event.modifierFlags }
        var rest: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                rest.insert(press)
                continue
            }
            guard !key.keyCode.isModifier else { continue }
            let keyCode = key.keyCode.windowKeyCode
            let characters = Self.characters(of: key)
            heldKey = (keyCode, characters, CACurrentMediaTime() + Self.keyRepeatDelay)
            win_delegate?.keyDown(key: keyCode, chars: characters)
        }
        return rest
    }

    /// Tell the delegate of each key in `presses` going up; the presses
    /// with no key, for UIKit.
    func releaseKeys(_ presses: Set<UIPress>, with event: UIPressesEvent?) -> Set<UIPress> {
        if let event { keyModifierFlags = event.modifierFlags }
        var rest: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                rest.insert(press)
                continue
            }
            guard !key.keyCode.isModifier else { continue }
            let keyCode = key.keyCode.windowKeyCode
            if heldKey?.keyCode == keyCode { heldKey = nil }
            win_delegate?.keyUp(key: keyCode, chars: Self.characters(of: key))
        }
        return rest
    }

    /// What `key` types, as the other platforms report it: nil for a key
    /// that types nothing, which UIKit names instead ("UIKeyInputLeftArrow").
    private static func characters(of key: UIKey) -> String? {
        let characters = key.characters
        return characters.isEmpty || characters.hasPrefix("UIKeyInput") ? nil : characters
    }

    /// The held key's next repeat, once it is due.
    private func repeatHeldKey(at time: CFTimeInterval) {
        guard let held = heldKey, time >= held.next else { return }
        heldKey?.next = time + Self.keyRepeatInterval
        win_delegate?.keyDown(key: held.keyCode, chars: held.characters)
    }

    // MARK: - On-screen keyboard

    /// The text the view with the keys takes, which decides the on-screen
    /// keyboard: up for a field, down for anything else. Kept apart from the
    /// UI layer's own name for it.
    public enum TextInputKind {
        /// Nothing focused takes text: no keyboard.
        case none
        /// A one-line field.
        case singleLine
        /// A text editor.
        case multiLine
    }

    private var shownTextInput = TextInputKind.none

    /// What the on-screen keyboard is up for. Anything but `.none` puts it
    /// up, `.none` puts it away. It goes back to `.none` by itself when the
    /// keyboard is put away from the keyboard (iPad's dismiss key), and the
    /// delegate is told (`keyboardDismissed`).
    ///
    /// A hardware keyboard keeps the on-screen one down either way; its keys
    /// reach the delegate as presses all the same.
    public var textInputKind: TextInputKind {
        get { shownTextInput }
        set {
            guard newValue != shownTextInput else { return }
            shownTextInput = newValue
            takeKeys()
        }
    }

    /// Make the responder for what is entered now first: the text-input
    /// view while text is — which is what puts the keyboard up — and the
    /// window otherwise, which puts it away.
    private func takeKeys() {
        if shownTextInput == .none {
            _ = becomeFirstResponder()
        } else {
            _ = textInputView.becomeFirstResponder()
        }
    }

    private func addTextInputView() {
        textInputView.platformWindow = self
        vulkanView.addSubview(textInputView)
    }

    /// Text typed on the on-screen keyboard, as presses with no modifiers.
    func typeText(_ presses: [(keyCode: UInt16, characters: String?)]) {
        let flags = keyModifierFlags
        keyModifierFlags = []
        defer { keyModifierFlags = flags }
        for press in presses {
            win_delegate?.keyDown(key: press.keyCode, chars: press.characters)
            win_delegate?.keyUp(key: press.keyCode, chars: press.characters)
        }
    }

    /// The text-input view gave up first responder. Asked for when nothing
    /// takes text any more; otherwise it is the keyboard put away from the
    /// keyboard, so the keys come back to the window and the delegate hears.
    func textInputViewResigned() {
        guard shownTextInput != .none else { return }
        shownTextInput = .none
        // After UIKit is done handing first responder over.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shownTextInput == .none, !self.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
        win_delegate?.keyboardDismissed()
    }

    // MARK: - Keyboard height

    /// How much of the window the on-screen keyboard covers, in points from
    /// the window's bottom edge up, rounded to the pixel. 0 while it is down,
    /// floating (iPad), on another screen or below the window.
    ///
    /// It changes when UIKit says the keyboard is about to move, before it
    /// does, so the delegate (`keyboardHeightChanged`) can move things along
    /// with it. It also changes when the window's size changes under a
    /// keyboard that stays put.
    public private(set) var keyboardHeight: CGFloat = 0

    /// Where the keyboard is going, in its screen's coordinates, and that
    /// screen, as UIKit last said. nil once it is going away.
    private var keyboardFrame: (frame: CGRect, screen: UIScreen?)?

    private func followKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillMove(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillMove(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The keyboard coming up, or moving: where to.
    @objc private func keyboardWillMove(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        // On iPhone, another app's keyboard is not over this one.
        if UIDevice.current.userInterfaceIdiom == .phone,
           info[UIResponder.keyboardIsLocalUserInfoKey] as? Bool == false {
            return
        }
        let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        // The screen is the notification's object, since iOS 16.1.
        keyboardFrame = frame.map { ($0, notification.object as? UIScreen) }
        updateKeyboardHeight(animatedAs: notification)
    }

    /// The keyboard going away.
    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardFrame = nil
        updateKeyboardHeight(animatedAs: notification)
    }

    /// Update the keyboard height, moving as the keyboard does in
    /// `notification`. A notification with no animation moves it at once.
    private func updateKeyboardHeight(animatedAs notification: Notification) {
        let info = notification.userInfo
        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            .flatMap(UIView.AnimationCurve.init(rawValue:)) ?? .linear
        updateKeyboardHeight(duration: duration, curve: curve)
    }

    /// Measure the keyboard height again, and tell the delegate if it is new.
    private func updateKeyboardHeight(duration: TimeInterval, curve: UIView.AnimationCurve) {
        let height = keyboardOverlap
        guard height != keyboardHeight else { return }
        keyboardHeight = height
        win_delegate?.keyboardHeightChanged(height, duration: duration, curve: curve)
    }

    /// From the window's bottom edge up to the keyboard's top edge, in the
    /// window's points, rounded to the pixel. 0 for no keyboard, one with
    /// an empty frame (iPad's floating keyboard), one on another screen, or
    /// one below the window.
    private var keyboardOverlap: CGFloat {
        guard let keyboard = keyboardFrame, keyboard.frame.width > 0, keyboard.frame.height > 0,
              let screen = keyboard.screen ?? windowScene?.screen else { return 0 }
        if let windowScreen = windowScene?.screen, windowScreen !== screen { return 0 }
        let top = convert(keyboard.frame, from: screen.coordinateSpace).minY
        let scale = screen.scale
        let overlap = ((bounds.maxY - top) * scale).rounded(.toNearestOrAwayFromZero) / scale
        return max(0, overlap)
    }

    // MARK: - Touch input

    private func id(for touch: UITouch) -> Int {
        let key = ObjectIdentifier(touch)
        if let existing = touchIDs[key] { return existing }
        let assigned = nextTouchID
        nextTouchID &+= 1
        touchIDs[key] = assigned
        return assigned
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            win_delegate?.touchDown(id: id(for: touch), location: touch.location(in: self))
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            win_delegate?.touchMoved(id: id(for: touch), location: touch.location(in: self))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let tid = id(for: touch)
            win_delegate?.touchUp(id: tid, location: touch.location(in: self))
            touchIDs[ObjectIdentifier(touch)] = nil
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let tid = id(for: touch)
            win_delegate?.touchCancelled(id: tid, location: touch.location(in: self))
            touchIDs[ObjectIdentifier(touch)] = nil
        }
    }
}
#endif
