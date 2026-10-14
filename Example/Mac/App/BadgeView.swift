import AppKit
import HotReloadUI

/// A plain AppKit view. Its methods hot-reload in place: the runtime calls
/// `hotReloaded()` on views in the app's windows after each reload, and marks
/// them as needing layout and display, so a replaced `applyStyling()` or
/// `draw(_:)` shows at once.
final class BadgeView: NSView, HotReloadRefreshing {
  private let label = NSTextField(labelWithString: "")

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    applyStyling()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func hotReloaded() {
    applyStyling()
  }

  func applyStyling() {
    label.stringValue = Probe.record("appkit", "AppKit Method")
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = .labelColor
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
  }
}
