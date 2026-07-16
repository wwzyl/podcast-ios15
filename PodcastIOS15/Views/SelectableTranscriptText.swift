import SwiftUI
import UIKit

/// 原生文本选择：长按单词或拖动选择词组后直接打开释义面板。
struct SelectableTranscriptText: UIViewRepresentable {
    let text: String
    let active: Bool
    let onTap: () -> Void
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onSelection: onSelection) }

    func makeUIView(context: Context) -> UITextView {
        let view = IntrinsicTextView()
        context.coordinator.textView = view
        view.onInteractionEnded = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.commitSelection(in: view)
        }
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let selectionPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectionGestureEnded(_:)))
        selectionPress.minimumPressDuration = 0.35
        selectionPress.cancelsTouchesInView = false
        selectionPress.delegate = context.coordinator
        view.addGestureRecognizer(selectionPress)
        update(view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onSelection = onSelection
        if uiView.text != text { uiView.text = text }
        update(uiView)
    }

    private func update(_ view: UITextView) {
        view.font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3).withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3), size: 0)
        view.textColor = active ? .label : UIColor.label.withAlphaComponent(0.9)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        var onSelection: (String) -> Void
        weak var textView: UITextView?
        private var pendingValue: String?

        init(onTap: @escaping () -> Void, onSelection: @escaping (String) -> Void) {
            self.onTap = onTap
            self.onSelection = onSelection
        }

        @objc func didTap() {
            guard textView?.selectedRange.length ?? 0 == 0 else { return }
            onTap()
        }

        @objc func selectionGestureEnded(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let textView else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let textView else { return }
                self?.commitSelection(in: textView)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else { pendingValue = nil; return }
            let value = (textView.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingValue = value.isEmpty ? nil : value
        }

        func commitSelection(in textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else { return }
            guard let pendingSelection = pendingValue else { return }
            let current = (textView.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = current.isEmpty ? pendingSelection : current
            guard !value.isEmpty else { return }
            pendingValue = nil
            onSelection(value)
        }
    }
}

private final class IntrinsicTextView: UITextView {
    var onInteractionEnded: (() -> Void)?
    private var lastWidth: CGFloat = 0
    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 30) }
        return sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onInteractionEnded?()
    }
}
