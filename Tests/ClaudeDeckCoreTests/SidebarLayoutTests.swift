import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SidebarLayoutTests {
    let g1 = UUID(), g2 = UUID()

    func session(_ state: SidebarSession.State, at t: TimeInterval? = nil, worktree: Bool = false) -> SidebarSession {
        SidebarSession(id: UUID(), state: state, updatedAt: t.map { Date(timeIntervalSince1970: $0) }, isWorktree: worktree)
    }

    func project(_ sessions: [SidebarSession], group: UUID? = nil, pinned: Bool = false) -> SidebarProject {
        SidebarProject(id: UUID(), pinned: pinned, groupID: group, sessions: sessions)
    }

    @Test func activeOrderIsStableWhenStatusChanges() {
        var order = ActivationOrder()
        var a = project([session(.running)]), b = project([session(.idle(unseen: false))])
        let first = SidebarLayout.build(groups: [], projects: [a, b], filter: .all, order: &order)
        #expect(first.active == [.project(a.id), .project(b.id)])
        // a finishes, b starts working: nobody moves.
        a.sessions[0].state = .idle(unseen: true)
        b.sessions[0].state = .blocked
        let second = SidebarLayout.build(groups: [], projects: [a, b], filter: .all, order: &order)
        #expect(second.active == first.active)
    }

    @Test func newlyActiveItemsAreAppendedAndGroupsInterleave() {
        var order = ActivationOrder()
        var a = project([session(.stopped)])
        let b = project([session(.running)], group: g1)
        let c = project([session(.running)])
        var layout = SidebarLayout.build(groups: [g1, g2], projects: [a, b, c], filter: .all, order: &order)
        #expect(layout.active == [.project(c.id), .group(g1)])
        #expect(layout.inactive == [.project(a.id), .group(g2)])
        a.sessions[0].state = .starting
        layout = SidebarLayout.build(groups: [g1, g2], projects: [a, b, c], filter: .all, order: &order)
        #expect(layout.active == [.project(c.id), .group(g1), .project(a.id)])
        // Stopping and restarting puts it at the end again.
        a.sessions[0].state = .stopped
        _ = SidebarLayout.build(groups: [g1, g2], projects: [a, b, c], filter: .all, order: &order)
        a.sessions[0].state = .shell
        layout = SidebarLayout.build(groups: [g1, g2], projects: [a, b, c], filter: .all, order: &order)
        #expect(layout.active.last == .project(a.id))
    }

    @Test func compactOnlyForSingleNonWorktreeSession() {
        var order = ActivationOrder()
        let one = project([session(.running)])
        let two = project([session(.running), session(.stopped)])
        let tree = project([session(.running, worktree: true)])
        let none = project([])
        let layout = SidebarLayout.build(groups: [], projects: [one, two, tree, none], filter: .all, order: &order)
        #expect(layout.compact == [one.id])
    }

    @Test func filtersHideNonMatchingRowsAndInactive() {
        var order = ActivationOrder()
        let waiting = project([session(.idle(unseen: true)), session(.running)])
        let working = project([session(.running)], group: g1)
        let quiet = project([session(.idle(unseen: false))], group: g1)
        let pinnedQuiet = project([session(.shell)], pinned: true)
        let stopped = project([session(.stopped)])
        let all = [waiting, working, quiet, pinnedQuiet, stopped]
        _ = SidebarLayout.build(groups: [g1], projects: all, filter: .all, order: &order)

        let w = SidebarLayout.build(groups: [g1], projects: all, filter: .waiting, order: &order)
        #expect(w.active == [.project(waiting.id)])
        #expect(w.sessionsInProject[waiting.id] == [waiting.sessions[0].id])
        #expect(w.inactive.isEmpty && w.pinned.isEmpty)
        #expect(w.compact.contains(working.id)) // compact is decided on all sessions

        let k = SidebarLayout.build(groups: [g1], projects: all, filter: .working, order: &order)
        #expect(k.active == [.project(waiting.id), .group(g1)])
        #expect(k.projectsInGroup[g1] == [working.id])
        #expect(k.sessionsInProject[waiting.id] == [waiting.sessions[1].id])
    }

    @Test func filterKeepsUnfilteredOrder() {
        var order = ActivationOrder()
        let a = project([session(.running)]), b = project([session(.running)])
        _ = SidebarLayout.build(groups: [], projects: [a, b], filter: .all, order: &order)
        let filtered = SidebarLayout.build(groups: [], projects: [b, a], filter: .working, order: &order)
        #expect(filtered.active == [.project(a.id), .project(b.id)])
    }

    @Test func pinnedProjectsStayInPinned() {
        var order = ActivationOrder()
        let p = project([session(.running)], pinned: true)
        let layout = SidebarLayout.build(groups: [], projects: [p], filter: .all, order: &order)
        #expect(layout.pinned == [p.id])
        #expect(layout.active.isEmpty && layout.inactive.isEmpty)
    }

    @Test func projectInUnknownGroupIsUngrouped() {
        var order = ActivationOrder()
        let p = project([session(.stopped)], group: UUID())
        let layout = SidebarLayout.build(groups: [g1], projects: [p], filter: .all, order: &order)
        #expect(layout.inactive == [.project(p.id), .group(g1)])
    }

    @Test func countsAndAttentionOrder() {
        let blockedLate = session(.blocked, at: 50)
        let blockedEarly = session(.blocked, at: 10)
        let unseenOld = session(.idle(unseen: true), at: 1)
        let unseenNew = session(.idle(unseen: true), at: 99)
        let seen = session(.idle(unseen: false), at: 100)
        let running = session(.running, at: 100)
        let all = [unseenNew, seen, blockedLate, running, unseenOld, blockedEarly]
        let counts = SidebarAttention.counts(all)
        #expect(counts.waiting == 4)
        #expect(counts.working == 3)
        #expect(SidebarAttention.order(all) == [blockedEarly.id, blockedLate.id, unseenOld.id, unseenNew.id])
    }

    @Test func nextAttentionCycles() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(SidebarAttention.next(after: nil, in: []) == nil)
        #expect(SidebarAttention.next(after: nil, in: [a, b, c]) == a)
        #expect(SidebarAttention.next(after: a, in: [a, b, c]) == b)
        #expect(SidebarAttention.next(after: c, in: [a, b, c]) == a)
        #expect(SidebarAttention.next(after: UUID(), in: [a, b]) == a)
        #expect(SidebarAttention.next(after: a, in: [a]) == a)
    }

    // MARK: LayoutGate

    func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1000 + s) }

    @Test func gateAppliesWhenPointerIsAway() {
        var gate = LayoutGate(1)
        let r1 = gate.offer(2, at: t(0))
        #expect(r1)
        #expect(gate.shown == 2 && gate.pending == nil)
        let r2 = gate.offer(2, at: t(1))
        #expect(!r2)
    }

    @Test func gateHoldsWhilePointerIsInsideAndBriefly() {
        var gate = LayoutGate(1)
        gate.pointer(inside: true, at: t(0))
        let r3 = gate.offer(2, at: t(1))
        #expect(!r3)
        #expect(gate.shown == 1 && gate.pending == 2)
        let r4 = gate.tick(at: t(5))
        #expect(!r4)
        gate.pointer(inside: false, at: t(6))
        let r5 = gate.tick(at: t(7))
        #expect(!r5)          // within the quiet period
        let r6 = gate.tick(at: t(7.6))
        #expect(r6)
        #expect(gate.shown == 2 && gate.pending == nil)
    }

    @Test func gateHoldsBrieflyAfterAClick() {
        var gate = LayoutGate(1)
        gate.click(at: t(0))
        let r7 = gate.offer(2, at: t(0.5))
        #expect(!r7)
        let r8 = gate.tick(at: t(1.6))
        #expect(r8)
    }

    @Test func userActionsApplyImmediatelyEvenUnderThePointer() {
        var gate = LayoutGate(1)
        gate.pointer(inside: true, at: t(0))
        gate.userAction(at: t(1))
        let r9 = gate.offer(2, at: t(1))
        #expect(r9)
        // A slow consequence (a session exiting after End Session) still counts.
        let r10 = gate.offer(3, at: t(2.2))
        #expect(r10)
        // Later system changes wait.
        let r11 = gate.offer(4, at: t(5))
        #expect(!r11)
        #expect(gate.shown == 3)
    }

    @Test func heldChangeIsAppliedAfterMaxHoldEvenIfThePointerNeverLeaves() {
        var gate = LayoutGate(1)
        gate.pointer(inside: true, at: t(0))
        let held = gate.offer(2, at: t(1))
        #expect(!held)
        let newer = gate.offer(3, at: t(6)) // a newer layout doesn't restart the clock
        #expect(!newer)
        let early = gate.tick(at: t(10.9))
        #expect(!early)
        let late = gate.tick(at: t(11))
        #expect(late)
        #expect(gate.shown == 3 && gate.pending == nil)
        // The next held change gets its own 10 s.
        let next = gate.offer(4, at: t(12))
        #expect(!next)
        let stillHeld = gate.tick(at: t(21))
        #expect(!stillHeld)
        let applied = gate.tick(at: t(22))
        #expect(applied)
    }

    @Test func revertingAHeldChangeDropsIt() {
        var gate = LayoutGate(1)
        gate.pointer(inside: true, at: t(0))
        gate.offer(2, at: t(1))
        gate.offer(1, at: t(2))
        #expect(gate.pending == nil)
        gate.pointer(inside: false, at: t(3))
        let r12 = gate.tick(at: t(10))
        #expect(!r12)
        #expect(gate.shown == 1)
    }
}
