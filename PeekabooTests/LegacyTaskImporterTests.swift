import Foundation
import SwiftData
import XCTest
@testable import Peekaboo

@MainActor
final class LegacyTaskImporterTests: XCTestCase {
    func testImportUpdatesOlderRowsAndArchivesPayload() async throws {
        let container = try makeContainer()
        let id = UUID()
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(container)
        context.insert(
            TaskItem(
                id: id,
                title: "Older local value",
                updatedAt: originalDate
            )
        )
        try context.save()

        let record = makeRecord(
            id: id,
            title: "Migrated through CloudKit context",
            updatedAt: originalDate.addingTimeInterval(60)
        )
        let payload = try makePayload([record])
        defer { try? FileManager.default.removeItem(at: payload.directory) }

        let importer = LegacyTaskImporter(modelContainer: container)
        let result = try await importer.importTasks(from: payload.url)

        XCTAssertEqual(result.payloadRecordCount, 1)
        XCTAssertEqual(result.uniqueRecordCount, 1)
        XCTAssertEqual(result.changedTaskCount, 1)
        XCTAssertNil(result.archiveWarning)

        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, id)
        XCTAssertEqual(tasks.first?.title, record.title)
        XCTAssertEqual(tasks.first?.status, .inProgress)
        XCTAssertEqual(tasks.first?.priority, .high)
        XCTAssertEqual(tasks.first?.manualOrder, 2_048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.url.path))
        XCTAssertEqual(try archivedPayloadCount(in: payload.directory), 1)
    }

    func testImportPreservesNewerCloudKitValue() async throws {
        let container = try makeContainer()
        let id = UUID()
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ModelContext(container)
        context.insert(
            TaskItem(
                id: id,
                title: "Newer CloudKit value",
                updatedAt: legacyDate.addingTimeInterval(120)
            )
        )
        try context.save()

        let payload = try makePayload([
            makeRecord(
                id: id,
                title: "Stale legacy value",
                updatedAt: legacyDate
            )
        ])
        defer { try? FileManager.default.removeItem(at: payload.directory) }

        let importer = LegacyTaskImporter(modelContainer: container)
        let result = try await importer.importTasks(from: payload.url)

        XCTAssertEqual(result.changedTaskCount, 0)
        XCTAssertNil(result.archiveWarning)
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Newer CloudKit value")
    }

    func testImportDeduplicatesPayloadUsingNewestRecord() async throws {
        let container = try makeContainer()
        let id = UUID()
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = try makePayload([
            makeRecord(id: id, title: "Older", updatedAt: olderDate),
            makeRecord(
                id: id,
                title: "Newest",
                updatedAt: olderDate.addingTimeInterval(60)
            )
        ])
        defer { try? FileManager.default.removeItem(at: payload.directory) }

        let importer = LegacyTaskImporter(modelContainer: container)
        let result = try await importer.importTasks(from: payload.url)

        XCTAssertEqual(result.payloadRecordCount, 2)
        XCTAssertEqual(result.uniqueRecordCount, 1)
        XCTAssertEqual(result.changedTaskCount, 1)
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Newest")
    }

    func testArchiveFailureDoesNotReplayCloudKitChanges() async throws {
        let container = try makeContainer()
        let id = UUID()
        let payload = try makePayload([
            makeRecord(
                id: id,
                title: "Imported once",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        defer { try? FileManager.default.removeItem(at: payload.directory) }
        let importer = LegacyTaskImporter(modelContainer: container)
        let failingArchive: LegacyTaskImporter.ArchivePayload = { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        let firstResult = try await importer.importTasks(
            from: payload.url,
            archivePayload: failingArchive
        )
        let secondResult = try await importer.importTasks(
            from: payload.url,
            archivePayload: failingArchive
        )

        XCTAssertEqual(firstResult.changedTaskCount, 1)
        XCTAssertNotNil(firstResult.archiveWarning)
        XCTAssertEqual(secondResult.changedTaskCount, 0)
        XCTAssertNotNil(secondResult.archiveWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.url.path))
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, id)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: TaskItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeRecord(
        id: UUID,
        title: String,
        updatedAt: Date
    ) -> LegacyTaskRecord {
        LegacyTaskRecord(
            id: id,
            title: title,
            statusRaw: TaskStatus.inProgress.rawValue,
            priorityRaw: TaskPriority.high.rawValue,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            completedAt: nil,
            manualOrder: 2_048
        )
    }

    private func makePayload(
        _ records: [LegacyTaskRecord]
    ) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            LegacyTaskImporter.pendingFileName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(records).write(to: url)
        return (directory, url)
    }

    private func archivedPayloadCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("legacy-tasks-imported-") }
            .count
    }
}
