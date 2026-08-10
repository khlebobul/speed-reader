import Foundation

/// Manages a list of recently opened file paths, persisted in UserDefaults.
final class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()

    private let key = "recentFilePaths"
    private let progressKey = "readingProgress"
    private let maxCount = 10

    @Published private(set) var files: [URL] = []

    /// The file currently open in the File tab (set by FileInputView).
    @Published var currentFile: URL?

    /// When non-nil, the user chose to resume reading from this word index.
    @Published var resumeWordIndex: Int?

    init() {
        load()
    }

    func add(_ url: URL) {
        var paths = storedPaths()
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        UserDefaults.standard.set(paths, forKey: key)
        load()
    }

    func remove(_ url: URL) {
        var paths = storedPaths()
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: key)
        clearProgress(for: url)
        load()
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: progressKey)
        files = []
    }

    // MARK: - Reading Progress

    func saveProgress(for url: URL, wordIndex: Int) {
        var dict = progressDict()
        dict[url.path] = wordIndex
        UserDefaults.standard.set(dict, forKey: progressKey)
    }

    func savedProgress(for url: URL) -> Int? {
        let index = progressDict()[url.path]
        guard let index, index > 0 else { return nil }
        return index
    }

    func clearProgress(for url: URL) {
        var dict = progressDict()
        dict.removeValue(forKey: url.path)
        UserDefaults.standard.set(dict, forKey: progressKey)
    }

    // MARK: - Private

    private func storedPaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func progressDict() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: progressKey) as? [String: Int] ?? [:]
    }

    private func load() {
        files = storedPaths()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
