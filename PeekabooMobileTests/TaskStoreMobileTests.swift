import SwiftData
import XCTest
@testable import PeekabooMobile

final class TaskStoreMobileTests: XCTestCase {
    @MainActor
    func testMobileUsesSharedTaskSemanticsWithoutCloudKitInTests() throws {
        let configuration = PersistenceController.makeConfiguration(inMemory: true)
        XCTAssertNil(configuration.cloudKitContainerIdentifier)

        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let task = try XCTUnwrap(
            store.create(title: "  From   iPhone ", priority: .high, status: .backlog)
        )

        XCTAssertEqual(task.title, "From iPhone")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.status, .backlog)

        XCTAssertTrue(store.update(task, status: .todo))
        XCTAssertEqual(task.status, .todo)
    }

    @MainActor
    func testPrimaryActionAdvancesEveryWorkflowStatus() throws {
        let completionDate = Date(timeIntervalSince1970: 2_000)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container, now: { completionDate })
        let backlog = try XCTUnwrap(store.create(title: "Backlog", status: .backlog))
        let todo = try XCTUnwrap(store.create(title: "To do"))
        let inProgress = try XCTUnwrap(
            store.create(title: "In Progress", status: .inProgress)
        )
        let done = try XCTUnwrap(store.create(title: "Done", status: .done))

        XCTAssertTrue(store.performPrimaryAction(backlog))
        XCTAssertEqual(backlog.status, .todo)
        XCTAssertNil(backlog.completedAt)

        XCTAssertTrue(store.performPrimaryAction(todo))
        XCTAssertEqual(todo.status, .inProgress)
        XCTAssertNil(todo.completedAt)

        XCTAssertTrue(store.performPrimaryAction(inProgress))
        XCTAssertEqual(inProgress.status, .done)
        XCTAssertEqual(inProgress.completedAt, completionDate)

        XCTAssertTrue(store.performPrimaryAction(done))
        XCTAssertEqual(done.status, .todo)
        XCTAssertNil(done.completedAt)
    }

    func testEditorPatchIncludesOnlyFieldsChangedByTheUser() {
        let baseline = MobileTaskEditBaseline(
            title: "Original",
            priority: .low,
            status: .todo
        )

        let patch = baseline.patch(
            title: "Renamed",
            priority: .low,
            status: .todo
        )

        XCTAssertEqual(patch.title, "Renamed")
        XCTAssertNil(patch.priority)
        XCTAssertNil(patch.status)
    }
}
