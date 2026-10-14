import Foundation
import HotReloadRuntime
import HotReloadUI
import Testing

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@Suite(.serialized)
@MainActor
struct HotReloadRuntimeSuite {
  @Test("loading a missing artifact reports the loader error without invalidating views")
  func missingArtifactIsRejected() {
    let observer = HotReloadRuntime.observer(for: "TestView")
    let generation = observer.generation

    let result = HotReloadRuntime.loadArtifact(
      at: URL(fileURLWithPath: "/tmp/hot-reload-artifact-that-does-not-exist.bundle"),
      declaration: "TestView"
    )

    guard case .failed(let message) = result else {
      Issue.record("Expected the artifact to be rejected")
      return
    }
    #expect(message.contains("hot-reload-artifact-that-does-not-exist.bundle"))
    #expect(observer.generation == generation)
  }

  @Test("reload signal notifies closure subscribers, NotificationCenter, and async sequence")
  func reloadSignalNotifiesListeners() async {
    var receivedGenerations: [Int] = []
    let subscription = HotReloadRuntime.onReload { generation in
      receivedGenerations.append(generation)
    }

    var notificationGenerations: [Int] = []
    let token = NotificationCenter.default.addObserver(
      forName: HotReloadRuntime.didReloadNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let gen = notification.userInfo?["generation"] as? Int {
        MainActor.assumeIsolated {
          notificationGenerations.append(gen)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    let stream = HotReloadRuntime.reloads()
    var iterator = stream.makeAsyncIterator()

    HotReloadRuntime.simulateReload(declarations: ["SampleView"])
    let event = await iterator.next()

    #expect(receivedGenerations.count == 1)
    #expect(notificationGenerations == receivedGenerations)
    #expect(event?.generation == receivedGenerations.first)
    #expect(event?.declarations == ["SampleView"])

    subscription.cancel()
    HotReloadRuntime.simulateReload(declarations: ["SampleView"])
    #expect(receivedGenerations.count == 1)
  }

  @Test("HotReloadRefreshing hook refreshes registered instances and releases deallocated ones")
  func refreshingHookNotifiesLiveInstances() {
    let active = RefreshableFixture()
    active.observeHotReload()

    do {
      let transient = RefreshableFixture()
      transient.observeHotReload()
      HotReloadRuntime.simulateReload(declarations: ["RefreshableFixture"])
      #expect(transient.reloadCount == 1)
    }

    HotReloadRuntime.simulateReload(declarations: ["RefreshableFixture"])
    #expect(active.reloadCount == 2)
  }

  #if canImport(UIKit)
    @Test("UIKit view and view-controller hosts rebuild on reload")
    func uikitHostsRebuildOnReload() {
      var controllerBuilds = 0
      let controllerHost = HotReloadViewControllerHost({
        controllerBuilds += 1
        let vc = UIViewController()
        vc.title = "Title #\(controllerBuilds)"
        return vc
      }())
      _ = controllerHost.view
      #expect(controllerBuilds == 1)
      #expect(controllerHost.title == "Title #1")

      var viewBuilds = 0
      let viewHost = HotReloadViewHost({
        viewBuilds += 1
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        view.tag = viewBuilds
        return view
      }())
      #expect(viewBuilds == 1)
      #expect(viewHost.hostedView.tag == 1)

      HotReloadRuntime.simulateReload(declarations: ["HostedScreen"])
      #expect(controllerBuilds == 2)
      #expect(controllerHost.title == "Title #2")
      #expect(viewBuilds == 2)
      #expect(viewHost.hostedView.tag == 2)
    }
  #elseif canImport(AppKit)
    @Test("AppKit view and view-controller hosts rebuild on reload")
    func appkitHostsRebuildOnReload() {
      var controllerBuilds = 0
      let controllerHost = HotReloadViewControllerHost({
        controllerBuilds += 1
        let vc = NSViewController()
        vc.title = "Title #\(controllerBuilds)"
        return vc
      }())
      _ = controllerHost.view
      #expect(controllerBuilds == 1)
      #expect(controllerHost.title == "Title #1")

      var viewBuilds = 0
      let viewHost = HotReloadViewHost({
        viewBuilds += 1
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        return view
      }())
      let firstHosted = viewHost.hostedView
      #expect(viewBuilds == 1)

      HotReloadRuntime.simulateReload(declarations: ["HostedScreen"])
      #expect(controllerBuilds == 2)
      #expect(controllerHost.title == "Title #2")
      #expect(viewBuilds == 2)
      #expect(viewHost.hostedView !== firstHosted)
      #expect(viewHost.hostedView.superview === viewHost)
      #expect(controllerHost.hostedController.parent === controllerHost)
      #expect(controllerHost.children.count == 1)
    }
  #endif
}

#if canImport(AppKit) && !canImport(UIKit)
  import SwiftUI

  extension HotReloadRuntimeSuite {
    @Test("window hierarchy: controllers, views, and window controllers refresh once each")
    func windowHierarchyRefreshes() {
      let controller = RefreshingViewController()
      let child = RefreshingViewController()
      controller.addChild(child)
      let window = makeWindow(controller: controller)
      defer { window.close() }
      let nested = RefreshingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
      controller.view.addSubview(child.view)
      child.view.addSubview(nested)
      // Registered and also in the hierarchy: still refreshed only once.
      nested.observeHotReload()

      HotReloadRuntime.simulateReload(declarations: ["RefreshingView"])

      #expect(controller.reloadCount == 1)
      #expect(child.reloadCount == 1)
      #expect(nested.reloadCount == 1)
    }

    @Test("reloads mark window views as needing layout and display")
    func reloadInvalidatesWindowViews() {
      let controller = RefreshingViewController()
      let window = makeWindow(controller: controller)
      defer { window.close() }
      let probe = LayoutProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
      controller.view.addSubview(probe)
      window.contentView?.layoutSubtreeIfNeeded()
      let layouts = probe.layoutCount

      HotReloadRuntime.simulateReload(declarations: ["LayoutProbeView"])
      #expect(probe.needsLayout)
      #expect(probe.needsDisplay)
      window.contentView?.layoutSubtreeIfNeeded()
      #expect(probe.layoutCount > layouts)

      HotReloadRuntime.redrawsWindowsOnReload = false
      defer { HotReloadRuntime.redrawsWindowsOnReload = true }
      window.contentView?.layoutSubtreeIfNeeded()
      HotReloadRuntime.simulateReload(declarations: ["LayoutProbeView"])
      #expect(!probe.needsLayout)
    }

    @Test("NSTableView visible rows are requested again and remeasured after a reload")
    func tableRowsReload() {
      let source = CountingTableSource(rows: 5)
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
      table.addTableColumn(NSTableColumn(identifier: .init("c")))
      table.dataSource = source
      table.delegate = source
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
      scroll.documentView = table
      let window = NSWindow(
        contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView = scroll
      defer { window.close() }
      table.reloadData()
      table.layoutSubtreeIfNeeded()
      let viewRequests = source.viewRequests
      let heightRequests = source.heightRequests
      #expect(viewRequests > 0)

      let subscription = table.hotReloadReloadsVisibleRows()
      defer { subscription.cancel() }
      source.rowHeight = 30
      HotReloadRuntime.simulateReload(declarations: ["CountingTableSource"])
      table.layoutSubtreeIfNeeded()

      #expect(source.viewRequests >= viewRequests + 5)
      #expect(source.heightRequests > heightRequests)
      #expect(table.rect(ofRow: 1).height == 30)
    }

    @Test("@HotReloadable SwiftUI content in an NSHostingView redraws and keeps its state")
    func hostingViewRedraws() {
      HostedCounters.reset()
      let hosting = NSHostingView(rootView: HostedReloadableRoot())
      let window = makeWindow(view: hosting)
      defer { window.close() }
      settle(hosting)
      let initial = HostedCounters.rootBodies
      #expect(initial >= 1)

      HotReloadRuntime.simulateReload(declarations: ["HostedReloadableRoot"])
      settle(hosting)
      #expect(HostedCounters.rootBodies > initial)
      // @HotReloadable redraws in place: @State isn't reset.
      #expect(HostedCounters.stateInits == 1)
    }

    @Test("rebuildsOnHotReload() recreates an unannotated subtree")
    func rebuildModifierRecreatesSubtree() {
      HostedCounters.reset()
      let hosting = NSHostingController(rootView: HostedPlainLeaf().rebuildsOnHotReload())
      let window = NSWindow(contentViewController: hosting)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      settle(hosting.view)
      let leafBodies = HostedCounters.leafBodies
      #expect(leafBodies >= 1)

      HotReloadRuntime.simulateReload(declarations: ["SomethingElse"])
      settle(hosting.view)
      #expect(HostedCounters.leafBodies > leafBodies)
    }

    @Test("HotReloadViewControllerHost rebuilds an NSHostingController")
    func hostRebuildsHostingController() {
      var builds = 0
      let host = HotReloadViewControllerHost({
        builds += 1
        let controller = NSHostingController(rootView: Text("Build \(builds)"))
        controller.title = "Hosted \(builds)"
        return controller
      }())
      let window = NSWindow(contentViewController: host)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      #expect(window.title == "Hosted 1")

      HotReloadRuntime.simulateReload(declarations: ["HostedScreen"])
      #expect(builds == 2)
      #expect(host.title == "Hosted 2")
      #expect(host.hostedController.view.superview === host.view)
    }

    private func makeWindow(controller: NSViewController) -> NSWindow {
      controller.view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
      let window = NSWindow(contentViewController: controller)
      window.isReleasedWhenClosed = false
      return window
    }

    private func makeWindow(view: NSView) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
        styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView = view
      return window
    }

    private func settle(_ view: NSView) {
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      view.layoutSubtreeIfNeeded()
    }
  }

  @MainActor
  private final class RefreshingViewController: NSViewController, HotReloadRefreshing {
    var reloadCount = 0
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) }
    func hotReloaded() { reloadCount += 1 }
  }

  @MainActor
  private final class RefreshingView: NSView, HotReloadRefreshing {
    var reloadCount = 0
    func hotReloaded() { reloadCount += 1 }
  }

  @MainActor
  private final class LayoutProbeView: NSView {
    var layoutCount = 0
    override func layout() {
      super.layout()
      layoutCount += 1
    }
  }

  @MainActor
  private final class CountingTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let rows: Int
    var rowHeight: CGFloat = 20
    var viewRequests = 0
    var heightRequests = 0
    init(rows: Int) { self.rows = rows }
    func numberOfRows(in tableView: NSTableView) -> Int { rows }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      heightRequests += 1
      return rowHeight
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      viewRequests += 1
      return NSTextField(labelWithString: "Row \(row)")
    }
  }

  @MainActor
  enum HostedCounters {
    static var rootBodies = 0
    static var leafBodies = 0
    static var stateInits = 0
    static func reset() {
      rootBodies = 0
      leafBodies = 0
      stateInits = 0
    }
  }

  @MainActor
  final class HostedStateBox {
    init() { HostedCounters.stateInits += 1 }
  }

  @HotReloadable
  struct HostedReloadableRoot: View {
    @State private var box = HostedStateBox()
    var body: some View {
      HostedCounters.rootBodies += 1
      return Text("Root \(ObjectIdentifier(box).hashValue)")
    }
  }

  struct HostedPlainLeaf: View {
    var body: some View {
      HostedCounters.leafBodies += 1
      return Text("Leaf")
    }
  }
#endif

@MainActor
private final class RefreshableFixture: HotReloadRefreshing {
  var reloadCount = 0
  func hotReloaded() {
    reloadCount += 1
  }
}
