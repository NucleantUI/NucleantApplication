//
//  TextInputView.swift
//  NucleantApplication
//
#if os(iOS)
import NucleantWindow
import UIKit

/// What the on-screen keyboard types into: a view with nothing to show,
/// which `PlatformWindow` makes first responder while text is entered —
/// that is what puts the keyboard up — and takes first responder back from
/// to put it away.
///
/// The keyboard's edits reach the window as key presses, as the Android
/// keyboard's do: Backspace for a deletion, Return for a newline, and each
/// other character as an unknown key (`unknownWindowKeyCode`) typing it.
///
/// `UIKeyInput` only, not `UITextInput`: the keyboard can't read the field's
/// text back, so what would rewrite text already typed — autocorrection,
/// smart punctuation, autocapitalization — is off.
final class TextInputView<WindowBase>: UIView, UIKeyInput
    where WindowBase: NucleantWindow & WindowTouchDelegate {

    /// The window the view is in, which owns it.
    weak var platformWindow: PlatformWindow<WindowBase>?

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Given up by asking, or by the keyboard being put away: the window
    /// tells which.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { platformWindow?.textInputViewResigned() }
        return resigned
    }

    // MARK: - UIKeyInput

    /// Always: so Backspace on an empty-looking field still arrives — the
    /// field's text is the field's, not this view's.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        platformWindow?.typeText(text.map { character in
            character == "\n"
                ? (keyCode: 0x24, characters: "\r")
                : (keyCode: UIKeyboardHIDUsage.unknownWindowKeyCode, characters: String(character))
        })
    }

    func deleteBackward() {
        platformWindow?.typeText([(keyCode: 0x33, characters: nil)])
    }

    // MARK: - UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no

    // MARK: - Hardware keys

    // A hardware keyboard's presses go to the window's delegate as they do
    // while the window has them — and not on to UIKit, whose text handling
    // would type each key into this view a second time.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let platformWindow else { return super.pressesBegan(presses, with: event) }
        let rest = platformWindow.pressKeys(presses, with: event)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let platformWindow else { return super.pressesEnded(presses, with: event) }
        let rest = platformWindow.releaseKeys(presses, with: event)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let platformWindow else { return super.pressesCancelled(presses, with: event) }
        let rest = platformWindow.releaseKeys(presses, with: event)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}
#endif
