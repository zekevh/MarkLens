import AppKit
import UniformTypeIdentifiers

/// NSDocument subclass that manages a single Markdown file.
///
/// Used as the backend for DocumentStore — it is instantiated directly
/// (never via NSDocumentController) so one window can navigate many files
/// through the sidebar without spawning new windows per document.
///
/// Key behaviors provided for free:
///  - autosaveInPlace: atomic writes triggered by updateChangeCount(.changeDone)
///  - NSFilePresenter: detects external edits (git, other editors, iCloud)
///  - File > Revert to Saved, Versions browser
///  - isDocumentEdited for dirty-state tracking
final class MarkdownDocument: NSDocument {

    /// Called on the main actor when an external process changes the file on disk.
    var onContentUpdated: ((String) -> Void)?

    /// The current in-memory text. DocumentStore reads this after init(contentsOf:ofType:).
    /// nonisolated(unsafe) allows reads/writes from nonisolated NSDocument callbacks
    /// (read, data, presentedItemDidChange). Access patterns are safe in practice:
    /// init writes once before any reads, update runs on MainActor, data(ofType:) reads
    /// only during NSDocument-coordinated writes.
    nonisolated(unsafe) private(set) var text: String = ""

    /// Set to true after the first read completes. Any subsequent read() call is a
    /// revert-to-saved operation — we notify DocumentStore in that case.
    nonisolated(unsafe) private var hasLoaded = false

    // MARK: - NSDocument overrides

    nonisolated override class var autosavesInPlace: Bool { true }

    /// Suppress the default behavior of opening a new window for this document.
    nonisolated override func makeWindowControllers() {}

    // MARK: - Read / Write

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let isRevert = hasLoaded && string != text
        text = string
        hasLoaded = true
        if isRevert {
            // File > Revert to Saved — notify DocumentStore to refresh the editor text.
            DispatchQueue.main.async { [weak self] in
                self?.onContentUpdated?(string)
            }
        }
    }

    nonisolated override func data(ofType typeName: String) throws -> Data {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    // MARK: - Mutation (called by DocumentStore on every edit)

    /// Updates the in-memory text and marks the document dirty.
    /// NSDocument's autosaveInPlace machinery handles the actual disk write.
    func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        updateChangeCount(.changeDone)
    }

    // MARK: - External edit detection (NSFilePresenter)

    /// Fired by NSFilePresenter when an external process modifies the file.
    /// NSDocument's default implementation does nothing, so we read the new
    /// content ourselves and route it through the onContentUpdated callback.
    nonisolated override func presentedItemDidChange() {
        super.presentedItemDidChange()
        guard let url = fileURL else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url),
                  let newText = String(data: data, encoding: .utf8),
                  newText != self.text else { return }
            self.text = newText
            self.onContentUpdated?(newText)
        }
    }

}
