import Foundation

struct RecentURLEntry: Codable, Identifiable {
    let urlString: String
    let title: String?
    let addedAt: Date

    var id: String { urlString }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        // Extract domain from URL
        if let url = URL(string: urlString), let host = url.host {
            return host
        }
        return urlString
    }
}

final class RecentURLsManager: ObservableObject {
    static let shared = RecentURLsManager()

    private let key = "recentURLs"
    private let maxCount = 10

    @Published private(set) var entries: [RecentURLEntry] = []

    init() {
        load()
    }

    func add(_ urlString: String, title: String? = nil) {
        var list = entries
        list.removeAll { $0.urlString == urlString }
        let entry = RecentURLEntry(urlString: urlString, title: title, addedAt: Date())
        list.insert(entry, at: 0)
        if list.count > maxCount {
            list = Array(list.prefix(maxCount))
        }
        entries = list
        save()
    }

    func remove(_ entry: RecentURLEntry) {
        entries.removeAll { $0.urlString == entry.urlString }
        save()
    }

    func clearAll() {
        entries = []
        save()
    }

    // MARK: - Private

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentURLEntry].self, from: data) else {
            return
        }
        entries = decoded
    }
}
