import XCTest
@testable import MarkLens

final class PerformanceBenchmarksTests: XCTestCase {
    private let clock = ContinuousClock()
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
        tempDirectoryURL = nil
    }

    func testWorkspaceTreeBuildBenchmark_largeWorkspace() throws {
        try makeWorkspaceFixture(
            root: tempDirectoryURL,
            directoryCount: 120,
            markdownFilesPerDirectory: 24,
            ignoredDirectoriesEvery: 8
        )

        benchmark(name: "workspace_tree_build_large_workspace") {
            _ = WorkspaceTreeBuilder.buildTree(at: tempDirectoryURL, pinnedURLs: [])
        }
    }

    @MainActor
    func testDocumentSearchBenchmark_largeDocument() {
        let document = makeLargeDocument(blockCount: 4_000, lineLength: 90)
        let search = DocumentSearch()

        benchmark(name: "document_search_large_document") {
            search.update(documentText: document, query: "target-needle")
            XCTAssertGreaterThan(search.matchCount, 0)
        }
    }

    @MainActor
    func testBlocksManagerIncrementalKindSyncBenchmark_singleBlockEdit() {
        let manager = BlocksManager()
        manager.load(from: makeLargeDocument(blockCount: 3_000, lineLength: 72))

        let oldBlocks = manager.blocks
        manager.blocks[1_500].content = "# Reclassified heading"

        benchmark(name: "blocks_manager_incremental_kind_sync_single_block_edit") {
            manager.syncBlockKinds(from: oldBlocks)
        }
    }

    @MainActor
    func testBlocksEditorSyncBenchmark_singleBlockEdit() {
        let manager = BlocksManager()
        manager.load(from: makeLargeDocument(blockCount: 3_000, lineLength: 72))

        let oldBlocks = manager.blocks
        manager.blocks[1_500].content = "# Reclassified heading"

        benchmark(name: "blocks_editor_sync_single_block_edit") {
            let serialized = manager.synchronizeDocument(from: oldBlocks)
            XCTAssertFalse(serialized.isEmpty)
        }
    }

    func testSerializeMarkdownBlocksBenchmark_largeDocument() {
        let blocks = parseMarkdownBlocks(makeLargeDocument(blockCount: 3_000, lineLength: 72))

        benchmark(name: "serialize_markdown_blocks_large_document") {
            let serialized = serializeMarkdownBlocks(blocks)
            XCTAssertFalse(serialized.isEmpty)
        }
    }

    private func benchmark(
        name: String,
        warmupIterations: Int = 2,
        measuredIterations: Int = 8,
        block: () -> Void
    ) {
        for _ in 0..<warmupIterations {
            block()
        }

        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(measuredIterations)

        for _ in 0..<measuredIterations {
            let start = clock.now
            block()
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            samplesMs.append(ms)
        }

        let average = samplesMs.reduce(0, +) / Double(samplesMs.count)
        let minimum = samplesMs.min() ?? 0
        let maximum = samplesMs.max() ?? 0
        let sorted = samplesMs.sorted()
        let median = sorted[sorted.count / 2]

        let line = "BENCHMARK\t\(name)\titerations=\(measuredIterations)\tavg_ms=\(format(average))\tmedian_ms=\(format(median))\tmin_ms=\(format(minimum))\tmax_ms=\(format(maximum))"
        print(line)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func makeWorkspaceFixture(
        root: URL,
        directoryCount: Int,
        markdownFilesPerDirectory: Int,
        ignoredDirectoriesEvery: Int
    ) throws {
        var ignoredNames: [String] = []

        for directoryIndex in 0..<directoryCount {
            let directoryName = String(format: "Section-%03d", directoryIndex)
            let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            if directoryIndex.isMultiple(of: ignoredDirectoriesEvery) {
                ignoredNames.append(directoryName)
            }

            for fileIndex in 0..<markdownFilesPerDirectory {
                let fileURL = directoryURL.appendingPathComponent("Note-\(fileIndex).md")
                try makeParagraph(seed: directoryIndex * 1000 + fileIndex, lineLength: 64)
                    .write(to: fileURL, atomically: true, encoding: .utf8)
            }

            let ignoredTextURL = directoryURL.appendingPathComponent("Skip.txt")
            try "not markdown".write(to: ignoredTextURL, atomically: true, encoding: .utf8)
        }

        if !ignoredNames.isEmpty {
            let gitignore = ignoredNames.map { "\($0)/" }.joined(separator: "\n")
            try gitignore.write(
                to: root.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func makeLargeDocument(blockCount: Int, lineLength: Int) -> String {
        (0..<blockCount).map { index in
            switch index % 6 {
            case 0:
                return "# Heading \(index)"
            case 1:
                return "- [\(index.isMultiple(of: 2) ? "x" : " ")] Task \(index)"
            case 2:
                return """
                ```swift
                let value\(index) = \(index)
                print(value\(index))
                ```
                """
            case 3:
                return """
                | Column | Value |
                | --- | --- |
                | Row \(index) | \(index * 2) |
                """
            case 4:
                return makeParagraph(seed: index, lineLength: lineLength) + " target-needle"
            default:
                return makeParagraph(seed: index, lineLength: lineLength)
            }
        }
        .joined(separator: "\n\n")
    }

    private func makeParagraph(seed: Int, lineLength: Int) -> String {
        let words = (0..<max(8, lineLength / 6)).map { offset in
            "word\(seed)-\(offset)"
        }
        return words.joined(separator: " ")
    }
}
