// CardView.swift — UIView subclass that renders a single playing card. Displays
// either the face (suit, rank, card image) or the card back provided by
// CardBackManager. Observes CardBackDidChange notifications so the back image
// updates immediately when the user switches styles without requiring a redeal.
//
//  CardStacks
//
//  Created by Gary on 4/22/19.
//  Copyright © 2019 Gary Hanson. All rights reserved.
//

import UIKit

let numberOfCardsInSuit = 13


enum Suit: Int {
    case spades, diamonds, hearts, clubs
    
    func name() -> String {
        switch (self) {
        case .clubs:
            return "Club"
        case .diamonds:
            return "Diamond"
        case .hearts:
            return "Heart"
        case .spades:
            return "Spade"
        }
    }
}


/**
 * @decision DEC-CARDBACK-002
 * @title CardView observes CardBackDidChange rather than holding a style reference
 * @status accepted
 * @rationale Each CardView independently observes the notification so the
 *   manager needs no view registry. The backgroundImageView frame is set to
 *   CGRect(origin:.zero, size:frame.size) — using the raw `frame` caused the
 *   image to be offset by the card's position in the superview's coordinate
 *   space, clipping the card back graphic.
 */
// UIView that displays a card
final class CardView: UIView {

    // the card value is its position in the 0..51 array of possible card values. see
    // getCardSuitAndRank to see how suit and rank are determined from the value
    var cardValue = 0       // suit and rank of card
    
    var faceUp: Bool = false {
        didSet {
            self.backgroundImageView.isHidden = self.faceUp
        }
    }
    
    var isFaceUp: Bool {
        return faceUp
    }
    
    var isKing: Bool {
        return cardValue % numberOfCardsInSuit == 12
    }
    
    var isAce: Bool {
        return cardValue % numberOfCardsInSuit == 0
    }
    
    private let mainImageView: UIImageView
    private let suitImageView: UIImageView
    private let rankLabel: UILabel
    private let backgroundImageView: UIImageView
    
    
    private func getDisplayValueForRank(rank: Int) -> String {
        var retString = ""
        
        switch (rank) {
        case 0:
            retString = "A"
        case 10:
            retString = "J"
        case 11:
            retString = "Q"
        case 12:
            retString = "K"
        default:
            retString = String(rank + 1)
        }
        
        return retString
    }
    
    private func getSuitAndColor() -> (suit: Suit, color: UIColor) {
        
        let suit = Suit(rawValue: self.cardValue / numberOfCardsInSuit)!
        var color: UIColor
        
        switch (suit) {
            case .spades, .clubs:
                color = .black
            case .hearts, .diamonds:
                color = .red
        }
        
        return (suit, color)
    }
    
    func getCardSuitAndRank() -> (suit: Suit, rank: Int) {
        let suit = Suit(rawValue: self.cardValue / numberOfCardsInSuit)!
        let rank = (self.cardValue % numberOfCardsInSuit)
        
        return (suit, rank)
    }
    
    private func getSuitImage() -> UIImage {
        
        let (suit, _) = getCardSuitAndRank()
        let suitName = suit.name()
        return UIImage(named: "images/\(suitName)2.png")!
    }
    
    private func getCardImage() -> UIImage {
        
        let (suit, rank) = getCardSuitAndRank()
        let suitName = suit.name()
        
        switch (rank) {
        case 10, 11, 12:
            var rankString = getDisplayValueForRank(rank: rank)
            rankString = suitName + "-" + rankString
            return UIImage(named: "images/\(rankString).png")!
        default:
            return UIImage(named: "images/\(suitName).png")!
        }
    }
    
    convenience init(frame: CGRect, value: Int, faceUp: Bool = false) {
        self.init(frame: frame)
        
        self.backgroundColor = .white
        
        self.clipsToBounds = true
        self.isUserInteractionEnabled = false
        self.layer.cornerRadius = 7.0
        self.layer.borderWidth = 1.0
        self.layer.borderColor = UIColor.gray.cgColor
        
        self.cardValue = value
        self.faceUp = faceUp
        
        let (_, color) = getSuitAndColor()
        self.mainImageView.image = getCardImage()
        self.suitImageView.image = getSuitImage()
        let (_, rank) = getCardSuitAndRank()
        self.rankLabel.text = getDisplayValueForRank(rank: rank)
        self.rankLabel.textColor = color
        self.rankLabel.font = UIFont(name: "Palatino-Bold", size: scaled(value: 16.0))
        self.backgroundImageView.image = CardBackManager.shared.image(forCardValue: value)

        self.addSubview(self.mainImageView)
        self.addSubview(self.suitImageView)
        self.addSubview(self.rankLabel)
        self.addSubview(self.backgroundImageView)

        // Refresh the card back image whenever the user switches styles.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cardBackDidChange),
            name: .cardBackDidChange,
            object: nil
        )
    }

    @objc private func cardBackDidChange() {
        self.backgroundImageView.image = CardBackManager.shared.image(forCardValue: self.cardValue)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .cardBackDidChange, object: nil)
    }

    override init(frame: CGRect) {
        let imageFrame = CGRect(x: 2.0, y: frame.height * 0.40, width: frame.width - 4.0, height: frame.height * 0.60 - 2.0)
        self.mainImageView = UIImageView(frame: imageFrame)
        self.mainImageView.contentMode = .scaleAspectFit
        
        let width = scaled(value: 20.0)
        let height = scaled(value: 16.0)
        let rankFrame = CGRect(x: scaled(value: 4.0), y: scaled(value: 3.0), width: width, height: height)
        self.rankLabel = UILabel(frame: rankFrame)
        
        let suitFrame = CGRect(x: frame.width - width - 4, y: scaled(value: 2.0), width: width, height: height)
        self.suitImageView = UIImageView(frame: suitFrame)
        
        self.backgroundImageView = UIImageView(frame: CGRect(origin: .zero, size: frame.size))
        self.backgroundImageView.contentMode = .scaleAspectFill
        self.backgroundImageView.clipsToBounds = true
        self.backgroundImageView.isHidden = true
        
        super.init(frame: frame)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
