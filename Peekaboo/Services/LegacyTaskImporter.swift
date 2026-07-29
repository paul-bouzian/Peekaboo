import Foundation
import SwiftData

struct LegacyTaskRecord: Codable, Sendable {
    let id: UUID
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let manualOrder: Int64?
}

struct LegacyTaskImportResult: Sendable {
    let payloadRecordCount: Int
    let uniqueRecordCount: Int
    let changedTaskCount: Int
    let archiveWarning: String?
}

@ModelActor
actor LegacyTaskImporter {
    typealias ArchivePayload = @Sendable (URL, URL) throws -> Void

    static let pendingFileName = "legacy-tasks.json"
    private static let processingFileName = "legacy-tasks-processing.json"

    func importIfPresent() throws -> LegacyTaskImportResult? {
        let fileManager = FileManager.default
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
        let pendingURL = migrationDirectory.appendingPathComponent(Self.pendingFileName)
        let processingURL = migrationDirectory.appendingPathComponent(
            Self.processingFileName
        )

        let payloadURL: URL
        if fileManager.fileExists(atPath: processingURL.path) {
            payloadURL = processingURL
        } else if fileManager.fileExists(atPath: pendingURL.path) {
            try fileManager.moveItem(at: pendingURL, to: processingURL)
            payloadURL = processingURL
        } else {
            return nil
        }

        return try importTasks(from: payloadURL)
    }

    func importTasks(
        from payloadURL: URL,
        archivePayload: ArchivePayload = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws -> LegacyTaskImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payloadRecords = try decoder.decode(
            [LegacyTaskRecord].self,
            from: Data(contentsOf: payloadURL)
        )
        let records = deduplicated(payloadRecords)

        let existingTasks = try modelContext.fetch(FetchDescriptor<TaskItem>())
        let existingByID = Dictionary(grouping: existingTasks, by: \.id)
        var changedTaskCount = 0

        for record in records {
            guard let replicas = existingByID[record.id], !replicas.isEmpty else {
                modelContext.insert(TaskItem(record))
                changedTaskCount += 1
                continue
            }

            var changedReplica = false
            for task in replicas where task.updatedAt < record.updatedAt {
                task.apply(record)
                changedReplica = true
            }
            if changedReplica {
                changedTaskCount += 1
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }

        let archiveURL = payloadURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "legacy-tasks-imported-\(UUID().uuidString).json"
            )
        let archiveWarning: String?
        do {
            try archivePayload(payloadURL, archiveURL)
            archiveWarning = nil
        } catch {
            let nsError = error as NSError
            archiveWarning = "\(nsError.domain) (\(nsError.code)): "
                + nsError.localizedDescription
        }

        return LegacyTaskImportResult(
            payloadRecordCount: payloadRecords.count,
            uniqueRecordCount: records.count,
            changedTaskCount: changedTaskCount,
            archiveWarning: archiveWarning
        )
    }

    private func deduplicated(
        _ records: [LegacyTaskRecord]
    ) -> [LegacyTaskRecord] {
        var newestByID: [UUID: LegacyTaskRecord] = [:]
        for record in records {
            if let existing = newestByID[record.id],
               existing.updatedAt >= record.updatedAt {
                continue
            }
            newestByID[record.id] = record
        }
        return newestByID.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }
}

private extension TaskItem {
    convenience init(_ record: LegacyTaskRecord) {
        self.init(
            id: record.id,
            title: record.title,
            status: TaskStatus(rawValue: record.statusRaw) ?? .todo,
            priority: TaskPriority(rawValue: record.priorityRaw) ?? .none,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            completedAt: record.completedAt,
            manualOrder: record.manualOrder
        )
    }

    func apply(_ record: LegacyTaskRecord) {
        title = record.title
        status = TaskStatus(rawValue: record.statusRaw) ?? .todo
        priority = TaskPriority(rawValue: record.priorityRaw) ?? .none
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        completedAt = record.completedAt
        manualOrder = record.manualOrder
    }
}
