import AppKit
import Combine

// MARK: - Notification

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("appSettingsDidChange")
}

// MARK: - AppSettings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var fontFamily: String = "system"
    @Published var fontSize: Double = 15
    @Published var ligatures: Bool = true

    // MARK: Resolved fonts

    var bodyNSFont: NSFont {
        resolve(family: fontFamily, size: fontSize)
    }

    var monoNSFont: NSFont {
        resolve(family: fontFamily, size: fontSize - 2, monoFallback: true)
    }

    var tableNSFont: NSFont {
        resolve(family: fontFamily, size: fontSize - 1, monoFallback: true)
    }

    // MARK: Persistence

    private let settingsURL: URL
    private var cancellables = Set<AnyCancellable>()

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkLens", isDirectory: true)
        settingsURL = dir.appendingPathComponent("settings.json")

        load()

        // Save + notify on any property change (debounced)
        objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.save()
                NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
            }
            .store(in: &cancellables)
    }

    // MARK: JSON

    struct JSONSettings: Codable {
        var editorFontFamily: String
        var editorFontSize: Double
        var editorLigatures: Bool

        enum CodingKeys: String, CodingKey {
            case editorFontFamily = "editor.fontFamily"
            case editorFontSize   = "editor.fontSize"
            case editorLigatures  = "editor.ligatures"
        }
    }

    var jsonText: String {
        let s = JSONSettings(editorFontFamily: fontFamily,
                             editorFontSize: fontSize,
                             editorLigatures: ligatures)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    func applyJSON(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        let s = try JSONDecoder().decode(JSONSettings.self, from: data)
        fontFamily = s.editorFontFamily
        fontSize   = s.editorFontSize
        ligatures  = s.editorLigatures
    }

    /// File URL of the on-disk settings.json so the user can open it externally.
    var settingsFileURL: URL { settingsURL }

    // MARK: Font resolution

    private func resolve(family: String, size: Double, monoFallback: Bool = false) -> NSFont {
        if family == "system" || family.isEmpty {
            return monoFallback
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: family, size: size)
            ?? (monoFallback
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: .regular))
    }

    // MARK: Load / Save

    private func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let s    = try? JSONDecoder().decode(JSONSettings.self, from: data)
        else { return }
        fontFamily = s.editorFontFamily
        fontSize   = s.editorFontSize
        ligatures  = s.editorLigatures
    }

    func save() {
        let s = JSONSettings(editorFontFamily: fontFamily,
                             editorFontSize: fontSize,
                             editorLigatures: ligatures)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        let dir = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: settingsURL)
    }
}
