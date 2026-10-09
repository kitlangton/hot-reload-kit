import Combine
import Foundation
import HotReloadProtocol

#if canImport(UIKit)
  import UIKit
#endif

#if DEBUG && (targetEnvironment(simulator) || os(macOS))
  import Darwin
#endif

package enum ReloadResult: Equatable, Sendable {
  case loaded
  case failed(String)
}

public struct HotReloadEvent: Equatable, Sendable {
  public let generation: Int
  public let declarations: [String]

  public init(generation: Int, declarations: [String]) {
    self.generation = generation
    self.declarations = declarations
  }
}

public final class HotReloadSubscription: Sendable {
  private let onCancel: @Sendable () -> Void

  package init(onCancel: @escaping @Sendable () -> Void = {}) {
    self.onCancel = onCancel
  }

  public func cancel() {
    onCancel()
  }
}

@MainActor
public protocol HotReloadRefreshing: AnyObject {
  func hotReloaded()
}

extension HotReloadRefreshing {
  @MainActor
  public func observeHotReload() {
    HotReloadRuntime.register(self)
  }
}

@MainActor
public final class HotReloadObserver: ObservableObject {
  @Published package private(set) var generation = 0

  fileprivate func invalidate() {
    generation += 1
  }
}

#if DEBUG && (targetEnvironment(simulator) || os(macOS))
  @MainActor
  public enum HotReloadRuntime {
    public nonisolated static let didReloadNotification = Notification.Name(
      "HotReloadRuntimeDidReload")

    private final class WeakRefreshingBox {
      weak var value: (any HotReloadRefreshing)?
      init(_ value: any HotReloadRefreshing) {
        self.value = value
      }
    }

    private static var loadedArtifacts: [UnsafeMutableRawPointer] = []
    private static var declarationObservers: [String: HotReloadObserver] = [:]
    private static var reloadHandlers: [UUID: @MainActor (Int) -> Void] = [:]
    private static var streamContinuations: [UUID: AsyncStream<HotReloadEvent>.Continuation] = [:]
    private static var refreshingObjects: [WeakRefreshingBox] = []
    private static var currentGeneration = 0
    private static var hasStarted = false
    private static var manifestTask: Task<Void, Never>?

    public static func observer(for declaration: String) -> HotReloadObserver {
      if let observer = declarationObservers[declaration] { return observer }
      let observer = HotReloadObserver()
      declarationObservers[declaration] = observer
      return observer
    }

    @discardableResult
    public static func onReload(
      _ handler: @escaping @MainActor (Int) -> Void
    ) -> HotReloadSubscription {
      let id = UUID()
      reloadHandlers[id] = handler
      return HotReloadSubscription {
        if Thread.isMainThread {
          MainActor.assumeIsolated {
            _ = reloadHandlers.removeValue(forKey: id)
          }
        } else {
          Task { @MainActor in
            _ = reloadHandlers.removeValue(forKey: id)
          }
        }
      }
    }

    public static func reloads() -> AsyncStream<HotReloadEvent> {
      let id = UUID()
      return AsyncStream { continuation in
        streamContinuations[id] = continuation
        continuation.onTermination = { _ in
          Task { @MainActor in
            streamContinuations.removeValue(forKey: id)
          }
        }
      }
    }

    public static func register(_ object: some HotReloadRefreshing) {
      refreshingObjects.removeAll { $0.value == nil || $0.value === object }
      refreshingObjects.append(WeakRefreshingBox(object))
    }

    public static func start() {
      guard !hasStarted else { return }
      hasStarted = true

      let environment = ProcessInfo.processInfo.environment
      if let manifest = environment["HOTRELOAD_MANIFEST_PATH"],
        let receipt = environment["HOTRELOAD_RECEIPT_PATH"]
      {
        manifestTask = Task.detached {
          await watchManifest(
            at: URL(fileURLWithPath: manifest),
            receiptURL: URL(fileURLWithPath: receipt)
          )
        }
      }
    }

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declaration: String
    ) -> ReloadResult {
      loadArtifact(at: url, declarations: [declaration])
    }

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declarations: [String]
    ) -> ReloadResult {
      dlerror()
      guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
        let message = dlerror().map { String(cString: $0) } ?? "Unknown dlopen error"
        return .failed(message)
      }

      // Swift images remain loaded for the process lifetime. Retaining the handles
      // makes that constraint explicit and prevents accidental dlclose attempts.
      loadedArtifacts.append(handle)
      notifyReload(declarations: declarations)
      return .loaded
    }

    package static func simulateReload(declarations: [String] = ["SimulatedView"]) {
      notifyReload(declarations: declarations)
    }

    private static func invalidateSwiftUIDebugReplaceableViews() {
      guard
        let symbol = dlsym(
          UnsafeMutableRawPointer(bitPattern: -2),
          "$s7SwiftUI20DebugReplaceableViewV20invalidateEverythingyyFZ"
        )
      else { return }
      typealias InvalidateFn = @convention(thin) () -> Void
      let invalidate = unsafeBitCast(symbol, to: InvalidateFn.self)
      invalidate()
    }

    private static func notifyReload(declarations: [String]) {
      currentGeneration += 1
      let generation = currentGeneration

      invalidateSwiftUIDebugReplaceableViews()

      var matchedAllDeclarations = !declarations.isEmpty
      for declaration in declarations {
        if let observer = declarationObservers[declaration] {
          observer.invalidate()
        } else {
          matchedAllDeclarations = false
        }
      }
      if !matchedAllDeclarations {
        for observer in declarationObservers.values {
          observer.invalidate()
        }
      }

      var notifiedObjects: Set<ObjectIdentifier> = []
      refreshingObjects = refreshingObjects.filter { $0.value != nil }
      for box in refreshingObjects {
        if let object = box.value {
          notifiedObjects.insert(ObjectIdentifier(object))
          object.hotReloaded()
        }
      }

      #if canImport(UIKit)
        notifyHierarchyRefreshingObjects(excluding: &notifiedObjects)
      #endif

      let handlers = Array(reloadHandlers.values)
      for handler in handlers {
        handler(generation)
      }

      let event = HotReloadEvent(generation: generation, declarations: declarations)
      for continuation in streamContinuations.values {
        continuation.yield(event)
      }

      NotificationCenter.default.post(
        name: didReloadNotification,
        object: nil,
        userInfo: [
          "generation": generation,
          "declarations": declarations,
        ]
      )
    }

    #if canImport(UIKit)
      private static func notifyHierarchyRefreshingObjects(
        excluding notified: inout Set<ObjectIdentifier>
      ) {
        for scene in UIApplication.shared.connectedScenes {
          guard let windowScene = scene as? UIWindowScene else { continue }
          for window in windowScene.windows {
            if let root = window.rootViewController {
              notifyViewControllerHierarchy(root, excluding: &notified)
            }
            notifyViewHierarchy(window, excluding: &notified)
          }
        }
      }

      private static func notifyViewControllerHierarchy(
        _ controller: UIViewController,
        excluding notified: inout Set<ObjectIdentifier>
      ) {
        let id = ObjectIdentifier(controller)
        if !notified.contains(id), let refreshing = controller as? any HotReloadRefreshing {
          notified.insert(id)
          refreshing.hotReloaded()
        }
        for child in controller.children {
          notifyViewControllerHierarchy(child, excluding: &notified)
        }
        if let presented = controller.presentedViewController {
          notifyViewControllerHierarchy(presented, excluding: &notified)
        }
      }

      private static func notifyViewHierarchy(
        _ view: UIView,
        excluding notified: inout Set<ObjectIdentifier>
      ) {
        let id = ObjectIdentifier(view)
        if !notified.contains(id), let refreshing = view as? any HotReloadRefreshing {
          notified.insert(id)
          refreshing.hotReloaded()
        }
        for subview in view.subviews {
          notifyViewHierarchy(subview, excluding: &notified)
        }
      }
    #endif

    nonisolated private static func watchManifest(at url: URL, receiptURL: URL) async {
      var generation = 0
      var pendingReceipt: ReloadReceipt?
      let decoder = JSONDecoder()
      let encoder = JSONEncoder()

      while !Task.isCancelled {
        if let pending = pendingReceipt,
          let receipt = try? encoder.encode(pending),
          (try? receipt.write(to: receiptURL, options: .atomic)) != nil
        {
          pendingReceipt = nil
        }
        if let data = try? Data(contentsOf: url),
          let command = try? decoder.decode(ReloadCommand.self, from: data),
          command.generation > generation
        {
          let result = await loadArtifact(
            at: URL(fileURLWithPath: command.artifactPath),
            declarations: command.declarations
          )
          generation = command.generation
          let error: String?
          switch result {
          case .loaded: error = nil
          case .failed(let message): error = message
          }
          let receipt = ReloadReceipt(generation: generation, error: error)
          if let encoded = try? encoder.encode(receipt),
            (try? encoded.write(to: receiptURL, options: .atomic)) != nil
          {
            pendingReceipt = nil
          } else {
            pendingReceipt = receipt
          }
        }
        try? await Task.sleep(for: .milliseconds(120))
      }
    }

  }
#else
  @MainActor
  public enum HotReloadRuntime {
    public nonisolated static let didReloadNotification = Notification.Name(
      "HotReloadRuntimeDidReload")

    private static let disabledObserver = HotReloadObserver()

    public static func observer(for declaration: String) -> HotReloadObserver {
      disabledObserver
    }

    @discardableResult
    public static func onReload(
      _ handler: @escaping @MainActor (Int) -> Void
    ) -> HotReloadSubscription {
      HotReloadSubscription()
    }

    public static func reloads() -> AsyncStream<HotReloadEvent> {
      AsyncStream { $0.finish() }
    }

    public static func register(_ object: some HotReloadRefreshing) {}

    public static func start() {}

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declaration: String
    ) -> ReloadResult {
      .failed("HotReloadRuntime is disabled outside Debug simulator builds")
    }

    @discardableResult
    package static func loadArtifact(
      at url: URL,
      declarations: [String]
    ) -> ReloadResult {
      .failed("HotReloadRuntime is disabled outside Debug simulator builds")
    }

    package static func simulateReload(declarations: [String] = ["SimulatedView"]) {}
  }
#endif
