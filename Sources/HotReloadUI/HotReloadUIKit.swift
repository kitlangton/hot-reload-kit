import HotReloadRuntime

#if canImport(UIKit)
  import UIKit

  @MainActor
  public final class HotReloadViewControllerHost<Hosted: UIViewController>: UIViewController {
    public private(set) var hostedController: Hosted
    #if DEBUG && targetEnvironment(simulator)
      private let buildController: @MainActor () -> Hosted
      private var reloadSubscription: HotReloadSubscription?
    #endif

    public init(_ build: @autoclosure @escaping @MainActor () -> Hosted) {
      let initial = build()
      self.hostedController = initial
      #if DEBUG && targetEnvironment(simulator)
        self.buildController = build
      #endif
      super.init(nibName: nil, bundle: nil)
      forwardProperties(from: initial)
      #if DEBUG && targetEnvironment(simulator)
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
      #if DEBUG && targetEnvironment(simulator)
        reloadSubscription?.cancel()
      #endif
    }

    public override func viewDidLoad() {
      super.viewDidLoad()
      embed(hostedController)
    }

    public override var childForStatusBarStyle: UIViewController? { hostedController }
    public override var childForStatusBarHidden: UIViewController? { hostedController }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { hostedController }
    public override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
      hostedController
    }

    private func embed(_ controller: Hosted) {
      addChild(controller)
      controller.view.frame = view.bounds
      controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(controller.view)
      controller.didMove(toParent: self)
      forwardProperties(from: controller)
    }

    private func forwardProperties(from controller: Hosted) {
      title = controller.title
      navigationItem.title = controller.navigationItem.title ?? controller.title
      navigationItem.prompt = controller.navigationItem.prompt
      navigationItem.largeTitleDisplayMode = controller.navigationItem.largeTitleDisplayMode
      navigationItem.leftBarButtonItems = controller.navigationItem.leftBarButtonItems
      navigationItem.rightBarButtonItems = controller.navigationItem.rightBarButtonItems
      navigationItem.leftItemsSupplementBackButton =
        controller.navigationItem.leftItemsSupplementBackButton
      navigationItem.titleView = controller.navigationItem.titleView
      navigationItem.searchController = controller.navigationItem.searchController
      navigationItem.hidesSearchBarWhenScrolling =
        controller.navigationItem.hidesSearchBarWhenScrolling
      navigationItem.hidesBackButton = controller.navigationItem.hidesBackButton
      navigationItem.backButtonTitle = controller.navigationItem.backButtonTitle
      navigationItem.backButtonDisplayMode = controller.navigationItem.backButtonDisplayMode
      navigationItem.backAction = controller.navigationItem.backAction
      navigationItem.style = controller.navigationItem.style
      toolbarItems = controller.toolbarItems
      tabBarItem = controller.tabBarItem
      hidesBottomBarWhenPushed = controller.hidesBottomBarWhenPushed
      preferredContentSize = controller.preferredContentSize
      setNeedsStatusBarAppearanceUpdate()
    }

    #if DEBUG && targetEnvironment(simulator)
      private func rebuildHostedController() {
        let old = hostedController
        if old.parent === self {
          old.willMove(toParent: nil)
          old.viewIfLoaded?.removeFromSuperview()
          old.removeFromParent()
        }
        let fresh = buildController()
        hostedController = fresh
        if isViewLoaded {
          embed(fresh)
        } else {
          forwardProperties(from: fresh)
        }
      }
    #endif
  }

  @MainActor
  public final class HotReloadViewHost<Hosted: UIView>: UIView {
    public private(set) var hostedView: Hosted
    #if DEBUG && targetEnvironment(simulator)
      private let buildView: @MainActor () -> Hosted
      private var reloadSubscription: HotReloadSubscription?
    #endif

    public init(_ build: @autoclosure @escaping @MainActor () -> Hosted) {
      let initial = build()
      self.hostedView = initial
      #if DEBUG && targetEnvironment(simulator)
        self.buildView = build
      #endif
      super.init(frame: initial.frame)
      embed(initial)
      #if DEBUG && targetEnvironment(simulator)
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
      #if DEBUG && targetEnvironment(simulator)
        reloadSubscription?.cancel()
      #endif
    }

    public override var intrinsicContentSize: CGSize {
      hostedView.intrinsicContentSize
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
      hostedView.sizeThatFits(size)
    }

    private func embed(_ child: Hosted) {
      child.frame = bounds
      child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(child)
    }

    #if DEBUG && targetEnvironment(simulator)
      private func rebuildHostedView() {
        hostedView.removeFromSuperview()
        let fresh = buildView()
        hostedView = fresh
        embed(fresh)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()
      }
    #endif
  }

  extension UICollectionView {
    @MainActor
    @discardableResult
    public func hotReloadReconfiguresVisibleItems() -> HotReloadSubscription {
      #if DEBUG && targetEnvironment(simulator)
        return HotReloadRuntime.onReload { [weak self] _ in
          guard let self else { return }
          let visible = indexPathsForVisibleItems
          if !visible.isEmpty {
            reconfigureItems(at: visible)
          }
          for cell in visibleCells {
            cell.invalidateIntrinsicContentSize()
            cell.setNeedsLayout()
          }
          collectionViewLayout.invalidateLayout()
          layoutIfNeeded()
        }
      #else
        return HotReloadSubscription()
      #endif
    }

    @MainActor
    @discardableResult
    public func hotReloadReconfiguresVisibleItems<
      Section: Hashable & Sendable, Item: Hashable & Sendable
    >(
      using dataSource: UICollectionViewDiffableDataSource<Section, Item>
    ) -> HotReloadSubscription {
      #if DEBUG && targetEnvironment(simulator)
        return HotReloadRuntime.onReload { [weak self, weak dataSource] _ in
          guard let self, let dataSource else { return }
          let visibleItems = indexPathsForVisibleItems.compactMap {
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
          for cell in visibleCells {
            cell.invalidateIntrinsicContentSize()
            cell.setNeedsLayout()
          }
          collectionViewLayout.invalidateLayout()
          layoutIfNeeded()
        }
      #else
        return HotReloadSubscription()
      #endif
    }
  }
#elseif canImport(AppKit)
  import AppKit

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
      self.title = initial.title
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

    private func embed(_ controller: Hosted) {
      addChild(controller)
      controller.view.frame = view.bounds
      controller.view.autoresizingMask = [.width, .height]
      view.addSubview(controller.view)
      title = controller.title
      preferredContentSize = controller.preferredContentSize
    }

    #if DEBUG
      private func rebuildHostedController() {
        let old = hostedController
        if old.parent === self {
          old.view.removeFromSuperview()
          old.removeFromParent()
        }
        let fresh = buildController()
        hostedController = fresh
        if isViewLoaded {
          embed(fresh)
        } else {
          title = fresh.title
          preferredContentSize = fresh.preferredContentSize
        }
      }
    #endif
  }

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

    private func embed(_ child: NSView) {
      child.frame = bounds
      child.autoresizingMask = [.width, .height]
      addSubview(child)
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
#endif
