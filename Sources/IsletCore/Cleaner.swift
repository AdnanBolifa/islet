import Foundation

public struct Artifact: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    /// Shared tool caches (Gradle, npm, Xcode…): safe to delete but slow to re-download, so not preselected.
    public var isCache = false
    public var id: URL { url }
}

public enum Cleaner {
    /// Folder name → project files that must sit next to it. A folder only counts as a build
    /// artifact when its parent is a real project, so a source folder that happens to be named
    /// "build" is never touched. An empty list means "always an artifact".
    static let directories: [String: [String]] = [
        "build": ["pubspec.yaml", "build.gradle", "build.gradle.kts", "package.json", "Podfile",
                  "CMakeLists.txt", "pyproject.toml", "setup.py"],
        ".dart_tool": ["pubspec.yaml"],
        "node_modules": ["package.json"],
        ".next": ["package.json"],
        "Pods": ["Podfile"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"],
        ".cxx": ["build.gradle", "build.gradle.kts"],
        "__pycache__": [],
        "DerivedData": [],
    ]

    static let fileExtensions: Set<String> = ["apk", "aab", "ipa"]

    static let developerCaches = [
        "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
        "Library/Caches/CocoaPods", "Library/Caches/org.swift.swiftpm",
        ".gradle/caches", ".npm/_cacache",
    ]

    /// Developer tool caches in the home folder that exist on this Mac.
    public static func scanDeveloperCaches(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Artifact] {
        developerCaches
            .map { home.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Artifact(url: $0, size: allocatedSize(of: $0), isCache: true) }
            .filter { $0.size > 0 }
    }

    /// Finds build artifacts under the given folders, largest first.
    public static func scan(_ roots: [URL]) -> [Artifact] {
        var found: [URL: Artifact] = [:] // keyed so overlapping roots don't list things twice
        for root in roots {
            walk(root.standardizedFileURL) { found[$0.url] = $0 }
        }
        return found.values.sorted { $0.size > $1.size }
    }

    /// Moves artifacts to the Trash (recoverable) and reports what moved.
    public static func trash(_ items: [Artifact]) -> (trashed: Set<URL>, freed: Int64) {
        var trashed = Set<URL>()
        var freed: Int64 = 0
        for item in items where (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil {
            trashed.insert(item.url)
            freed += item.size
        }
        return (trashed, freed)
    }

    private static func walk(_ dir: URL, _ emit: (Artifact) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        let siblings = Set(items.map(\.lastPathComponent))

        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let name = item.lastPathComponent

            if values?.isDirectory == true {
                if name == ".git" { continue }
                if let markers = directories[name], markers.isEmpty || markers.contains(where: siblings.contains) {
                    emit(Artifact(url: item, size: allocatedSize(of: item)))
                } else {
                    walk(item, emit)
                }
            } else if fileExtensions.contains(item.pathExtension.lowercased()) {
                emit(Artifact(url: item, size: allocatedSize(of: item)))
            }
        }
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        if let values = try? url.resourceValues(forKeys: [key, .isRegularFileKey]), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key])
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
