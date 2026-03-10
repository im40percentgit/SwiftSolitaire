// Game.swift — Game logic singleton and move history for undo.
// Owns the ordered move history (moveHistory). Each recorded Move is a value-type
// snapshot of which cards moved, from where, to where, and whether the source's
// new top card was flipped face-up as a side-effect. SolitaireGameView records
// moves at each call site; Game.undoLast() is called by the Undo button action.
//
//  Created by Gary on 4/22/19.
//  Copyright © 2019 Gary Hanson. All rights reserved.
//

import UIKit

// MARK: - Move Model Types

/**
 * @decision DEC-UNDO-001
 * @title Value-type move history for undo
 * @status accepted
 * @rationale Using value types (enum + struct) for move history means each
 *   recorded move is an immutable snapshot. No aliasing hazards — undoing a
 *   move always restores exactly the cards that were captured at move time,
 *   regardless of what happened to the originating stack afterward.
 *   StackIdentifier as an enum (rather than a weak reference) avoids dangling
 *   pointer risk if views are ever recreated on new deal.
 */
enum StackIdentifier {
    case tableau(Int)      // 0-6
    case foundation(Int)   // 0-3
    case talon
    case stock
}

enum MoveType {
    case dragDrop, doubleTap, stockToTalon, recycleToStock
}

struct Move {
    let type: MoveType
    let cards: [Card]
    let source: StackIdentifier
    let destination: StackIdentifier
    let didFlipSourceTopCard: Bool
}

// MARK: - Game

class Game {
    static let sharedInstance = Game()

    /// Ordered history of moves; last element is the most recent.
    private(set) var moveHistory = [Move]()

    private init() {}

    // MARK: Move History

    func recordMove(_ move: Move) {
        moveHistory.append(move)
    }

    func clearMoveHistory() {
        moveHistory.removeAll()
    }

    var canUndo: Bool {
        return !moveHistory.isEmpty
    }

    // MARK: Card Operations

    func moveTopCard(from: CardDataStack, to: CardDataStack, faceUp: Bool, makeNewTopCardFaceup: Bool) {
        var card = from.topCard()
        if (card != nil) {
            card!.faceUp = faceUp
            to.addCard(card: card!)
            from.popCards(numberToPop: 1, makeNewTopCardFaceup: makeNewTopCardFaceup)
        }
    }

    func copyCards(from: CardDataStack, to: CardDataStack) {
        from.cards.forEach( { _ in self.moveTopCard(from: from, to: to, faceUp: false, makeNewTopCardFaceup: false) })
    }

    func shuffle() {
        Model.sharedInstance.shuffle()
    }

    func initalizeDeal() {
        self.shuffle()

        Model.sharedInstance.tableauStacks.forEach { $0.removeAllCards() }
        Model.sharedInstance.foundationStacks.forEach { $0.removeAllCards() }
        Model.sharedInstance.talonStack.removeAllCards()
        Model.sharedInstance.stockStack.removeAllCards()

        clearMoveHistory()
    }

}
