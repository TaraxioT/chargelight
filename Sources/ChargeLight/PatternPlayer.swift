import Foundation

/// Shows an ``LEDSpec`` through a function that writes one state: a fixed
/// state is written once, a pattern is stepped through on a background thread
/// until something else is shown.
public final class PatternPlayer {
    private let write: (LEDState) throws -> Void
    private let condition = NSCondition()
    /// Serialises writes, so a pattern step that was about to be written
    /// cannot land after the state that replaced the pattern.
    private let writeLock = NSLock()
    private var generation = 0
    private var current: LEDSpec?

    /// Creates a player that changes the LED with `write`.
    public init(write: @escaping (LEDState) throws -> Void) {
        self.write = write
    }

    deinit {
        stop()
    }

    /// Shows `spec`, replacing whatever was showing. Showing the pattern that
    /// is already playing does not restart it.
    ///
    /// - Throws: Whatever `write` throws for a fixed state. Errors while a
    ///   pattern plays are ignored; the next step tries again.
    public func show(_ spec: LEDSpec) throws {
        condition.lock()
        if case .pattern = spec, spec == current {
            condition.unlock()
            return
        }
        generation += 1
        let mine = generation
        current = spec
        condition.broadcast()
        condition.unlock()

        switch spec {
        case .state(let state):
            writeLock.lock()
            defer { writeLock.unlock() }
            try write(state)
        case .pattern(let pattern):
            // The thread holds the player only for one step at a time, so a
            // player that is dropped without `stop()` still ends its thread.
            let thread = Thread { [weak self] in
                var deadline = Date()
                var index = 0
                while let player = self, player.playStep(pattern.steps[index], generation: mine, deadline: &deadline) {
                    index = (index + 1) % pattern.steps.count
                }
            }
            thread.name = "chargelight.pattern"
            thread.start()
        }
    }

    /// Stops a playing pattern, leaving the LED on its current step.
    public func stop() {
        condition.lock()
        generation += 1
        current = nil
        condition.broadcast()
        condition.unlock()
    }

    /// Writes one step and waits out its duration. Returns `false` once the
    /// pattern has been replaced or stopped.
    private func playStep(_ step: Pattern.Step, generation mine: Int, deadline: inout Date) -> Bool {
        writeLock.lock()
        condition.lock()
        let live = generation == mine
        condition.unlock()
        if live { try? write(step.state) }
        writeLock.unlock()
        guard live else { return false }

        // Deadlines are absolute, so write latency does not make the pattern drift.
        deadline = max(deadline.addingTimeInterval(step.duration), Date())

        condition.lock()
        while generation == mine, condition.wait(until: deadline) {}
        let stillLive = generation == mine
        condition.unlock()
        return stillLive
    }
}
