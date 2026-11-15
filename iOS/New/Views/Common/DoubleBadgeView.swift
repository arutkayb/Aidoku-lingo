//
//  DoubleBadgeView.swift
//  Aidoku
//
//  Created by Skitty on 11/21/25.
//

import UIKit

class DoubleBadgeView: UIView {
    var badgeNumber: Int = 0 {
        didSet {
            badgeLabel.text = badgeNumber == 0 ? nil : String(badgeNumber)
            updateLayout()
        }
    }

    var badgeNumber2: Int = 0 {
        didSet {
            badgeLabel2.text = badgeNumber2 == 0 ? nil : String(badgeNumber2)
            updateLayout()
        }
    }

    var badgeNumber3: Int = 0 {
        didSet {
            badgeLabel3.text = badgeNumber3 == 0 ? nil : String(badgeNumber3)
            badgeView3.accessibilityValue = badgeLabel3.text
            updateLayout()
        }
    }

    private lazy var badgeView = {
        let badgeView = UIView()
        badgeView.isHidden = true
        badgeView.backgroundColor = tintColor
        badgeView.layer.cornerRadius = 5
        badgeView.addSubview(badgeLabel)
        return badgeView
    }()

    private let badgeLabel = {
        let badgeLabel = UILabel()
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        return badgeLabel
    }()

    private lazy var badgeView2 = {
        let badgeView = UIView()
        badgeView.isHidden = true
        badgeView.backgroundColor = .systemIndigo
        badgeView.layer.cornerRadius = 5
        badgeView.addSubview(badgeLabel2)
        return badgeView
    }()

    private let badgeLabel2 = {
        let badgeLabel = UILabel()
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        return badgeLabel
    }()

    private lazy var badgeView3 = {
        let badgeView = UIView()
        badgeView.isHidden = true
        badgeView.backgroundColor = .systemGreen
        badgeView.layer.cornerRadius = 5
        badgeView.isAccessibilityElement = true
        badgeView.accessibilityLabel = NSLocalizedString("NEW_CHAPTERS")
        badgeView.addSubview(badgeLabel3)
        return badgeView
    }()

    private let badgeLabel3 = {
        let badgeLabel = UILabel()
        badgeLabel.textColor = .white
        badgeLabel.numberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        return badgeLabel
    }()

    private var badgeConstraints: [NSLayoutConstraint] = []

    override var intrinsicContentSize: CGSize {
        var width: CGFloat = 0
        if !badgeView.isHidden {
            width += (badgeLabel.text?.size(withAttributes: [.font: badgeLabel.font as Any]).width ?? 0) + 10
        }
        if !badgeView2.isHidden {
            width += (badgeLabel2.text?.size(withAttributes: [.font: badgeLabel2.font as Any]).width ?? 0) + 10
        }
        if !badgeView3.isHidden {
            width += (badgeLabel3.text?.size(withAttributes: [.font: badgeLabel3.font as Any]).width ?? 0) + 10
        }
        return CGSize(width: width, height: 20)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        constrain()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure() {
        addSubview(badgeView)
        addSubview(badgeView2)
        addSubview(badgeView3)
    }

    func constrain() {
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView2.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel2.translatesAutoresizingMaskIntoConstraints = false
        badgeView3.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel3.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel2.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel2.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel3.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel3.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.widthAnchor.constraint(equalTo: badgeLabel.widthAnchor, constant: 10),
            badgeView.heightAnchor.constraint(equalToConstant: 20),
            badgeLabel.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

            badgeView2.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView2.widthAnchor.constraint(equalTo: badgeLabel2.widthAnchor, constant: 10),
            badgeView2.heightAnchor.constraint(equalToConstant: 20),
            badgeLabel2.centerXAnchor.constraint(equalTo: badgeView2.centerXAnchor),
            badgeLabel2.centerYAnchor.constraint(equalTo: badgeView2.centerYAnchor),

            badgeView3.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView3.widthAnchor.constraint(equalTo: badgeLabel3.widthAnchor, constant: 10),
            badgeView3.heightAnchor.constraint(equalToConstant: 20),
            badgeLabel3.centerXAnchor.constraint(equalTo: badgeView3.centerXAnchor),
            badgeLabel3.centerYAnchor.constraint(equalTo: badgeView3.centerYAnchor)
        ])

        updateLayout()
    }

    override func tintColorDidChange() {
        badgeView.backgroundColor = tintColor
        if tintAdjustmentMode == .dimmed {
            badgeView2.backgroundColor = .systemIndigo.grayscale()
            badgeView3.backgroundColor = .systemGreen.grayscale()
        } else {
            badgeView2.backgroundColor = .systemIndigo
            badgeView3.backgroundColor = .systemGreen
        }
    }

    func updateLayout() {
        NSLayoutConstraint.deactivate(badgeConstraints)
        badgeConstraints = []
        let badges = [(badgeView, badgeNumber), (badgeView2, badgeNumber2), (badgeView3, badgeNumber3)]
        let visibleBadges = badges.filter { $0.1 > 0 }.map(\.0)
        var previous: UIView?
        for (view, count) in badges {
            view.isHidden = count <= 0
            badgeConstraints.append(view.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? leadingAnchor))
            guard count > 0 else { continue }
            view.layer.maskedCorners = []
            if view === visibleBadges.first {
                view.layer.maskedCorners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
            }
            if view === visibleBadges.last {
                view.layer.maskedCorners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
            }
            previous = view
        }
        NSLayoutConstraint.activate(badgeConstraints)
        invalidateIntrinsicContentSize()
    }
}

private extension UIColor {
    /// Returns a grayscale version of the color.
    func grayscale() -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }

        let gray = red * 0.299 + green * 0.587 + blue * 0.114
        return UIColor(red: gray, green: gray, blue: gray, alpha: alpha)
    }
}
