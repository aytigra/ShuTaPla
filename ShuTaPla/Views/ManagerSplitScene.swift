//
//  ManagerSplitScene.swift
//  ShuTaPla
//
//  The AppKit backbone of Manager mode: an `NSSplitViewController` hosting the three
//  SwiftUI panes (playlists sidebar, center file panel, tag inspector) and a custom
//  `NSToolbar` whose items align to the split view's dividers via tracking separators.
//
//  The toolbar is a real window toolbar, so its controls sit on the traffic-light line,
//  are fully interactive, and group into pane-aligned regions: the center region carries
//  the playlist title and the scope's playback actions; the inspector region carries the
//  tag controls. Two `NSTrackingSeparatorToolbarItem`s pin the region boundaries to the
//  sidebar and inspector dividers, so each region stays bounded by its pane. The sidebar's
//  own controls sit outside the toolbar in a `SidebarToolbarAccessory`, mounted and removed
//  alongside it.
//
//  The panes are SwiftUI (`PlaylistSidebar` / `PlaylistCenterView` / `TagSidebar`) hosted
//  across the AppKit boundary, so `ManagerEnv` re-injects the SwiftData container and the
//  observable services that the SwiftUI environment would otherwise carry. `ManagerChrome`
//  holds the view-chrome the toolbar and the split view share — sidebar collapse, inspector
//  visibility, and tag-management mode — as the single source of truth.
//

import SwiftUI
import SwiftData
import AppKit
import Observation

// MARK: - Chrome state

/// The Manager's view-chrome, shared by the toolbar controls and the split view. The toolbar
/// buttons write it; the split view collapses its panes to match. Scope itself lives in
/// `AppState.managerScope`, since data routing keys off it.
@MainActor
@Observable
final class ManagerChrome {
    /// Whether the playlists sidebar is collapsed. The scope tabs drive it: clicking the active
    /// scope collapses, clicking either while collapsed expands.
    var sidebarCollapsed = false {
        didSet { defaults.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey) }
    }
    /// Whether the tag inspector is shown.
    var inspectorVisible = true {
        didSet { defaults.set(inspectorVisible, forKey: Self.inspectorVisibleKey) }
    }
    /// Whether the inspector is in whole-playlist tag-management mode rather than filter-and-edit.
    /// Deliberately not remembered: a task the user is in the middle of, not a layout preference.
    var managingTags = false

    private static let sidebarCollapsedKey = "managerSidebarCollapsed"
    private static let inspectorVisibleKey = "managerInspectorVisible"
    private let defaults: UserDefaults

    /// Restores which side panes were showing when the Manager was last on screen. This object is
    /// `@State` on a view that Player mode takes off the tree, so it is rebuilt on every mode switch
    /// as well as on relaunch — the defaults are what carry the layout across both. They sit beside
    /// the divider positions the split view autosaves, which is the other half of the same memory.
    ///
    /// The two panes' defaults differ, so the inspector can't take `bool(forKey:)`'s missing-key
    /// `false`: a first launch shows it.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarCollapsedKey)
        inspectorVisible = defaults.object(forKey: Self.inspectorVisibleKey) as? Bool ?? true
    }
}

// MARK: - Environment bridge

/// The observable services and SwiftData container the hosted panes need, re-applied to each
/// `NSHostingController`/`NSHostingView` rootView so the SwiftUI environment survives the AppKit
/// boundary.
@MainActor
struct ManagerEnv {
    let appState: AppState
    let coordinator: PlaybackCoordinator
    let thumbnailService: ThumbnailService
    let metadataService: MediaMetadataService
    let hdrCache: HDRCache
    let chrome: ManagerChrome
    let modelContainer: ModelContainer

    /// Wraps a SwiftUI view with the full Manager environment so it renders identically whether it
    /// lives inside the SwiftUI tree or is hosted from AppKit.
    func host(_ view: some View) -> some View {
        view
            .environment(appState)
            .environment(coordinator)
            .environment(thumbnailService)
            .environment(metadataService)
            .environment(hdrCache)
            .environment(chrome)
            .modelContainer(modelContainer)
    }

    /// The same, as an AppKit view sized to its content — what a toolbar item or a titlebar
    /// accessory needs.
    func hostingView(_ view: some View) -> NSView {
        let hosting = NSHostingView(rootView: host(view))
        hosting.sizingOptions = [.intrinsicContentSize]
        return hosting
    }
}

// MARK: - SwiftUI bridge

/// Hosts `ManagerSplitViewController` in the SwiftUI tree and keeps the window toolbar attached
/// while Manager mode is on screen.
struct ManagerSplitScene: NSViewControllerRepresentable {
    let env: ManagerEnv

    func makeNSViewController(context: Context) -> ManagerSplitViewController {
        ManagerSplitViewController(env: env)
    }

    func updateNSViewController(_ controller: ManagerSplitViewController, context: Context) {
        controller.attachToolbarIfNeeded()
    }

    static func dismantleNSViewController(_ controller: ManagerSplitViewController, coordinator: ()) {
        controller.detachToolbar()
    }

    /// Fills the proposed area so the split view spans the full window. The default sizing pass asks
    /// the split view controller for its fitting size — the sum of the panes' minimum thicknesses —
    /// and SwiftUI then centers that narrower content, leaving margins on both edges. With the split
    /// view undersized, a divider drag can't hand freed width to the center pane and a pane collapse
    /// detaches from the window edge. Reporting the full proposed size pins it edge to edge.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: ManagerSplitViewController,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - Split view controller

@MainActor
final class ManagerSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private let env: ManagerEnv

    private let sidebarItem: NSSplitViewItem
    private let centerItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem

    private var managerToolbar: NSToolbar?
    private var sidebarAccessory: SidebarToolbarAccessory?
    private weak var hostWindow: NSWindow?
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var inspectorCollapseObservation: NSKeyValueObservation?

    init(env: ManagerEnv) {
        self.env = env

        // Each pane fills its column: opting out of hosting-content sizing drops the intrinsic-width
        // constraint that would otherwise pin a pane (e.g. the audio placeholder) to its content's
        // size and force the dividers to move symmetrically instead of resizing the dragged pane.
        //
        // The side panes carry no maximum thickness on purpose: a cap turns a drag that grows the
        // pane past the cap into a drag that shrinks the *next* pane over, so the side panels would
        // slide toward the center once the inspector hit its limit. A minimum thickness is enough to
        // keep them usable.
        let sidebar = NSHostingController(rootView: env.host(PlaylistSidebar()))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // A starting value only: once mounted, `SidebarToolbarAccessory` raises this to whatever its
        // controls measure, so the pane can never be dragged narrower than the group in the titlebar.
        sidebarItem.minimumThickness = SidebarToolbarLayout.minimumThicknessFloor
        sidebarItem.canCollapse = true

        let center = NSHostingController(rootView: env.host(PlaylistCenterView()))
        center.sizingOptions = []
        centerItem = NSSplitViewItem(viewController: center)
        centerItem.minimumThickness = 360
        centerItem.canCollapse = false

        // The inspector edits the active scope's tag-management mode, which is shared chrome state.
        let managingTags = Binding(
            get: { [chrome = env.chrome] in chrome.managingTags },
            set: { [chrome = env.chrome] newValue in chrome.managingTags = newValue }
        )
        // A regular trailing pane, not an inspector item: the inspector behavior installs its own
        // width management that fights a manual divider drag.
        let inspector = NSHostingController(rootView: env.host(TagSidebar(managingTags: managingTags)))
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.canCollapse = true

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(centerItem)
        addSplitViewItem(inspectorItem)
        // Set holding priorities after the items are installed so the side panes hold their widths
        // and the center (lowest priority) is the one that grows or shrinks for a divider drag or a
        // pane collapse. Applying them in the initializer lets `sidebarWithViewController` override.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        centerItem.holdingPriority = NSLayoutConstraint.Priority(250)
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Persist the divider positions across launches. Set after the items are installed so the
        // split view restores against the final pane set. Collapse state stays driven by
        // `ManagerChrome` (applied below), which remembers it across launches itself, so autosave
        // only governs pane widths.
        splitView.autosaveName = "ManagerSplitView"
        applyCollapse()
        startObserving()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attachToolbarIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        attachToolbarIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        detachToolbar()
    }

    // MARK: Toolbar attachment

    /// Installs the Manager toolbar and the sidebar accessory on the host window, once it has one.
    /// Idempotent — safe to call from the appearance callbacks and from the representable's update
    /// pass.
    func attachToolbarIfNeeded() {
        guard let window = view.window else { return }
        hostWindow = window

        let toolbar = managerToolbar ?? makeToolbar()
        managerToolbar = toolbar

        if window.toolbar !== toolbar {
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.toolbar = toolbar
        }

        if sidebarAccessory == nil {
            sidebarAccessory = SidebarToolbarAccessory(env: env, splitViewController: self)
        }
        syncSidebarControls()
    }

    /// Removes the Manager toolbar and the sidebar accessory when Manager mode leaves the screen, so
    /// Welcome and Player don't inherit them. Both references go with them: a chrome change after
    /// this point still reaches `syncSidebarControls()`, which must then find nothing to mutate
    /// rather than reach into a toolbar no window is showing. Re-entering Manager mode builds a
    /// fresh pair.
    func detachToolbar() {
        guard let window = hostWindow else { return }
        Self.detachChrome(from: window, toolbar: managerToolbar, accessory: sidebarAccessory)
        managerToolbar = nil
        sidebarAccessory = nil
    }

    /// Takes the Manager's chrome back off a window. The accessory goes unconditionally — it is ours
    /// wherever the window's toolbar has ended up, and one left behind is the sidebar's controls
    /// sitting on Welcome's or Player's titlebar. The toolbar is only cleared while the window still
    /// holds ours, since stripping the mode that took over is not ours to do.
    static func detachChrome(
        from window: NSWindow, toolbar: NSToolbar?, accessory: NSTitlebarAccessoryViewController?
    ) {
        if let accessory, let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        guard window.toolbar === toolbar else { return }
        window.toolbar = nil
        window.titleVisibility = .visible
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ManagerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: Pane collapse

    /// Drives the panes to match the chrome.
    ///
    /// Unanimated on purpose: an animated collapse resizes the center pane every frame, and the pane
    /// is hosted with `sizingOptions = []`, so each of those widths costs a full SwiftUI layout pass
    /// over the gallery — the center reflows for the whole animation. Snapping is one pass. It also
    /// settles where the collapsed toolbar items appear: they follow the tracking separator, which
    /// follows the divider, so an animated divider would slide them in from the sidebar's edge.
    private func applyCollapse() {
        setCollapsed(sidebarItem, to: env.chrome.sidebarCollapsed)
        setCollapsed(inspectorItem, to: !env.chrome.inspectorVisible)
        syncSidebarControls()
    }

    /// Moves the sidebar's own controls between their two homes: the titlebar accessory while the
    /// sidebar is open, the toolbar once it collapses — where the system draws them the same glass
    /// group capsules as every other toolbar group. Exactly one home holds them at a time, and both
    /// halves key off the chrome rather than off the panes' realized geometry, so they switch with
    /// the intent that starts the collapse animation instead of with the layout that ends it.
    private func syncSidebarControls() {
        let collapsed = env.chrome.sidebarCollapsed

        // Taken out of the window rather than hidden in place: an accessory left mounted keeps its
        // width, and the toolbar indents its own items past whatever the accessory claims — so the
        // collapsed controls would start well right of the traffic lights.
        if let window = hostWindow, let accessory = sidebarAccessory {
            let mounted = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
            if collapsed {
                if let mounted { window.removeTitlebarAccessoryViewController(at: mounted) }
            } else if mounted == nil {
                window.addTitlebarAccessoryViewController(accessory)
                accessory.updateGeometry()
            }
        }

        // Only `collapsedOnlyIdentifiers` ever differ between the two orders, so inserting and
        // removing them leaves the rest of the toolbar's items — and their hosted views — untouched.
        if let toolbar = managerToolbar {
            let wanted = SidebarToolbarLayout.toolbarIdentifiers(sidebarCollapsed: collapsed)
            for identifier in SidebarToolbarLayout.collapsedOnlyIdentifiers {
                let present = toolbar.items.firstIndex { $0.itemIdentifier == identifier }
                if let index = wanted.firstIndex(of: identifier) {
                    if present == nil { toolbar.insertItem(withItemIdentifier: identifier, at: index) }
                } else if let present {
                    toolbar.removeItem(at: present)
                }
            }
        }
    }

    /// Writes only a real change: `applyCollapse` runs on any chrome change and drives both panes, so
    /// most calls already ask for the state the pane is in.
    private func setCollapsed(_ item: NSSplitViewItem, to collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        item.isCollapsed = collapsed
    }

    /// Mirrors chrome → panes (toolbar toggles) and panes → chrome (a divider dragged to the edge),
    /// keeping the toolbar's highlight in step with the actual layout. The equality guards below are
    /// what break the feedback loop between the two directions.
    private func startObserving() {
        observeChrome()
        observeScope()
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.env.chrome.sidebarCollapsed != collapsed {
                    self.env.chrome.sidebarCollapsed = collapsed
                }
            }
        }
        inspectorCollapseObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let collapsed = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.env.chrome.inspectorVisible != !collapsed {
                    self.env.chrome.inspectorVisible = !collapsed
                }
            }
        }
    }

    private func observeChrome() {
        withObservationTracking {
            _ = env.chrome.sidebarCollapsed
            _ = env.chrome.inspectorVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyCollapse()
                self.observeChrome()
            }
        }
    }

    private func observeScope() {
        withObservationTracking {
            _ = env.appState.managerScope
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.realignSeparators()
                self.observeScope()
            }
        }
    }

    /// Forces a split-view layout pass so the toolbar's tracking separators realign to the dividers.
    /// A scope switch changes pane content but not pane widths, so without a nudge the separators
    /// stay where they were and the center items overlap the inspector items until the next drag.
    private func realignSeparators() {
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SidebarToolbarLayout.toolbarIdentifiers(sidebarCollapsed: env.chrome.sidebarCollapsed)
    }

    /// The collapsed order, which is the superset: an identifier the toolbar may be asked to insert
    /// later has to be allowed from the start.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SidebarToolbarLayout.toolbarIdentifiers(sidebarCollapsed: true)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            // Nothing precedes it, so it bounds the center region alone: the title and actions start
            // at the sidebar divider and the system keeps drawing the divider's hairline through the
            // toolbar.
            return NSTrackingSeparatorToolbarItem(identifier: .sidebarTrackingSeparator, splitView: splitView, dividerIndex: 0)
        // The sidebar's controls, for as long as it stays collapsed.
        case .scopeTabs:
            return sidebarControl(itemIdentifier, label: "Scope") { ScopeTabs() }
        case .newPlaylist:
            return sidebarControl(itemIdentifier, label: "New Playlist") { NewPlaylistButton() }
        case .trailingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: .trailingSeparator, splitView: splitView, dividerIndex: 1)
        case .title:
            // The title yields first when space is tight, and reads as a plain label, not a control.
            let item = hosting(itemIdentifier, label: "Playlist", visibility: .low) { ManagerTitleLabel() }
            item.isBordered = false
            return item
        case .centerActions:
            return hosting(itemIdentifier, label: "Actions", visibility: .high) { CenterActionsBar() }
        case .manageTags:
            return hosting(itemIdentifier, label: "Manage Tags", visibility: .high) { ManageTagsButton() }
        case .toggleTags:
            return hosting(itemIdentifier, label: "Toggle Tags", visibility: .high) { ToggleTagsButton() }
        default:
            return nil
        }
    }

    /// Builds a toolbar item whose content is a SwiftUI view hosted with the full Manager
    /// environment, sized to its intrinsic content.
    private func hosting(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        visibility: NSToolbarItem.VisibilityPriority = .standard,
        @ViewBuilder _ content: () -> some View
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = env.hostingView(content())
        item.label = label
        item.visibilityPriority = visibility
        return item
    }

    /// One of the sidebar's own controls, dressed for the toolbar line: padded off the glass capsule
    /// the toolbar draws around it. That capsule hugs a custom view's bounds, and these buttons are
    /// laid out edge to edge — deliberately, since on the sidebar there is no capsule to clear — so
    /// the inset is the item's, never the control's.
    private func sidebarControl(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        @ViewBuilder _ content: () -> some View
    ) -> NSToolbarItem {
        hosting(identifier, label: label, visibility: .high) {
            content().padding(.horizontal, SidebarToolbarLayout.toolbarCapsuleInset)
        }
    }
}

nonisolated extension NSToolbarItem.Identifier {
    static let scopeTabs = NSToolbarItem.Identifier("ManagerScopeTabs")
    static let newPlaylist = NSToolbarItem.Identifier("ManagerNewPlaylist")
    static let title = NSToolbarItem.Identifier("ManagerTitle")
    static let centerActions = NSToolbarItem.Identifier("ManagerCenterActions")
    static let trailingSeparator = NSToolbarItem.Identifier("ManagerTrailingSeparator")
    static let manageTags = NSToolbarItem.Identifier("ManagerManageTags")
    static let toggleTags = NSToolbarItem.Identifier("ManagerToggleTags")
}

// MARK: - Toolbar controls

/// The current playlist's name, the window's center title. Placeholder when nothing is selected.
private struct ManagerTitleLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text(appState.managedPlaylist?.name ?? "Shutapla")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 280)
    }
}

/// The active scope's playback actions, bounded to the center region: visual gets Play · Reshuffle ·
/// List/Gallery · Settings; audio gets Reshuffle · Settings. Empty when nothing is selected.
private struct CenterActionsBar: View {
    @Environment(AppState.self) private var appState
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 6) {
            if let playlist = appState.managedPlaylist {
                switch appState.managerScope {
                case .image, .video: visualActions(playlist)
                case .audio: audioActions(playlist)
                }
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private func visualActions(_ playlist: Playlist) -> some View {
        @Bindable var playlist = playlist

        Button {
            appState.startPlayback(of: playlist)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        // A review mode surfaces an unplayable set, so its play affordance is unavailable — matching
        // the double-click and `[enter]` no-ops. Reading the memoized sequence re-derives the
        // affordance on a membership `bump()`, so no separate `version` read is needed.
        .disabled(appState.sequences.sequence(of: playlist).isEmpty || appState.inReviewMode)
        .help("Play")

        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        Picker("View", selection: $playlist.preferences.viewMode) {
            Image(systemName: "list.bullet").tag(ViewMode.list)
            Image(systemName: "square.grid.2x2").tag(ViewMode.gallery)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("List or gallery")

        settingsButton(playlist)
    }

    @ViewBuilder
    private func audioActions(_ playlist: Playlist) -> some View {
        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        settingsButton(playlist)
    }

    /// Opens the per-playlist settings popover (overrides of the global defaults).
    private func settingsButton(_ playlist: Playlist) -> some View {
        Button {
            showingSettings.toggle()
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .help("Playlist settings")
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            PlaylistSettingsView(playlist: playlist)
        }
    }
}

private struct ManageTagsButton: View {
    @Environment(AppState.self) private var appState
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        Button {
            // Entering management is meaningless with the panel hidden, so reveal it.
            if !chrome.managingTags { chrome.inspectorVisible = true }
            chrome.managingTags.toggle()
        } label: {
            Label("Manage Tags", systemImage: "tag")
                .symbolVariant(chrome.managingTags ? .fill : .none)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .tint(chrome.managingTags ? .accentColor : nil)
        .disabled(appState.managedPlaylist == nil)
        .help(chrome.managingTags ? "Edit selected files' tags" : "Manage playlist tags")
    }
}

private struct ToggleTagsButton: View {
    @Environment(ManagerChrome.self) private var chrome

    var body: some View {
        Button {
            chrome.inspectorVisible.toggle()
        } label: {
            Label("Toggle Tags", systemImage: "sidebar.right")
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .help(chrome.inspectorVisible ? "Hide tags" : "Show tags")
    }
}
