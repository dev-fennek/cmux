import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Observation

extension NotificationCenterService {
    /// What a viewed tab's arrivals need, pushed by observation of the viewed
    /// tabs, no poll and no settle re-run:
    /// - a `done` or `error` record that arrives while the user looks at its
    ///   tab (key window, cmux active) is seen at once;
    /// - an unread notification on a viewed tab is read at once, on every
    ///   path that marks it unread (an arrival, a held delivery, a resync),
    ///   as a focus on that tab would read it (`interacted(.focus)`, by the
    ///   dismissal policy).
    /// Focus, typing, clicks and opens see the rest through `interacted`. An
    /// agent chat's turns are acpmux's (`unread`, cx-n8ou): its pane says
    /// whether it shows the chat.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in ObservationStream({ [weak self] in self?.viewedFacts(store) ?? ViewedTabsFacts(revision: 0, tabs: []) }) {
                guard let self else { return }
                let viewed = self.viewedTabs(store)
                for tab in viewed { self.interacted(.focus, tab: tab) }
                self.readTabs(enteringScreen: self.shownTabs(store), appActive: NSApp.isActive)
                self.clearTabMarks(entering: viewed)
            }
        }
    }

    /// Reads each tab of `shown` that came on screen since the last pass,
    /// while cmux is active: classic read a pane that became visible in the
    /// selected workspace (a workspace switch shows its splits, a tab switch
    /// shows that tab). A notification arriving on a tab already on screen,
    /// but not focused, keeps its ring until the pane is looked at.
    func readTabs(enteringScreen shown: [TabModel], appActive: Bool) {
        let entered = Set(TabUnreadMark.entered(shown.map(\.id), previous: shownTabIDs))
        shownTabIDs = Set(shown.map(\.id))
        _ = (entered, appActive)
    }

    /// Clears the manual mark (Mark Tab Unread, `TabUnreadMark`) of each tab
    /// that came into view since the last pass. A tab marked while viewed
    /// keeps the mark until it is viewed again.
    func clearTabMarks(entering viewed: [TabModel]) {
        let entered = Set(TabUnreadMark.entered(viewed.map(\.id), previous: viewedTabIDs))
        viewedTabIDs = Set(viewed.map(\.id))
        guard let services else { return }
        for tab in viewed where tab.markedUnread && entered.contains(tab.id) {
            try? TabUnreadMark.set(false, tab: tab, daemon: services.daemon)
        }
    }

    /// What the rules follow: which tabs are viewed (`viewedRevision`, bumped
    /// when a window's settled focus changes), their OSC 7501 records and
    /// whether they hold an unread notification.
    func viewedFacts(_ store: DaemonStore) -> ViewedTabsFacts {
        ViewedTabsFacts(revision: viewedRevision,
                        tabs: viewedTabs(store).map { ViewedProgramStatus(tab: $0.id, records: $0.programStatus, unread: $0.hasUnread) },
                        shown: shownTabs(store).map(\.id))
    }

    /// The tabs shown in a key window while cmux is active: each window's
    /// focused tab (O(1) per window). Only `store`'s tabs (the local daemon's).
    func viewedTabs(_ store: DaemonStore) -> [TabModel] {
        guard let services, NSApp.isActive else { return [] }
        return services.windows.controllers.compactMap { controller in
            controller.focus.state.windowKey ? viewedTab(in: controller, store: store) : nil
        }
    }

    /// The focused pane's selected tab in `controller`, wherever the keyboard
    /// is: classic read the selected workspace's focused pane on a workspace
    /// switch and a click on its row, with the keyboard still in the sidebar,
    /// a text field, or a page focus does not name. Only `store`'s tabs.
    func viewedTab(in controller: WindowController, store: DaemonStore) -> TabModel? {
        let resolved = controller.focus.state.resolved
        guard let id = Self.contentTab(resolved), let pane = resolved.pane else { return nil }
        guard let model = controller.content?.paneModel(key: pane), store.pane(model.handle) === model else { return nil }
        return model.tabs.first { $0.id == id }
    }

    /// The tabs on screen: in each visible window that shows a workspace, the
    /// selected tab of every pane on its active screen. Only `store`'s tabs.
    func shownTabs(_ store: DaemonStore) -> [TabModel] {
        guard let services else { return [] }
        return services.windows.controllers.flatMap { controller in
            controller.window?.occlusionState.contains(.visible) == true ? shownTabs(in: controller, store: store) : []
        }
    }

    /// The selected tab of every pane on `controller`'s active screen (none under a top page).
    func shownTabs(in controller: WindowController, store: DaemonStore) -> [TabModel] {
        guard controller.state.page == nil, let content = controller.content else { return [] }
        let layout = content.layoutModel
        guard let screen = layout.screens.first(where: { $0.id == layout.activeScreenID }) else { return [] }
        let topology = controller.focus.state.topology
        return screen.layout.panes.compactMap { pane in
            guard let model = content.paneModel(key: pane.rawValue), store.pane(model.handle) === model,
                  let id = topology.panes.first(where: { $0.id == pane.rawValue })?.selected else { return nil }
            return model.tabs.first { $0.id == id }
        }
    }
}
