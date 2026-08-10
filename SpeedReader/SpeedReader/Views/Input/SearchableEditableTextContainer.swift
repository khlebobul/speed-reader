import AppKit
import SwiftUI

/// Editable plain-text area with the shared always-visible search control.
@available(macOS 14.0, *)
struct SearchableEditableTextContainer: View {
    @Binding var text: String
    @Binding var selectedStartIndex: Int?
    /// Called with the active match's RSVP word index when the user clicks "Read from here".
    var onStartFromHere: ((Int) -> Void)? = nil
    /// Leading content of the unified top toolbar.
    var toolbarLeading: AnyView = AnyView(EmptyView())
    /// Trailing controls of the unified top toolbar.
    var toolbarTrailing: AnyView = AnyView(EmptyView())
    /// Keep the toolbar row visible even when search is unavailable.
    var alwaysShowsToolbar: Bool = false

    @State private var textViewRef: NSTextView? = nil
    @State private var target: EditableTextSearchTarget? = nil
    @State private var focusRequest = 0
    @State private var isSearchOpen: Bool = false

    private var textViewID: ObjectIdentifier? {
        textViewRef.map(ObjectIdentifier.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            ZStack(alignment: .topLeading) {
                EditableTextView(
                    text: $text,
                    selectedStartIndex: selectedStartIndex,
                    textViewRef: $textViewRef
                )

                if text.isEmpty {
                    Text("Paste or type your text here...")
                        .font(.system(size: 15))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                        .padding(.leading, 19)
                        .padding(.top, 15)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSearchOpen, let target {
                    ExpandedSearchRow(
                        target: target,
                        focusRequest: focusRequest,
                        onClose: closeSearch,
                        onStartFromHere: onStartFromHere
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: target != nil)
        .animation(.easeOut(duration: 0.2), value: isSearchOpen)
        .onAppear(perform: syncTarget)
        .onChange(of: textViewID) { _, _ in syncTarget() }
        .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
            syncTarget()
            isSearchOpen = true
            focusRequest += 1
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        if target != nil || alwaysShowsToolbar {
            PreviewToolbarRow(leading: toolbarLeading, trailing: toolbarTrailing) {
                if target != nil {
                    SearchToggleButton(isOpen: isSearchOpen) {
                        if isSearchOpen {
                            closeSearch()
                        } else {
                            isSearchOpen = true
                            focusRequest += 1
                        }
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func syncTarget() {
        guard let textView = textViewRef else { return }
        if target?.textView !== textView {
            target = EditableTextSearchTarget(textView: textView)
        }
    }

    private func closeSearch() {
        target?.clear()
        isSearchOpen = false
    }
}

@available(macOS 14.0, *)
private struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    let selectedStartIndex: Int?
    @Binding var textViewRef: NSTextView?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        DispatchQueue.main.async {
            textViewRef = textView
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateStartHighlight(in: textView, selectedIndex: selectedStartIndex)
        if textViewRef !== textView {
            DispatchQueue.main.async {
                textViewRef = textView
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView {
            textView.delegate = nil
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var highlightedStartRange: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func updateStartHighlight(in textView: NSTextView, selectedIndex: Int?) {
            clearStartHighlight(in: textView)
            guard let selectedIndex,
                  selectedIndex >= 0,
                  let range = wordRange(for: selectedIndex, in: textView.string),
                  let layoutManager = textView.layoutManager
            else { return }

            highlightedStartRange = range
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: HighlightStyle.nsColor(for: .startMarker),
                forCharacterRange: range
            )
            for (key, value) in HighlightStyle.nsBorderAttributes(for: .startMarker) {
                layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
            }
            textView.scrollRangeToVisible(range)
        }

        private func clearStartHighlight(in textView: NSTextView) {
            guard let range = highlightedStartRange,
                  let layoutManager = textView.layoutManager
            else { return }

            if NSMaxRange(range) <= (textView.string as NSString).length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
            }
            highlightedStartRange = nil
        }

        private func wordRange(for selectedIndex: Int, in text: String) -> NSRange? {
            guard let regex = try? NSRegularExpression(pattern: RSVPEngine.wordPattern) else {
                return nil
            }

            let nsRange = NSRange(location: 0, length: (text as NSString).length)
            let matches = regex.matches(in: text, range: nsRange)
            guard selectedIndex < matches.count else { return nil }
            return matches[selectedIndex].range
        }
    }
}
