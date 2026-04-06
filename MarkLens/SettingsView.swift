import SwiftUI
import AppKit

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "textformat") }
        }
        .frame(width: 520, height: 320)
    }
}

// MARK: - EditorSettingsTab

private struct EditorSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    enum Mode: String, CaseIterable {
        case visual = "Visual"
        case json   = "JSON"
    }

    @State private var mode: Mode = .visual
    @State private var jsonText: String = ""
    @State private var jsonError: String? = nil
    @State private var fontOptions: [(display: String, postscript: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if mode == .visual {
                visualForm
            } else {
                jsonEditor
            }
        }
        .onAppear {
            fontOptions = loadMonoFonts()
            jsonText = settings.jsonText
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .json {
                jsonText = settings.jsonText
                jsonError = nil
            }
        }
    }

    // MARK: Visual Form

    private var visualForm: some View {
        Form {
            Section {
                Picker("Font Family", selection: $settings.fontFamily) {
                    Text("System (Default)")
                        .tag("system")
                    Divider()
                    ForEach(fontOptions, id: \.postscript) { opt in
                        Text(opt.display).tag(opt.postscript)
                    }
                }

                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .foregroundStyle(.secondary)
                    Stepper("", value: $settings.fontSize, in: 10...36, step: 1)
                        .labelsHidden()
                }

                Toggle("Enable Ligatures", isOn: $settings.ligatures)
            }

            Section {
                HStack {
                    Text("settings.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open File") {
                        NSWorkspace.shared.open(settings.settingsFileURL)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: JSON Editor

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = jsonError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            JSONEditorView(text: $jsonText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text(settings.settingsFileURL.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Apply") {
                    do {
                        try settings.applyJSON(jsonText)
                        jsonError = nil
                    } catch {
                        jsonError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: Font loading

    private func loadMonoFonts() -> [(display: String, postscript: String)] {
        let keywords = ["mono", "code", "courier", "console", "fira", "jet",
                        "menlo", "consolas", "hack", "inconsolata", "cascadia",
                        "iosevka", "source code", "input ", "anonymous"]
        var result: [(String, String)] = []
        for family in NSFontManager.shared.availableFontFamilies {
            let lower = family.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { continue }
            guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
                  !members.isEmpty else { continue }
            // Pick Regular weight; fall back to first member
            let regular = members.first(where: {
                ($0[1] as? String)?.lowercased().contains("regular") == true
            }) ?? members[0]
            guard let ps = regular[0] as? String else { continue }
            result.append((family, ps))
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

// MARK: - JSONEditorView

private struct JSONEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let tv = NSTextView()
        tv.isEditable   = true
        tv.isRichText   = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor.labelColor
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        tv.delegate = context.coordinator

        scrollView.documentView = tv
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditorView
        init(_ parent: JSONEditorView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
