import Foundation

struct HostEntry: Identifiable, Codable {
    var id = UUID()
    var label: String
    var address: String
    var port: Int = 22
    var username: String
    var sshKeyPath: String?
}

@MainActor final class HostStore: ObservableObject {
    @Published var hosts: [HostEntry] = []

    private static var storageURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    init() {
        load()
    }

    func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HostEntry].self, from: data)
        else { return }
        hosts = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    func addHost(_ host: HostEntry) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: HostEntry) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
            save()
        }
    }

    func removeHost(_ host: HostEntry) {
        hosts.removeAll { $0.id == host.id }
        save()
    }
}
