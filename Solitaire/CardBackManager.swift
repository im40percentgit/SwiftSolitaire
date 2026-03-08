// CardBackManager.swift — Manages the active card back style (Classic or Corgi)
// and the current card back image. Persists the user's choice via UserDefaults
// and broadcasts changes via NotificationCenter so all CardViews can refresh
// without the manager holding direct references to views.
//
//  Solitaire
//
//  Created for the Card Back Style Selector feature.
//  Copyright © 2024 Gary Hanson. All rights reserved.
//

/**
 * @decision DEC-CARDBACK-001
 * @title Card back style persistence via UserDefaults singleton
 * @status accepted
 * @rationale A singleton centralizes style state so all CardViews observe a
 *   single source of truth. UserDefaults provides zero-setup persistence across
 *   launches without requiring a database or file I/O. NotificationCenter
 *   broadcast lets every existing CardView update itself without the manager
 *   holding references to views.
 */

import UIKit

// MARK: - CardBackStyle

/// The two supported card back visual styles.
enum CardBackStyle: String {
    case classic
    case corgi
}

// MARK: - CardBackManager

/// Singleton that owns the active card back style and image.
///
/// Observers subscribe to `Notification.Name.cardBackDidChange` to refresh
/// their displayed image whenever the style or corgi selection changes.
final class CardBackManager {

    // MARK: Shared instance

    static let shared = CardBackManager()

    // MARK: Constants

    private static let userDefaultsKey = "cardBackStyle"
    private static let corgiCount = 52

    // MARK: State

    /// The active card back style. Setting this value persists the choice,
    /// reloads the current image, and broadcasts `cardBackDidChange`.
    var style: CardBackStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: CardBackManager.userDefaultsKey)
            reloadImage()
            postChangeNotification()
        }
    }

    /// The image currently representing the card back.
    private(set) var currentImage: UIImage

    /// Index of the corgi image currently in use (1–52).
    private var corgiIndex: Int = 1

    // MARK: Init

    private init() {
        // Restore persisted style, defaulting to classic.
        let savedRaw = UserDefaults.standard.string(forKey: CardBackManager.userDefaultsKey) ?? ""
        style = CardBackStyle(rawValue: savedRaw) ?? .classic

        // Load a random corgi index so the first new deal randomises correctly.
        corgiIndex = Int.random(in: 1...CardBackManager.corgiCount)

        // Bootstrap currentImage without triggering didSet notification.
        currentImage = CardBackManager.imageForStyle(style, corgiIndex: corgiIndex)
    }

    // MARK: Public API

    /// Picks a new random corgi image and, if the current style is corgi,
    /// reloads `currentImage` and broadcasts `cardBackDidChange`.
    func randomizeCorgi() {
        corgiIndex = Int.random(in: 1...CardBackManager.corgiCount)
        if style == .corgi {
            reloadImage()
            postChangeNotification()
        }
    }

    // MARK: Private helpers

    private func reloadImage() {
        currentImage = CardBackManager.imageForStyle(style, corgiIndex: corgiIndex)
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .cardBackDidChange, object: nil)
    }

    /// Loads the appropriate UIImage for the given style + corgi index.
    /// Falls back to a solid-colour placeholder if the asset is missing so the
    /// app never crashes due to a missing resource.
    private static func imageForStyle(_ style: CardBackStyle, corgiIndex: Int) -> UIImage {
        switch style {
        case .classic:
            return UIImage(named: "images/PlayingCard-back.png") ?? UIImage()
        case .corgi:
            let name = String(format: "images/corgi/corgi-%02d.jpg", corgiIndex)
            return UIImage(named: name) ?? UIImage(named: "images/PlayingCard-back.png") ?? UIImage()
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted by `CardBackManager` whenever the card back image changes.
    static let cardBackDidChange = Notification.Name("CardBackDidChange")
}
