@testable import AethergramCore
import Foundation
import Testing

// MARK: - Clock and calendar

/// UTC Gregorian throughout. A test that read the machine's calendar would
/// pass or fail on where the machine sits, and hour-of-day is one of the two
/// clock-derived fields the payload carries.
let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}()

func testDate(year: Int, month: Int, day: Int, hour: Int = 12) throws -> Date {
    let components = DateComponents(year: year, month: month, day: day, hour: hour)
    return try #require(testCalendar.date(from: components))
}

/// A clock that advances one step per read, so two signals recorded in a row
/// carry distinct `recordedAt` values and an order assertion can rest on the
/// timestamps rather than only on the names.
func steppingClock(from start: Date, step: TimeInterval = 1) -> @Sendable () -> Date {
    let reads = Counter()
    return { start.addingTimeInterval(step * Double(reads.nextIndex())) }
}

/// A clock pinned to one instant, for the payload assertions where the
/// interesting value is the calendar field rather than the ordering.
func fixedClock(at date: Date) -> @Sendable () -> Date {
    { date }
}

// MARK: - Recorder assembly

/// `transmitInterval` is deliberately long: a `.retryable` outcome schedules a
/// background retry, and a short interval would let that task fire mid-test
/// and race the assertions.
func testConfiguration(
    signalPrefix: String = "",
    batchSize: Int = 100,
    queueLimit: Int = 1000,
    transmitInterval: TimeInterval = 3600,
    maxBackoffInterval: TimeInterval = 7200
) -> AethergramConfiguration {
    AethergramConfiguration(
        signalPrefix: signalPrefix,
        logSubsystem: testLogSubsystem,
        batchSize: batchSize,
        queueLimit: queueLimit,
        transmitInterval: transmitInterval,
        maxBackoffInterval: maxBackoffInterval
    )
}

/// A recorder plus every collaborator a test needs to interrogate.
struct RecorderFixture {
    let recorder: SignalRecorder
    let transport: SpyTransport
    let storage: RecordingQueueStorage
    let retention: SpyRetentionStore
    /// Invocation count for `clientUserProvider`. Zero before a grant is the
    /// assertion that no identifier is minted ahead of the answer.
    let clientUserCalls: Counter
    /// Invocation count for `environmentProvider`. Zero before a grant is the
    /// assertion that the payload is not even read.
    let environmentCalls: Counter
}

func makeFixture(
    directory: URL,
    configuration: AethergramConfiguration = testConfiguration(),
    transport: SpyTransport = SpyTransport(),
    retention: SpyRetentionStore = SpyRetentionStore(),
    environment: [String: String] = ["env.key": "env-value"],
    clientUser: String? = "client-user",
    calendar: Calendar = testCalendar,
    now: @escaping @Sendable () -> Date
) -> RecorderFixture {
    let storage = RecordingQueueStorage(directory: directory)
    let clientUserCalls = Counter()
    let environmentCalls = Counter()
    let recorder = SignalRecorder(
        configuration: configuration,
        transport: transport,
        queueStorage: storage,
        retentionStore: retention,
        clientUserProvider: {
            clientUserCalls.increment()
            return clientUser
        },
        environmentProvider: {
            environmentCalls.increment()
            return environment
        },
        calendar: calendar,
        now: now
    )
    // Observations of the double settle the writer first; see `settle`.
    storage.settle = { [weak recorder] in recorder?.writer.waitForPendingWrites() }
    return RecorderFixture(
        recorder: recorder,
        transport: transport,
        storage: storage,
        retention: retention,
        clientUserCalls: clientUserCalls,
        environmentCalls: environmentCalls
    )
}
