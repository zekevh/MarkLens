import SwiftUI
import Combine
import AppKit

struct NodeEditorView: View {
    @Binding var text: String
    var searchText: String
    var searchJumpRequest: DocumentSearchJumpRequest?
    var fileURL: URL?
    var onReadyStateChange: (Bool) -> Void = { _ in }
    var onTextChange: (String) -> Void
    var onLinkClick: ((String) -> Void)? = nil

    @StateObject private var manager = BlocksManager()
    @StateObject private var commandController = NodeEditorCommandController()
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargetID: UUID? = nil
    @State private var lastHandledSearchJumpID: UUID? = nil
    @State private var pendingInitialLayoutIDs: Set<UUID> = []
    @State private var isEditorReady = false
    @State private var suppressProgrammaticSync = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array($manager.blocks.enumerated()), id: \.element.id) { index, $block in
                        BlockRowView(
                            block: $block,
                            index: index,
                            previousBlockKind: index > 0 ? manager.blocks[index - 1].kind : nil,
                            searchText: searchText,
                            fileURL: fileURL,
                            isDropTarget: dropTargetID == block.id,
                            debugBlocks: commandController.debugBlocks,
                            isBlockSelected: manager.allBlocksSelected,
                            registry: manager.registry,
                            onSplitBlock: { orig, loc, nb, na, cp in manager.splitBlock(id: block.id, originalContent: orig, at: loc, newBefore: nb, newAfter: na, newBlockCursorPos: cp) },
                            onMergeWithPrevious: { trailing in manager.mergeWithPrevious(block.id, trailing: trailing) },
                            onNavigatePrevious: { placement in manager.navigatePrevious(from: block.id, placement: placement) },
                            onNavigateNext: { placement in manager.navigateNext(from: block.id, placement: placement) },
                            onInitialLayout: { handleInitialLayout(for: block.id) }
                        )
                        .dropDestination(for: String.self) { items, _ in
                            guard let idString = items.first,
                                  let sourceID = UUID(uuidString: idString),
                                  sourceID != block.id,
                                  let from = manager.blocks.firstIndex(where: { $0.id == sourceID }),
                                  let to = manager.blocks.firstIndex(where: { $0.id == block.id })
                            else { return false }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                manager.moveBlock(from: from, to: to > from ? to + 1 : to)
                            }
                            return true
                        } isTargeted: { targeted in
                            dropTargetID = targeted ? block.id : nil
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 48)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .opacity(isEditorReady ? 1 : 0)
            .offset(y: isEditorReady ? 0 : 10)
        }
        .onAppear {
            commandController.installMonitor(manager: manager)
        }
        .onAppear {
            manager.undoManager = undoManager
            loadEditorText(text)
            manager.registry.onLinkClick = onLinkClick
            manager.registry.onCrossBlockDrag = { [weak manager] anchorID, mouseY in
                guard let manager else { return }
                let registered = manager.registry.allRegistered()
                guard let anchorTV = registered.first(where: { $0.0 == anchorID })?.1 else { return }
                let anchorFrame = windowFrame(of: anchorTV)

                guard mouseY < anchorFrame.minY || mouseY > anchorFrame.maxY else {
                    manager.clearCrossBlockSelection()
                    return
                }
                let goingDown = mouseY < anchorFrame.minY
                var crossIDs = Set<UUID>()
                var newCursorID: UUID? = nil

                for (id, tv) in registered {
                    guard id != anchorID else { continue }
                    let blockTV = tv as? BlockNSTextView
                    let f = windowFrame(of: tv)
                    let totalLength = tv.string.count

                    if goingDown {
                        guard f.maxY <= anchorFrame.minY else {
                            blockTV?.crossBlockSelectionRange = nil
                            continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            let end = min(crossBlockCharIndex(in: tv, windowY: mouseY) + 1, totalLength)
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: end)
                            newCursorID = id
                        } else if f.maxY >= mouseY {
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: totalLength)
                            crossIDs.insert(id)
                        } else {
                            blockTV?.crossBlockSelectionRange = nil
                        }
                    } else {
                        guard f.minY >= anchorFrame.maxY else {
                            blockTV?.crossBlockSelectionRange = nil
                            continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            let start = crossBlockCharIndex(in: tv, windowY: mouseY)
                            blockTV?.crossBlockSelectionRange = NSRange(location: start, length: totalLength - start)
                            newCursorID = id
                        } else if f.minY <= mouseY {
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: totalLength)
                            crossIDs.insert(id)
                        } else {
                            blockTV?.crossBlockSelectionRange = nil
                        }
                    }
                }
                manager.crossSelectedIDs = crossIDs
                manager.crossCursorID = newCursorID
            }
        }
        .onDisappear {
            commandController.removeMonitor()
        }
        .onChange(of: undoManager) { _, um in
            manager.undoManager = um
        }
        .onChange(of: manager.blocks) { oldBlocks, _ in
            guard !suppressProgrammaticSync else { return }
            let serialized = manager.synchronizeDocument(from: oldBlocks)
            guard serialized != text else { return }
            text = serialized
            onTextChange(serialized)
        }
        .onChange(of: text) { _, newText in
            let serialized = serializeMarkdownBlocks(manager.blocks)
            guard newText != serialized else { return }
            loadEditorText(newText)
            applySearchJumpIfNeeded()
        }
        .onAppear { applySearchJumpIfNeeded() }
        .onChange(of: searchJumpRequest?.id) { _, _ in
            applySearchJumpIfNeeded()
        }
        .animation(.easeOut(duration: 0.18), value: isEditorReady)
        .onChange(of: isEditorReady) { _, isReady in
            onReadyStateChange(isReady)
        }
    }

    private func loadEditorText(_ newText: String) {
        suppressProgrammaticSync = true
        isEditorReady = false
        onReadyStateChange(false)
        manager.load(from: newText)
        let blockIDs = Set(manager.blocks.map(\.id))
        pendingInitialLayoutIDs = blockIDs

        if blockIDs.isEmpty {
            isEditorReady = true
            onReadyStateChange(true)
            Task { @MainActor in
                suppressProgrammaticSync = false
            }
            return
        }

        Task { @MainActor in
            await Task.yield()
            suppressProgrammaticSync = false
            if pendingInitialLayoutIDs.isEmpty {
                isEditorReady = true
            }
        }
    }

    private func handleInitialLayout(for blockID: UUID) {
        guard pendingInitialLayoutIDs.contains(blockID) else { return }
        pendingInitialLayoutIDs.remove(blockID)
        if pendingInitialLayoutIDs.isEmpty {
            isEditorReady = true
            onReadyStateChange(true)
        }
    }

    private func applySearchJumpIfNeeded() {
        guard let request = searchJumpRequest,
              request.fileURL == fileURL,
              lastHandledSearchJumpID != request.id else { return }

        lastHandledSearchJumpID = request.id
        focusSearchJump(at: request.location, centered: request.isCenteredScroll)
    }

    private func focusSearchJump(at absoluteLocation: Int, centered: Bool = false) {
        guard !manager.blocks.isEmpty else { return }

        let clampedLocation = max(0, absoluteLocation)
        var cursor = 0

        for (index, block) in manager.blocks.enumerated() {
            let blockLength = (block.content as NSString).length
            if clampedLocation <= cursor + blockLength {
                manager.registry.focus(block.id, at: .position(clampedLocation - cursor), centered: centered)
                return
            }

            cursor += blockLength
            if index < manager.blocks.count - 1 {
                let separatorLength = 2
                if clampedLocation < cursor + separatorLength {
                    manager.registry.focus(block.id, at: .end, centered: centered)
                    return
                }
                cursor += separatorLength
            }
        }

        if let lastBlock = manager.blocks.last {
            manager.registry.focus(lastBlock.id, at: .end, centered: centered)
        }
    }
}
