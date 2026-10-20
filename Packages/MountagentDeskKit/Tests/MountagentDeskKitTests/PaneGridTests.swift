import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct PaneGridTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func opensInTheFocusedPaneAndFocusesWhereASessionAlreadyIs() {
        var grid = PaneGrid()
        grid.open(a)
        grid.setLayout(.columns)
        grid.focus(1)
        grid.open(b)
        #expect(grid.visible == [a, b])
        #expect(grid.focusedSession == b)

        grid.open(a)
        #expect(grid.visible == [a, b], "not shown twice")
        #expect(grid.focused == 0)
    }

    @Test func dropsSwapPanes() {
        var grid = PaneGrid()
        grid.setLayout(.grid)
        grid.open(a, inPane: 0)
        grid.open(b, inPane: 3)
        grid.open(a, inPane: 3)
        #expect(grid.visible == [b, nil, nil, a])
        #expect(grid.focused == 3)
    }

    @Test func shrinkingKeepsTheFocusedSessionOnScreen() {
        var grid = PaneGrid()
        grid.setLayout(.grid)
        grid.open(a, inPane: 0)
        grid.open(b, inPane: 1)
        grid.open(c, inPane: 2)
        grid.open(d, inPane: 3)
        grid.setLayout(.columns)
        #expect(grid.visible == [a, d])
        #expect(grid.focusedSession == d)
        grid.setLayout(.single)
        #expect(grid.visible == [d])
        grid.setLayout(.grid)
        #expect(Set(grid.visible.compactMap { $0 }) == [a, b, c, d], "hidden panes keep their sessions")
    }

    @Test func forgetsDeletedSessionsAndSurvivesBadSaves() throws {
        var grid = PaneGrid()
        grid.setLayout(.columns)
        grid.open(a, inPane: 0)
        grid.open(b, inPane: 1)
        grid.remove(b)
        #expect(grid.visible == [a, nil])
        grid.keep(only: [])
        #expect(grid.visible == [nil, nil])

        let data = try JSONEncoder().encode(grid)
        #expect(try JSONDecoder().decode(PaneGrid.self, from: data) == grid)
        let damaged = Data(#"{"layout":"rows","slots":[],"focused":9}"#.utf8)
        let loaded = try JSONDecoder().decode(PaneGrid.self, from: damaged)
        #expect(loaded.layout == .rows)
        #expect(loaded.slots.count == PaneGrid.maxPanes)
        #expect(loaded.focused == 1)
    }
}
