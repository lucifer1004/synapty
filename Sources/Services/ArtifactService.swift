import Foundation
import Observation
import os

/// Things agents finished making and handed over.
///
/// `present` IS A TRANSFER PLUS AN ANNOUNCEMENT, and it is built that way
/// rather than as a second mover: the artifact comes across the same
/// resident queue with the same limit, the same record and the same
/// attribution as everything else ([[ADR-0010]]). What it adds is that a
/// human is told it arrived.
///
/// STAGED, NOT RENDERED IN PLACE. The file lands in a directory this
/// application owns, and what the human sees is a card naming it — the
/// agent, the title in its own words, the size. Rendering arbitrary
/// agent-supplied content inline is the thing the quarantine frame exists
/// to make safe, and a card that can be opened deliberately is the smaller
/// promise ([[RFC-0013]] C-PRIMITIVES).
///
/// [[WI-2026-08-15-012]]
@MainActor @Observable final class ArtifactService {

    static weak var shared: ArtifactService?

    weak var transfers: TransferService?

    struct Artifact: Identifiable, Equatable {
        let id: UUID
        /// Who handed it over. There is no anonymous artifact.
        let agent: String
        /// The agent's own words, quoted rather than used as a heading.
        let title: String?
        let fileName: String
        /// Where it landed on this Mac.
        let localPath: String
        let arrivedAt: Date
        var transferID: UUID?

        var isReady: Bool { FileManager.default.fileExists(atPath: localPath) }

        var size: Int64? {
            let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }
    }

    private(set) var artifacts: [Artifact] = []

    private static let log = Logger(subsystem: "com.synapty.app", category: "Artifact")

    /// A directory this application owns, so nothing an agent sends lands
    /// among the human's own files or anywhere they did not expect.
    static var stagingDirectory: URL {
        let url = ConfigPaths.root.appendingPathComponent("presented")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fetch and announce. Returns the artifact's id, or nil when there is
    /// nothing to fetch with.
    @discardableResult
    func present(from source: FileEndpoint, agent: String, title: String?) -> UUID? {
        guard let transfers else { return nil }
        let name = source.fileName
        // A NAME OF OUR CHOOSING on this side. Two agents presenting
        // `report.pdf` must not overwrite each other, and a name an agent
        // controls must not decide a path on this Mac.
        let id = UUID()
        let staged = Self.stagingDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)

        let transferID = transfers.enqueue(
            from: source,
            to: FileEndpoint(hostID: nil, path: staged.deletingLastPathComponent().path),
            initiator: .agent(agent))

        artifacts.append(Artifact(
            id: id, agent: agent, title: title, fileName: name,
            localPath: staged.path, arrivedAt: Date(), transferID: transferID))
        Self.log.info("\(agent, privacy: .public) presented \(name, privacy: .public)")
        return id
    }

    /// The human is done with it. Removes the staged copy as well — leaving
    /// it would make this application a place files quietly accumulate.
    func dismiss(_ id: UUID) {
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return }
        let artifact = artifacts[idx]
        artifacts.remove(at: idx)
        let container = URL(fileURLWithPath: artifact.localPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: container)
    }
}
