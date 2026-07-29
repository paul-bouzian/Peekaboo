import Foundation
import SwiftData

@main
struct LegacyStoreMigrator {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(
                Data("Usage: migrate_legacy_store <source.store> <output.json>\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }

        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MigrationError.missingSource(sourceURL)
        }

        let sourceConfiguration = ModelConfiguration(
            "legacy",
            url: sourceURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let sourceContainer = try ModelContainer(
            for: TaskItem.self,
            configurations: sourceConfiguration
        )
        let sourceContext = ModelContext(sourceContainer)
        let sourceTasks = try sourceContext.fetch(FetchDescriptor<TaskItem>())
        let records = sourceTasks.map(LegacyTaskRecord.init)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: outputURL, options: .atomic)

        print("Exported \(records.count) task(s) for in-app CloudKit migration.")
    }
}

private struct LegacyTaskRecord: Codable {
    let id: UUID
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let manualOrder: Int64?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        statusRaw = task.statusRaw
        priorityRaw = task.priorityRaw
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        completedAt = task.completedAt
        manualOrder = task.manualOrder
    }
}

private enum MigrationError: LocalizedError {
    case missingSource(URL)

    var errorDescription: String? {
        switch self {
        case .missingSource(let url):
            "Legacy store not found at \(url.path)"
        }
    }
}
