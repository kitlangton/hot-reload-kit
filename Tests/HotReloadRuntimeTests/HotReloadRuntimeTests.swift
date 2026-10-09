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
    }
  #endif
}

@MainActor
private final class RefreshableFixture: HotReloadRefreshing {
  var reloadCount = 0
  func hotReloaded() {
    reloadCount += 1
  }
}
