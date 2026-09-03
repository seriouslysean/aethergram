import Foundation
import Testing

/// Test-side temp-dir mailbox. The trait creates a unique URL, runs the test,
/// then removes the directory tree even on failure.
public enum TestTempDirectory {
    @TaskLocal public static var url: URL?
}

/// Allocates a per-test `URL` under `FileManager.default.temporaryDirectory`
/// and removes it on teardown. Use for any test touching disk I/O, so the test
/// process leaves no scratch behind.
public struct TempDirectoryTrait: TestTrait, SuiteTrait, TestScoping, Sendable {
    /// Recursive so a suite can be decorated once and every test in it gets its
    /// own directory, rather than each `@Test` repeating the trait. Scoping
    /// still runs per test case, so no two tests share a path.
    public var isRecursive: Bool {
        true
    }

    @preconcurrency
    public func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aethergram-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await TestTempDirectory.$url.withValue(dir) {
            try await function()
        }
    }
}

public extension Trait where Self == TempDirectoryTrait {
    /// Decorate `@Test` or `@Suite` with an ephemeral temp directory. The test
    /// body reads `TestTempDirectory.url` for the path.
    static var tempDirectory: TempDirectoryTrait {
        TempDirectoryTrait()
    }
}
