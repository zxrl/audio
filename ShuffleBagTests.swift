import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private func track(_ name: String) -> URL {
    URL(fileURLWithPath: "/music/\(name).mp3")
}

private func testEachTrackPlaysOncePerCycle() throws {
    let tracks = ["a", "b", "c", "d"].map(track)
    var bag = ShuffleBag()
    var firstCycle: [URL] = []

    for _ in tracks {
        guard let next = bag.draw(available: tracks, after: firstCycle.last) else {
            throw TestFailure.assertion("bag ended before every track was drawn")
        }
        firstCycle.append(next)
    }

    try expect(Set(firstCycle) == Set(tracks), "first cycle did not contain every track exactly once")

    let nextCycleFirst = bag.draw(available: tracks, after: firstCycle.last)
    try expect(nextCycleFirst != nil, "bag did not refill after the first cycle")
    try expect(nextCycleFirst != firstCycle.last, "bag repeated across the refill boundary")
}

private func testAddedTrackJoinsCurrentCycle() throws {
    let a = track("a")
    let b = track("b")
    let c = track("c")
    var bag = ShuffleBag()

    bag.beginCycle(available: [a, b], currentTrack: a)
    let draws = [
        bag.draw(available: [a, b, c], after: a),
        bag.draw(available: [a, b, c], after: nil),
    ].compactMap { $0 }

    try expect(Set(draws) == Set([b, c]), "new track did not join the active cycle")
}

private func testRemovedTrackLeavesCurrentCycle() throws {
    let a = track("a")
    let b = track("b")
    let c = track("c")
    var bag = ShuffleBag()

    bag.beginCycle(available: [a, b, c], currentTrack: a)
    let next = bag.draw(available: [a, c], after: a)

    try expect(next == c, "removed track remained eligible")
    try expect(!bag.remaining.contains(b), "removed track remained queued")
}

private func testRestoredPlayedTrackStaysConsumed() throws {
    let a = track("a")
    let b = track("b")
    let c = track("c")
    let d = track("d")
    var bag = ShuffleBag()

    bag.beginCycle(available: [a, b, c, d], currentTrack: a)
    bag.markPlayed(b, available: [a, b, c, d])

    let firstUnplayed = bag.draw(available: [a, c, d], after: b)
    let secondUnplayed = bag.draw(available: [a, b, c, d], after: firstUnplayed)

    try expect(
        Set([firstUnplayed, secondUnplayed].compactMap { $0 }) == Set([c, d]),
        "restored played track became eligible before the cycle boundary"
    )
}

private func testManualSelectionConsumesQueuedTrack() throws {
    let a = track("a")
    let b = track("b")
    let c = track("c")
    var bag = ShuffleBag()

    bag.beginCycle(available: [a, b, c], currentTrack: a)
    bag.markPlayed(b, available: [a, b, c])
    let next = bag.draw(available: [a, b, c], after: b)

    try expect(next == c, "manual selection remained in the bag")
}

@main
private struct ShuffleBagTestRunner {
    static func main() {
        do {
            try testEachTrackPlaysOncePerCycle()
            try testAddedTrackJoinsCurrentCycle()
            try testRemovedTrackLeavesCurrentCycle()
            try testRestoredPlayedTrackStaysConsumed()
            try testManualSelectionConsumesQueuedTrack()
            print("ShuffleBag tests passed")
        } catch {
            FileHandle.standardError.write(Data("ShuffleBag tests failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
