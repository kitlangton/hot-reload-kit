import HotReloadUI
import SwiftUI
import UIKit

final class UIKitStatusCardView: UIView {
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureCard()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configureCard() {
    backgroundColor = .secondarySystemBackground
    layer.cornerRadius = 12
    label.text = "Hosted UIKit View"
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
    ])
  }
}

final class UIKitPreviewViewController: UIViewController, HotReloadRefreshing {
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private var tapCount = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    observeHotReload()

    let cardHost = HotReloadViewHost(UIKitStatusCardView())
    let button = UIButton(type: .system)
    button.setTitle("UIKit Tap", for: .normal)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        tapCount += 1
        renderContent()
      },
      for: .touchUpInside
    )

    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.textAlignment = .center
    detailLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    detailLabel.textColor = .secondaryLabel
    detailLabel.textAlignment = .center

    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, button, cardHost])
    stack.axis = .vertical
    stack.spacing = 8
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])

    renderContent()
  }

  func hotReloaded() {
    renderContent()
  }

  func renderContent() {
    titleLabel.text = "UIKit Hook Active"
    detailLabel.text = "UIKit taps preserved: \(tapCount)"
  }
}

struct UIKitPreviewSection: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> UIViewController {
    UIKitPreviewViewController()
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
