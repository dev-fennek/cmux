import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Testing

/// The unread ring stayed on a pane the person was looking at while the
/// sidebar row's badge was gone (Austin, 2026-10-20): the viewed-tab rule read
/// only a tab whose page or terminal held the keyboard, so a workspace picked
/// in the sidebar (keyboard still there) or a chat whose focus resolved to no
/// page kept its ring. cmux classic read the selected workspace's focused pane
/// on a switch and on a click of its row, and every pane that became visible
/// (`TabManager` selection observer, `WorkspaceContentView` visibility).
@MainActor @Suite(.serialized)
struct UnreadRingClassicReadTests {
    /// One workspace, two panes side by side, each tab holding an unread notification.
    private static func tree() -> DaemonTree {
        let marker = { (id: UInt64) in TabNotification(notification: NotificationID(rawValue: id), unread: true, level: .info, source: "agent") }
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~", notification: marker(4))])
        // The second pane also holds a background tab, unread too.
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~", notification: marker(5)),
                                                                   TabSnapshot(surface: SurfaceID(rawValue: 3), title: "~", notification: marker(6))])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ring-ws"), name: "ring", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ring-ws"), index: 0)])
        return tree
    }

    private static func open() async throws -> (AppServices, WindowController, DaemonStore) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["ring-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.workspaceContent?.panes.count == 2, "the window never showed the workspace's two panes")
        for _ in 0..<200 where controller.focus.state.pane == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.focus.state.pane != nil, "the window focused no pane")
        let layout = try #require(controller.content?.layoutModel)
        controller.content?.contentView.layoutSubtreeIfNeeded()
        for _ in 0..<200 where layout.visiblePanes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(layout.visiblePanes.count == 2, "the layout never reported both panes in its viewport")
        return (services, controller, store)
    }

    @Test func theFocusedPaneIsViewedWhileTheKeyboardIsInTheSidebar() async throws {
        let (services, controller, store) = try await Self.open()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let pane = try #require(controller.focus.state.pane)
        let focused = try #require(controller.content?.paneModel(key: pane)?.tabs.first)
        controller.focus.send(.focusTarget(.sidebar(keyboard: false), source: .intent))
        #expect(controller.focus.state.resolved == .sidebar, "the sidebar holds the keyboard")
        let viewed = services.notifications.viewedTab(in: controller, store: store)
        #expect(viewed?.id == focused.id, "a workspace picked in the sidebar left its focused pane's ring on")
        if let viewed { services.notifications.interacted(.focus, tab: viewed) }
        #expect(services.notifications.log.contains("ack \(focused.id)"))
    }

    @Test func everyPaneThatComesOnScreenIsRead() async throws {
        let (services, controller, store) = try await Self.open()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let panes = try #require(store.workspaces.first?.screens.first?.panes)
        let front = panes.compactMap(\.tabs.first)
        try #require(front.count == 2 && front.allSatisfy(\.hasUnread))
        let shown = services.notifications.shownTabs(in: controller, store: store)
        #expect(Set(shown.map(\.id)) == Set(front.map(\.id)), "each pane's selected tab is on screen, the background tab is not")
        // The app's own passes ran with cmux inactive (a test process): they read nothing. Start over as
        // a workspace that has just come on screen.
        services.notifications.shownTabIDs = []
        services.notifications.readTabs(enteringScreen: shown, appActive: true)
        for tab in front { #expect(services.notifications.log.contains("ack \(tab.id)"), "\(tab.id) came on screen and kept its ring") }
        // A tab already on screen is not read again by a later pass: its next arrival keeps the ring.
        let acks = { services.notifications.log.filter { $0.hasPrefix("ack ") }.count }
        let before = acks()
        services.notifications.readTabs(enteringScreen: services.notifications.shownTabs(in: controller, store: store), appActive: true)
        #expect(acks() == before)
        // A tab switch in the pane without focus puts the background tab on screen: it is read then.
        let background = try #require(panes[1].tabs.last)
        controller.state.selection.select(background.id, in: panes[1].id)
        let after = services.notifications.shownTabs(in: controller, store: store)
        #expect(after.contains { $0.id == background.id }, "the selected background tab is on screen")
        services.notifications.readTabs(enteringScreen: after, appActive: true)
        #expect(services.notifications.log.contains("ack \(background.id)"))
    }

    @Test func aPaneThatComesOnScreenWhileCmuxIsInactiveIsNotRead() async throws {
        let (services, controller, store) = try await Self.open()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let shown = services.notifications.shownTabs(in: controller, store: store)
        services.notifications.shownTabIDs = []
        services.notifications.readTabs(enteringScreen: shown, appActive: false)
        for tab in shown { #expect(!services.notifications.log.contains("ack \(tab.id)")) }
    }
}
