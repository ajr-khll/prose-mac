import Foundation
import ProseCore
import ProseHost
import Testing

@testable import Prose

/// Whether a waiting read should be answered now or parked.
///
/// This is the single decision that separates a supervision loop from a hang,
/// so it is tested on its own rather than only through the socket.
@MainActor
@Suite("Supervision")
struct SupervisionTests {
    /// A pane's session, with no socket behind it — none of this needs one.
    private func agent() -> AgentSession { AgentSession(pane: 1) }

    // MARK: - Level-triggered, not edge-triggered

    @Test("a child that finished before the parent asked does not park")
    func aFastChildDoesNotHangItsParent() {
        // **The failure this exists to prevent.** The child finishes in fifty
        // milliseconds; the parent's model gets round to waiting at a hundred.
        // Edge-triggered, the event that would have woken the read has already
        // happened and the parent waits until its timeout — forever, as far as
        // anyone watching the pane is concerned. A fast child is the common
        // case, not an edge case.
        let workspace = Workspace()
        let child = agent()
        child.apply(.turn(state: .started, error: nil))
        child.apply(.messageStart(id: "m1", role: .agent))
        child.apply(.delta(id: "m1", text: "done"))
        child.apply(.turn(state: .ended, error: nil))

        let query = ReadQuery(since: 0, until: [.turn], timeout: 60_000)
        #expect(workspace.satisfied(query, child) == .turn)
    }

    @Test("a child still working is parked")
    func aRunningChildParks() {
        let workspace = Workspace()
        let child = agent()
        child.apply(.turn(state: .started, error: nil))
        child.apply(.delta(id: "m1", text: "thinking"))

        let query = ReadQuery(since: 0, until: [.turn], timeout: 60_000)
        #expect(workspace.satisfied(query, child) == nil)
    }

    @Test("a child that has not started yet is parked")
    func aSilentChildParks() {
        // Nothing has happened, so there is nothing to have missed.
        let workspace = Workspace()
        #expect(workspace.satisfied(ReadQuery(until: [.turn], timeout: 60_000), agent()) == nil)
    }

    @Test("a turn the parent has already seen does not wake it again")
    func theCursorIsWhatMakesItLevelTriggered() {
        // Same idle child, but the parent is caught up. Without the cursor in
        // the test, "idle" alone would satisfy every wait forever and the loop
        // would spin instead of blocking.
        let workspace = Workspace()
        let child = agent()
        child.apply(.turn(state: .started, error: nil))
        child.apply(.turn(state: .ended, error: nil))

        let caughtUp = ReadQuery(since: child.transcript.clock, until: [.turn], timeout: 60_000)
        #expect(workspace.satisfied(caughtUp, child) == nil)
    }

    // MARK: - The other two conditions

    @Test("a pending question satisfies a wait at once")
    func aPendingAskWakesImmediately() {
        let workspace = Workspace()
        let child = agent()
        child.ask(id: .number(1), prompt: "Which?", choices: ["a"], placeholder: nil)

        let query = ReadQuery(until: [.turn, .ask], timeout: 60_000)
        #expect(workspace.satisfied(query, child) == .ask)
    }

    @Test("an agent whose process has gone satisfies a wait on exit")
    func exitWakesImmediately() {
        let workspace = Workspace()
        let child = agent()
        child.markExited()

        #expect(workspace.satisfied(ReadQuery(until: [.exit], timeout: 60_000), child) == .exit)
        #expect(
            workspace.satisfied(ReadQuery(until: [.ask], timeout: 60_000), child) == nil,
            "and only the condition that was asked for")
    }

    @Test("a failed turn is still a turn ending")
    func aFailedTurnWakesToo() {
        // A parent waiting for its child to stop wants to know either way. It
        // reads the notice to find out which.
        let workspace = Workspace()
        let child = agent()
        child.apply(.turn(state: .started, error: nil))
        child.apply(.turn(state: .failed, error: "the agent fell over"))

        #expect(workspace.satisfied(ReadQuery(until: [.turn], timeout: 60_000), child) == .turn)
    }
}
