import XCTest
@testable import IsletCore

final class CleanerTests: XCTestCase {
    func testFindsOnlyRealArtifacts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        for path in [
            "app/pubspec.yaml", "app/build/out.bin", "app/.dart_tool/cache",
            "app/lib/build/keep.dart",          // "build" with no project file beside it: source, keep
            "app/.git/build/obj",               // never look inside .git
            "app/release.apk",
            "web/package.json", "web/node_modules/a/index.js",
            "loose/node_modules/x.js",          // no package.json: keep
        ] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        let found = Set(Cleaner.scan([root, root.appendingPathComponent("app")]).map {
            $0.url.pathComponents.suffix(2).joined(separator: "/")
        })
        XCTAssertEqual(found, ["app/build", "app/.dart_tool", "app/release.apk", "web/node_modules"])
    }
}

final class StatsTests: XCTestCase {
    func testReadsMemoryAndDisk() {
        let memory = MemoryInfo.current()
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertGreaterThan(DiskInfo.current().total, 0)

        var cpu = CPUSampler()
        _ = cpu.sample()
        XCTAssert((0...1).contains(cpu.sample()))

        var network = NetworkSampler()
        _ = network.sample()
        let speed = network.sample()
        XCTAssert(speed.down >= 0 && speed.up >= 0)

        // nil is fine on Intel; on Apple Silicon it must be a plausible reading.
        if let celsius = TemperatureReader().cpuCelsius() { XCTAssert((1...130).contains(celsius)) }
    }
}

final class MediaTests: XCTestCase {
    func testCleansBrowserTabTitles() {
        XCTAssertEqual(cleanMediaTabTitle("(3) Lofi beats - YouTube"), "Lofi beats")
        XCTAssertEqual(cleanMediaTabTitle("Song - Artist - YouTube Music"), "Song - Artist")
        XCTAssertEqual(cleanMediaTabTitle("Plain title"), "Plain title")
    }
}
