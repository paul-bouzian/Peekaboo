import Foundation
import SwiftData

struct LegacyTaskRecord: Codable {
    let id: UUID
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let manualOrder: Int64?
}

@MainActor
enum LegacyTaskImporter {
    static let pendingFileName = "legacy-tasks.json"

    static func importIfPresent(
        into container: ModelContainer,
        fileManager: FileManager = .default
    ) throws -> Int {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let migrationDirectory = applicationSupportURL.appendingPathComponent(
            "Peekaboo",
            isDirectory: true
        )
        let pendingURL = migrationDirectory.appendingPathComponent(pendingFileName)
        guard fileManager.fileExists(atPath: pendingURL.path) else { return 0 }

        return try importTasks(
            from: pendingURL,
            into: container,
            fileManager: fileManager
        )
    }

    static func importTasks(
        from pendingURL: URL,
        into container: ModelContainer,
        fileManager: FileManager = .default
    ) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let records = try decoder.decode(
            [LegacyTaskRecord].self,
            from: Data(contentsOf: pendingURL)
        )

        let context = ModelContext(container)
        let migratedIDs = Set(records.map(\.id))
        let existingTasks = try context.fetch(FetchDescriptor<TaskItem>())
        for task in existingTasks where migratedIDs.contains(task.id) {
            context.delete(task)
        }
        for record in records {
            context.insert(
                TaskItem(
                    id: record.id,
                    title: record.title,
                    status: TaskStatus(rawValue: record.statusRaw) ?? .todo,
                    priority: TaskPriority(rawValue: record.priorityRaw) ?? .none,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    completedAt: record.completedAt,
                    manualOrder: record.manualOrder
                )
            )
        }
        if context.hasChanges {
            try context.save()
        }

        let archiveURL = pendingURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "legacy-tasks-imported-\(UUID().uuidString).json"
            )
        try fileManager.moveItem(at: pendingURL, to: archiveURL)
        return records.count
    }
}
