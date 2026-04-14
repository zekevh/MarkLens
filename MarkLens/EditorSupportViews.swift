import SwiftUI
import AppKit

struct RawTextEditorView: NSViewRepresentable {
    @Binding var text: String
    var fileURL: URL?
    var searchJumpRequest: DocumentSearchJumpRequest?
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityIdentifier("rawTextEditor")
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 40, height: 72)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.parent = self
        context.coordinator.applySearchJumpIfNeeded(to: textView)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawTextEditorView
        private var handledJumpRequestID: UUID?

        init(_ parent: RawTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            parent.text = newText
            parent.onTextChange(newText)
        }

        func applySearchJumpIfNeeded(to textView: NSTextView) {
            guard let request = parent.searchJumpRequest,
                  request.fileURL == parent.fileURL,
                  handledJumpRequestID != request.id else { return }

            handledJumpRequestID = request.id
            let length = (textView.string as NSString).length
            let location = min(max(0, request.location), length)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            scrollCursorToVisible(in: textView)
        }
    }
}

struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No file selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open a folder or file to start editing")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("emptyEditorView")
    }
}
