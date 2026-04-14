import SwiftUI
import AppKit

/// Xcode-style welcome window shown on launch when there is no prior session.
/// Dismissed automatically when the user opens or selects a document.
struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    private var recents: [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            recentPanel
        }
        .frame(width: 640, height: 380)
    }

    // MARK: - Left sidebar (branding)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 72, height: 72)
                }
                Text("MarkLens")
                    .font(.title.bold())
                Text("The Markdown editor\nfor your thoughts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            Spacer()
            Text("Version \(Bundle.main.shortVersionString)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
        }
        .padding(28)
        .frame(width: 220)
        .background(.quinary)
    }

    // MARK: - Right panel (recents + actions)

    private var recentPanel: some View {
        VStack(spacing: 0) {
            recentsList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
        }
    }

    @ViewBuilder
    private var recentsList: some View {
        if recents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.quaternary)
                Text("No Recent Documents")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(recents.prefix(12), id: \.self) { url in
                Button {
                    open(url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .truncationMode(.head)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Open File…") {
                (NSApp.delegate as? AppDelegate)?.performOpenFile()
                dismiss()
            }
            Button("Open Folder…") {
                (NSApp.delegate as? AppDelegate)?.performOpenFolder()
                dismiss()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func open(_ url: URL) {
        (NSApp.delegate as? AppDelegate)?.activeAppState?.workspaceStore.openExternalFile(url)
        dismiss()
    }

    private func dismiss() {
        dismissWindow(id: "welcome")
    }
}

private extension Bundle {
    var shortVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
