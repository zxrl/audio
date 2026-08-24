import Foundation

struct ShuffleBag {
    private(set) var remaining: [URL] = []
    private(set) var played: Set<URL> = []
    private var hasActiveCycle = false

    mutating func beginCycle(available tracks: [URL], currentTrack: URL?) {
        let available = normalized(tracks)
        let current = currentTrack.map(canonical)

        played.removeAll(keepingCapacity: true)
        if let current, available.contains(current) {
            played.insert(current)
        }

        remaining = available.filter { $0 != current }
        remaining.shuffle()
        hasActiveCycle = true
    }

    mutating func markPlayed(_ track: URL, available tracks: [URL]) {
        let track = canonical(track)

        if !hasActiveCycle {
            beginCycle(available: tracks, currentTrack: track)
            return
        }

        reconcile(available: tracks)
        remaining.removeAll { $0 == track }
        played.insert(track)
    }

    mutating func draw(available tracks: [URL], after currentTrack: URL?) -> URL? {
        let available = normalized(tracks)

        if !hasActiveCycle {
            beginCycle(available: available, currentTrack: nil)
        } else {
            reconcile(available: available)
        }

        if remaining.isEmpty {
            played.removeAll(keepingCapacity: true)
            remaining = available
            remaining.shuffle()
            avoidImmediateBoundaryRepeat(after: currentTrack)
            hasActiveCycle = true
        }

        guard let next = remaining.popLast() else { return nil }
        played.insert(next)
        return next
    }

    mutating func remove(_ track: URL) {
        let track = canonical(track)
        remaining.removeAll { $0 == track }
    }

    private mutating func reconcile(available tracks: [URL]) {
        let available = normalized(tracks)
        let availableSet = Set(available)

        remaining.removeAll { !availableSet.contains($0) }

        let queued = Set(remaining)
        let additions = available.filter {
            !played.contains($0) && !queued.contains($0)
        }

        guard !additions.isEmpty else { return }
        remaining.append(contentsOf: additions)
        remaining.shuffle()
    }

    private mutating func avoidImmediateBoundaryRepeat(after currentTrack: URL?) {
        guard
            remaining.count > 1,
            let current = currentTrack.map(canonical),
            remaining.last == current
        else {
            return
        }

        let replacementIndex = Int.random(in: 0..<(remaining.count - 1))
        remaining.swapAt(replacementIndex, remaining.count - 1)
    }

    private func normalized(_ tracks: [URL]) -> [URL] {
        var seen = Set<URL>()
        return tracks
            .map(canonical)
            .filter { seen.insert($0).inserted }
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}
