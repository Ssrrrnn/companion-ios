import SwiftUI
import UIKit

/// A wrapping composer: a typed Return sends, pasted paragraphs stay together.
struct ReturnComposer: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var canSend: Bool
    var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .label
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "聊天输入框"
        view.accessibilityIdentifier = "chat-composer"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil && view.text != text { view.text = text; view.invalidateIntrinsicContentSize() }
        if focused && !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        uiView.isScrollEnabled = measured.height > 136
        return CGSize(width: width, height: min(136, max(42, measured.height)))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReturnComposer
        init(_ parent: ReturnComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil {
                if parent.canSend { parent.onSend() }
                return false
            }
            return true
        }
    }
}
