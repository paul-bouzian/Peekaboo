import Foundation
import SwiftData
import XCTest
@testable import Peekaboo

@MainActor
final class LegacyTaskImporterTests: XCTestCase {
    func testImportReplacesStagedRowsAndArchivesPayload() throws {
        let container = try ModelContainer(
            for: TaskItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let id = UUID()
        let context = ModelContext(container)
        context.insert(TaskItem(id: id, title: "Staged locally"))
        try context.save()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingURL = directory.appendingPathComponent(
            LegacyTaskImporter.pendingFileName
        )
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = LegacyTaskRecord(
            id: id,
            title: "Migrated through CloudKit context",
            statusRaw: TaskStatus.inProgress.rawValue,
            priorityRaw: TaskPriority.high.rawValue,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(60),
            completedAt: nil,
            manualOrder: 2_048
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode([record]).write(to: pendingURL)

        XCTAssertEqual(
            try LegacyTaskImporter.importTasks(
                from: pendingURL,
                into: container
            ),
            1
        )

        let refreshedContext = ModelContext(container)
        let tasks = try refreshedContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, id)
        XCTAssertEqual(tasks.first?.title, record.title)
        XCTAssertEqual(tasks.first?.status, .inProgress)
        XCTAssertEqual(tasks.first?.priority, .high)
        XCTAssertEqual(tasks.first?.manualOrder, 2_048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("legacy-tasks-imported-") }
                .count,
            1
        )
    }
}
