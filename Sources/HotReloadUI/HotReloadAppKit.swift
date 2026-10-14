import HotReloadRuntime

#if canImport(AppKit) && !canImport(UIKit)
  import AppKit

  /// Rebuilds its hosted view controller on every hot reload.
  ///
  /// Wrap a creation site whose controller builds its view hierarchy in
  /// `loadView()`/`viewDidLoad()` (or an `NSHostingController`), so a replaced
  /// method shows on the next reload. The hosted controller is recreated, so
  /// keep state you want to survive in a model outside it. In Release builds
  /// it's an inert container.
  @MainActor
  public final class HotReloadViewControllerHost<Hosted: NSViewController>: NSViewController {
    public private(set) var hostedController: Hosted
    #if DEBUG
      private let buildController: @MainActor () -> Hosted
      private var reloadSubscription: HotReloadSubscription?
    #endif

    public init(_ build: @autoclosure @escaping @MainActor () -> Hosted) {
      let initial = build()
      self.hostedController = initial
      #if DEBUG
        self.buildController = build
      #endif
      super.init(nibName: nil, bundle: nil)
      forwardProperties(from: initial)
      #if DEBUG
        reloadSubscription = HotReloadRuntime.onReload { [weak self] _ in
          self?.rebuildHostedController()
        }
      #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    deinit {
      #if DEBUG
        reloadSubscription?.cancel()
      #endif
    }

    public override func loadView() {
      view = NSView()
      embed(hostedController)
    }

    public override var preferredMinimumSize: NSSize { hostedController.preferredMinimumSize }
    public override var preferredMaximumSize: NSSize { hostedController.preferredMaximumSize }

    private func embed(_ controller: Hosted) {
      addChild(controller)
      let child = controller.view
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
      NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        child.topAnchor.constraint(equalTo: view.topAnchor),
        child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      forwardProperties(from: controller)
    }

    private func forwardProperties(from controller: Hosted) {
      // A window's title follows its content view controller's title.
      title = controller.title
      identifier = controller.identifier
      representedObject = controller.representedObject
      preferredContentSize = controller.preferredContentSize
    }

    #if DEBUG
      private func rebuildHostedController() {
        let old = hostedController
        let window = viewIfLoaded?.window
        let hadFocus = Self.contains(window?.firstResponder, in: old.viewIfLoaded)
        if old.parent === self {
          old.viewIfLoaded?.removeFromSuperview()
          old.removeFromParent()
        }
        let fresh = buildController()
        hostedController = fresh
        if isViewLoaded {
          embed(fresh)
          if hadFocus, let window {
            window.makeFirstResponder(fresh.view.nextValidKeyView ?? fresh.view)
          }
        } else {
          forwardProperties(from: fresh)
        }
      }

      private static func contains(_ responder: NSResponder?, in view: NSView?) -> Bool {
        guard let view, let responderView = responder as? NSView else { return false }
        return responderView === view || responderView.isDescendant(of: view)
      }
    #endif
  }

  /// Rebuilds its hosted view on every hot reload.
  ///
  /// Wrap a creation site whose view builds its subviews in `init(frame:)`, so
  /// a replaced initializer helper or configuration method shows on the next
  /// reload. In Release builds it's an inert container.
  @MainActor
  public final class HotReloadViewHost<Hosted: NSView>: NSView {
    public private(set) var hostedView: Hosted
    #if DEBUG
      private let buildView: @MainActor () -> Hosted
      private var reloadSubscription: HotReloadSubscription?
    #endif

    public init(_ build: @autoclosure @escaping @MainActor () -> Hosted) {
      let initial = build()
      self.hostedView = initial
      #if DEBUG
        self.buildView = build
      #endif
      super.init(frame: initial.frame)
      embed(initial)
      #if DEBUG
        reloadSubscription = HotReloadRuntime.onReload { [weak self] _ in
          self?.rebuildHostedView()
        }
      #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    deinit {
      #if DEBUG
        reloadSubscription?.cancel()
      #endif
    }

    public override var intrinsicContentSize: NSSize {
      hostedView.intrinsicContentSize
    }

    public override var isFlipped: Bool { hostedView.isFlipped }

    private func embed(_ child: Hosted) {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
      NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: leadingAnchor),
        child.trailingAnchor.constraint(equalTo: trailingAnchor),
        child.topAnchor.constraint(equalTo: topAnchor),
        child.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    #if DEBUG
      private func rebuildHostedView() {
        hostedView.removeFromSuperview()
        let fresh = buildView()
        hostedView = fresh
        embed(fresh)
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
      }
    #endif
  }

  extension NSTableView {
    /// Reloads the visible rows after each hot reload and notes their heights,
    /// so cell views configured by a replaced method (or hosting a replaced
    /// SwiftUI body) pick up the change and variable-height rows remeasure.
    ///
    /// The data source is asked for the visible rows' views again
    /// (`tableView(_:viewFor:row:)`) and the delegate for their heights.
    @MainActor
    @discardableResult
    public func hotReloadReloadsVisibleRows() -> HotReloadSubscription {
      #if DEBUG
        return HotReloadRuntime.onReload { [weak self] _ in
          self?.reloadVisibleRowsForHotReload()
        }
      #else
        return HotReloadSubscription()
      #endif
    }

    @MainActor
    func reloadVisibleRowsForHotReload() {
      let range = rows(in: visibleRect)
      guard range.length > 0, numberOfColumns > 0 else { return }
      let rows = IndexSet(integersIn: range.location..<(range.location + range.length))
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
      noteHeightOfRows(withIndexesChanged: rows)
      NSAnimationContext.endGrouping()
      for row in rows {
        rowView(atRow: row, makeIfNecessary: false)?.needsLayout = true
      }
    }
  }

  extension NSCollectionView {
    /// Reloads the visible items and invalidates the layout after each hot
    /// reload, so items configured by a replaced method resize in place.
    @MainActor
    @discardableResult
    public func hotReloadReconfiguresVisibleItems() -> HotReloadSubscription {
      #if DEBUG
        return HotReloadRuntime.onReload { [weak self] _ in
          guard let self else { return }
          let visible = indexPathsForVisibleItems()
          if !visible.isEmpty {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            reloadItems(at: visible)
            NSAnimationContext.endGrouping()
          }
          collectionViewLayout?.invalidateLayout()
          layoutSubtreeIfNeeded()
        }
      #else
        return HotReloadSubscription()
      #endif
    }

    /// Diffable variant: reloads the visible item identifiers through the data
    /// source's snapshot after each hot reload, then invalidates the layout.
    @MainActor
    @discardableResult
    public func hotReloadReconfiguresVisibleItems<
      Section: Hashable & Sendable, Item: Hashable & Sendable
    >(
      using dataSource: NSCollectionViewDiffableDataSource<Section, Item>
    ) -> HotReloadSubscription {
      #if DEBUG
        return HotReloadRuntime.onReload { [weak self, weak dataSource] _ in
          guard let self, let dataSource else { return }
          let visibleItems = indexPathsForVisibleItems().compactMap {
            dataSource.itemIdentifier(for: $0)
          }
          if !visibleItems.isEmpty {
            var snapshot = dataSource.snapshot()
            let existing = Set(snapshot.itemIdentifiers)
            let valid = visibleItems.filter(existing.contains)
            if !valid.isEmpty {
              snapshot.reloadItems(valid)
              dataSource.apply(snapshot, animatingDifferences: false)
            }
          }
          collectionViewLayout?.invalidateLayout()
          layoutSubtreeIfNeeded()
        }
      #else
        return HotReloadSubscription()
      #endif
    }
  }
#endif
