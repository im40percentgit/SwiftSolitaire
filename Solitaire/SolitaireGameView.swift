// SolitaireGameView.swift — Root UIView for the solitaire game. Manages layout
// of foundation stacks, tableau stacks, stock, talon, and control buttons.
// Hosts the "Style" button that presents the card back style picker, and calls
// CardBackManager.randomizeCorgi() on each new deal so every game shows a
// different corgi image when corgi mode is active.
//
// Drag handling: touchesBegan now guards against mid-drag re-entry (multitouch
// or rapid tap) by restoring in-flight cards to their source stack before starting
// a new drag. Force-unwrap on card index replaced with nil-safe if-let.
// ensureTableauTopCardsFaceUp() called as defense-in-depth after drag completion.
//
// Undo: every move (drag-drop, double-tap, stock-to-talon, recycle) is recorded
// in Game.sharedInstance.moveHistory. The Undo button calls undoAction() which
// pops the last Move and reverses it against the live data stacks.
//
// Win animation: when all 52 cards reach the foundation stacks, startWinAnimation()
// launches a classic Windows-Solitaire-style bouncing card cascade. Cards fly up
// from their foundation positions with randomised velocity and bounce off the
// bottom edge with diminishing energy. A fading trail accumulates beneath each
// card. After ~10 seconds (or on New Deal) all animation views are cleaned up.
//
//  CardStacks
//
//  Created by Gary on 4/22/19.
//  Copyright © 2019 Gary Hanson. All rights reserved.
//

import UIKit


fileprivate let SPACING = CGFloat(UIScreen.main.bounds.width > 750 ? 10.0 : 3.0)
let CARD_WIDTH = CGFloat((UIScreen.main.bounds.width - CGFloat(7.0 * SPACING)) / 7.0)
let CARD_HEIGHT = CARD_WIDTH * 1.42

private extension Selector {
    static let handleTap = #selector(SolitaireGameView.newDealAction)
    static let showStylePicker = #selector(SolitaireGameView.showCardBackPicker)
    static let handleUndo = #selector(SolitaireGameView.undoAction)
}


/**
 * @decision DEC-WIN-001
 * @title CADisplayLink physics loop for win animation
 * @status accepted
 * @rationale CADisplayLink at 60 fps gives smooth, consistent physics without
 *   the drift that accumulates when using repeating Timer callbacks. Each card
 *   carries a WinCardPhysics struct (position + velocity + bounce coefficient)
 *   so state is self-contained and easy to reset. Trail stamps are plain
 *   UIImageViews added directly to self; capping at kMaxTrailStamps prevents
 *   unbounded memory growth during long animations.
 */
final class SolitaireGameView: UIView {

    private var foundationStacks = [FoundationCardStackView]()
    private var tableauStackViews = [TableauStackView]()
    private var stockStackView = StockCardStackView(frame: CGRect.zero)
    private var talonStackView = TalonCardStackView()
    private var doingDrag = false           // flag to keep callbacks from trying to do stuff on touches when not dragging
    private var dragView = DragStackView(frame: CGRect.zero, cards: Model.sharedInstance.dragStack)   // view containing cards being dragged.
    private var stackDraggedFrom: CardStackView?
    private var dragPosition = CGPoint.zero
    private var baseTableauFrameRect = CGRect.init()

    // MARK: Win Animation State
    private var isAnimatingWin = false
    private var winDisplayLink: CADisplayLink?
    private var winAnimationViews = [UIImageView]()     // the bouncing card images
    private var winCardPhysics = [WinCardPhysics]()     // parallel array of physics state
    private var winTrailViews = [UIImageView]()         // accumulated trail stamps
    private var winLaunchTimer: Timer?                  // fires every 0.12s to launch next card
    private var winCardsToLaunch = [(image: UIImage, origin: CGPoint, stackIndex: Int)]()  // queue of cards waiting to launch
    private var winOverlayLabel: UILabel?
    private var winFrameCounter = 0                     // frame counter used to pace trail stamps
    private var winLastTimestamp: CFTimeInterval = 0    // previous display-link timestamp for dt

    //MARK: Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.backgroundColor = UIColor(hex: 0x004D2C)
        
        self.initStackViews()
        
        self.dealCards()
    }
    
    private func initStackViews() {
        let baseRect = CGRect(x: 4.0, y: scaled(value: 110.0), width: CARD_WIDTH, height: CARD_HEIGHT)
        var foundationRect = baseRect
        for index in 0 ..< 4 {
            let stackView = FoundationCardStackView(frame: foundationRect, cards: Model.sharedInstance.foundationStacks[index])
            self.addSubview(stackView)
            self.foundationStacks.append(stackView)
            foundationRect = foundationRect.offsetBy(dx: CGFloat(CARD_WIDTH + SPACING), dy: 0.0)
        }
        
        foundationRect = foundationRect.offsetBy(dx: CGFloat(CARD_WIDTH + SPACING), dy: 0.0)
        self.talonStackView = TalonCardStackView(frame: foundationRect, cards: Model.sharedInstance.talonStack)
        self.addSubview(self.talonStackView)
        
        foundationRect = foundationRect.offsetBy(dx: CGFloat(CARD_WIDTH + SPACING), dy: 0.0)
        self.stockStackView = StockCardStackView(frame: foundationRect, cards: Model.sharedInstance.stockStack)
        self.addSubview(self.stockStackView)

        // Wire move recording callback for stock tap (stock-to-talon and recycle).
        // Using a closure keeps StockCardStackView decoupled from SolitaireGameView.
        // See DEC-UNDO-002 in MASTER_PLAN.md.
        self.stockStackView.onMoveRecorded = { move in
            Game.sharedInstance.recordMove(move)
        }

        var gameStackRect = baseRect.offsetBy(dx: 0.0, dy: CGFloat(CARD_HEIGHT + scaled(value: 12.0)))
        self.baseTableauFrameRect = gameStackRect
        for index in 0 ..< 7 {
            let stackView = TableauStackView(frame: gameStackRect, cards: Model.sharedInstance.tableauStacks[index])
            self.addSubview(stackView)
            self.tableauStackViews.append(stackView)
            gameStackRect = gameStackRect.offsetBy(dx: CGFloat(CARD_WIDTH + SPACING), dy: 0.0)
        }
        
        let buttonFrame = CGRect(x: 1.0, y: scaled(value: 60.0), width: scaled(value: 70.0), height: scaled(value: 30.0))
        let newDealButton = UIButton(frame: buttonFrame)
        newDealButton.setTitle("New Deal", for: .normal)
        newDealButton.setTitleColor(.white, for: .normal)
        newDealButton.titleLabel?.font = .systemFont(ofSize: scaled(value: 14.0))
        newDealButton.addTarget(self, action: .handleTap, for: .touchUpInside)
        self.addSubview(newDealButton)

        // Undo button — right of New Deal, same vertical position.
        let undoButtonFrame = CGRect(
            x: buttonFrame.maxX + 8.0,
            y: scaled(value: 60.0),
            width: scaled(value: 55.0),
            height: scaled(value: 30.0)
        )
        let undoButton = UIButton(frame: undoButtonFrame)
        undoButton.setTitle("Undo", for: .normal)
        undoButton.setTitleColor(.white, for: .normal)
        undoButton.titleLabel?.font = .systemFont(ofSize: scaled(value: 14.0))
        undoButton.addTarget(self, action: .handleUndo, for: .touchUpInside)
        self.addSubview(undoButton)

        // Style button — right-aligned at the same vertical position as New Deal.
        let styleButtonWidth = scaled(value: 60.0)
        let styleButtonFrame = CGRect(
            x: self.bounds.width - styleButtonWidth - 4.0,
            y: scaled(value: 60.0),
            width: styleButtonWidth,
            height: scaled(value: 30.0)
        )
        let styleButton = UIButton(frame: styleButtonFrame)
        styleButton.setTitle("Style", for: .normal)
        styleButton.setTitleColor(.white, for: .normal)
        styleButton.titleLabel?.font = .systemFont(ofSize: scaled(value: 14.0))
        styleButton.autoresizingMask = [.flexibleLeftMargin]
        styleButton.addTarget(self, action: .showStylePicker, for: .touchUpInside)
        self.addSubview(styleButton)

    }

    // MARK: Card Back Style Picker

    /**
     * @decision DEC-CARDBACK-003
     * @title UIAlertController action sheet for style selection
     * @status accepted
     * @rationale An action sheet is the idiomatic iOS pattern for choosing
     *   between a small set of mutually-exclusive options. A checkmark on the
     *   active choice gives instant visual feedback without requiring a
     *   separate settings screen.
     */
    @objc func showCardBackPicker() {
        let alert = UIAlertController(title: "Card Back Style", message: nil, preferredStyle: .actionSheet)
        let current = CardBackManager.shared.style

        let classicAction = UIAlertAction(
            title: current == .classic ? "Classic ✓" : "Classic",
            style: .default
        ) { _ in
            CardBackManager.shared.style = .classic
        }

        let corgiAction = UIAlertAction(
            title: current == .corgi ? "Corgi ✓" : "Corgi",
            style: .default
        ) { _ in
            CardBackManager.shared.style = .corgi
        }

        alert.addAction(classicAction)
        alert.addAction(corgiAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Walk the responder chain to find the presenting view controller.
        if let vc = self.findViewController() {
            // On iPad, action sheets must be anchored to a source view.
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self
                popover.sourceRect = CGRect(
                    x: self.bounds.width - scaled(value: 64.0),
                    y: scaled(value: 60.0),
                    width: scaled(value: 60.0),
                    height: scaled(value: 30.0)
                )
            }
            vc.present(alert, animated: true)
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: Deal
    @objc func newDealAction() {
        cleanupWinAnimation()
        self.dealCards()
    }
    
    private func dealCards() {
        CardBackManager.shared.randomizeCorgi()
        Game.sharedInstance.initalizeDeal()
        
        var tableauFrame = self.baseTableauFrameRect
        var cardValuesIndex = 0
        for outerIndex in 0 ..< 7 {
            self.tableauStackViews[outerIndex].frame = tableauFrame
            for innerIndex in (0 ... outerIndex) {
                Model.sharedInstance.tableauStacks[outerIndex].addCard(card: Card(value: Model.sharedInstance.deck[cardValuesIndex], faceUp: outerIndex == innerIndex))
                cardValuesIndex += 1
            }
            tableauFrame = tableauFrame.offsetBy(dx: CGFloat(CARD_WIDTH + SPACING), dy: 0.0)
        }
        
        for _ in cardValuesIndex ..< 52 {
            Model.sharedInstance.stockStack.addCard(card: Card(value: Model.sharedInstance.deck[cardValuesIndex], faceUp: false))
            cardValuesIndex += 1
        }
    }

    // Defense-in-depth: ensure all non-empty tableau stacks have their top card
    // face-up. Called after drag cleanup and at end of touchesEnded to recover
    // from any state where a face-down card ended up on top.
    private func ensureTableauTopCardsFaceUp() {
        for stackView in tableauStackViews {
            stackView.flipTopCard()
        }
    }

}

// MARK: Handle dragging
extension SolitaireGameView {
    
    override func touchesBegan(_ touches: Set<UITouch>,
                               with event: UIEvent?) {
        let touch = touches.first!
        let tapCount = touch.tapCount
        if tapCount > 1 {
            handleDoubleTap(inView: touch.view!)
            return
        }

        // Guard: if a drag is already in progress (multitouch or rapid tap),
        // restore the in-flight cards to their source stack before starting fresh.
        // Mirrors the touchesCancelled restore path.
        if doingDrag {
            if let src = stackDraggedFrom {
                dragView.cards.cards.forEach { card in src.cards.addCard(card: card) }
                src.refresh()
            }
            dragView.removeFromSuperview()
            dragView.removeAllCardViews()
            dragView.bounds = CGRect.zero
            doingDrag = false
            ensureTableauTopCardsFaceUp()
        }

        if let touchedView = touch.view {
            Model.sharedInstance.dragStack.removeAllCards()
            dragView.removeAllCardViews()
            let touchPoint = touch.location(in: self)
            // we want the first view (in reverse order) that is visible and contains the touch point
            // create a drag view with this view, and other cards above it in the hierarchy, if any
            // the cards are removed from the stack during the drag, and then copied to either a new
            // stack or back to the originating stack.
            for cardView in touchedView.subviews.reversed() {
                if let cardView = cardView as? CardView {
                    let t = touch.location(in: cardView)
                    if cardView.isFaceUp && cardView.point(inside: t, with: event) {
                        stackDraggedFrom = touchedView as? CardStackView
                        let dragCard = Card(value: cardView.cardValue, faceUp: true)
                        if let index = stackDraggedFrom?.cards.cards.firstIndex(where: { $0.value == dragCard.value }) {
                            // card that was touched
                            doingDrag = true
                            dragView.frame = cardView.convert(cardView.bounds, to: self)
                            self.addSubview(dragView)
                            Model.sharedInstance.dragStack.addCard(card: dragCard)

                            // add any cards above it
                            let endIndex = stackDraggedFrom!.cards.cards.endIndex - 1
                            if index < endIndex {
                                for i in index + 1 ... endIndex {
                                    let card = stackDraggedFrom!.cards.cards[i]
                                    Model.sharedInstance.dragStack.addCard(card: card)
                                }
                            }

                            // the cards are now in the drag view so remove them from the stack
                            for card in Model.sharedInstance.dragStack.cards {
                                if let cardIndex = stackDraggedFrom!.cards.cards.firstIndex(where: { $0.value == card.value }) {
                                    stackDraggedFrom!.cards.cards.remove(at: cardIndex)
                                }
                            }

                            stackDraggedFrom?.refresh()
                            dragView.refresh()
                            dragPosition = touchPoint
                            break
                        }
                    }
                }
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>,
                               with event: UIEvent?) {
        guard doingDrag else {
            return
        }
        
        if let touch = touches.first {
            let currentPosition = touch.location(in: self)
            
            let oldLocation = dragPosition
            dragPosition = currentPosition
            
            moveDragView(offset: CGPoint(x: (currentPosition.x) - (oldLocation.x), y: (currentPosition.y) - (oldLocation.y)))
        }
    }
    
    private func moveDragView(offset: CGPoint) {
        dragView.center = CGPoint(x: dragView.center.x + offset.x, y: dragView.center.y + offset.y)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>,
                                   with event: UIEvent?) {
        guard doingDrag else {
            return
        }
        
        dragView.cards.cards.forEach{ card in stackDraggedFrom!.cards.addCard(card: card) }
        dragView.removeFromSuperview()
        dragView.removeAllCardViews()
        
        dragView.bounds = CGRect.zero
        doingDrag = false
    }
    
    override func touchesEnded(_ touches: Set<UITouch>,
                               with event: UIEvent?) {
        if doingDrag {
            var done = false
            let dragFrame = dragView.convert(dragView.bounds, to: self)

            for view in tableauStackViews where view != stackDraggedFrom! {
                let viewFrame = view.convert(view.bounds, to: self)
                if viewFrame.intersects(dragFrame) {
                    // if a drop here is valid, move card and break out of loop
                    if view.cards.canAccept(droppedCard: dragView.cards.cards.first!) {
                        let movedCards = Model.sharedInstance.dragStack.cards
                        // Detect if source top (the new top after removal) was face-down —
                        // that means flipTopCard() will flip it, so didFlipSourceTopCard = true.
                        var didFlip = false
                        if let src = stackDraggedFrom as? TableauStackView,
                           let newTop = src.cards.topCard() {
                            didFlip = !newTop.faceUp
                        }
                        for card in movedCards {
                            view.cards.addCard(card: card)
                        }
                        if let stack = stackDraggedFrom as? TableauStackView {
                            stack.flipTopCard()
                            stack.refresh()
                        }
                        view.refresh()

                        if let src = stackDraggedFrom {
                            Game.sharedInstance.recordMove(Move(
                                type: .dragDrop,
                                cards: movedCards,
                                source: stackIdentifier(for: src),
                                destination: stackIdentifier(for: view),
                                didFlipSourceTopCard: didFlip
                            ))
                        }
                        done = true
                        break
                    }
                }
            }

            if (!done && dragView.cards.cards.count == 1) {      // can only drag one card at a time to Foundation stack
                for view in foundationStacks where view != stackDraggedFrom! {
                    let viewFrame = view.convert(view.bounds, to: self)
                    if viewFrame.intersects(dragFrame) {
                        // if a drop here is valid, move card and break out of loop
                        if view.cards.canAccept(droppedCard: dragView.cards.cards.first!) {
                            let card = Model.sharedInstance.dragStack.cards.first!
                            var didFlip = false
                            if let src = stackDraggedFrom as? TableauStackView,
                               let newTop = src.cards.topCard() {
                                didFlip = !newTop.faceUp
                            }
                            view.cards.addCard(card: card)
                            if let stack = stackDraggedFrom as? TableauStackView {
                                stack.flipTopCard()
                                stack.refresh()
                            }
                            if let src = stackDraggedFrom {
                                Game.sharedInstance.recordMove(Move(
                                    type: .dragDrop,
                                    cards: [card],
                                    source: stackIdentifier(for: src),
                                    destination: stackIdentifier(for: view),
                                    didFlipSourceTopCard: didFlip
                                ))
                            }
                        }
                        done = true
                        view.refresh()
                        checkForWin()
                        break
                    }
                }
            }

            if !done {
                // card(s) couldn't be dropped, so put them back
                dragView.cards.cards.forEach{ card in stackDraggedFrom!.cards.addCard(card: card) }
            }

            dragView.removeFromSuperview()
            dragView.removeAllCardViews()

            dragView.bounds = CGRect.zero
            doingDrag = false

            ensureTableauTopCardsFaceUp()
        }
    }
}

// MARK: Double Tap
extension SolitaireGameView {
    
    // if a card in the talon stack or one of the tableau stacks is double-tapped,
    // see if it can be added to a foundation stack
    // if you copy / paste these two functions and replace Foundation with Tableau
    // you can try moving them to a tableau stack if it doesn't go into a foundation stack
    // or, you can just let the user do something for themself :-)
    func handleDoubleTap(inView: UIView) {
        if let talonStack = inView as? TalonCardStackView {
            if let card = talonStack.cards.topCard() {
                if let foundationIndex = self.addCardToFoundation(card: card) {
                    talonStack.cards.popCards(numberToPop: 1, makeNewTopCardFaceup: true)
                    Game.sharedInstance.recordMove(Move(
                        type: .doubleTap,
                        cards: [card],
                        source: .talon,
                        destination: .foundation(foundationIndex),
                        didFlipSourceTopCard: false
                    ))
                }
            }
        } else if let tableauStack = inView as? TableauStackView {
            if let card = tableauStack.cards.topCard() {
                if let foundationIndex = self.addCardToFoundation(card: card) {
                    // Detect if the card below (new top after pop) was face-down before
                    // popCards flips it with makeNewTopCardFaceup:true.
                    let newTopWasFaceDown: Bool
                    if tableauStack.cards.cards.count >= 2 {
                        let cardBelowTop = tableauStack.cards.cards[tableauStack.cards.cards.count - 2]
                        newTopWasFaceDown = !cardBelowTop.faceUp
                    } else {
                        newTopWasFaceDown = false
                    }
                    tableauStack.cards.popCards(numberToPop: 1, makeNewTopCardFaceup: true)
                    Game.sharedInstance.recordMove(Move(
                        type: .doubleTap,
                        cards: [card],
                        source: stackIdentifier(for: tableauStack),
                        destination: .foundation(foundationIndex),
                        didFlipSourceTopCard: newTopWasFaceDown
                    ))
                }
            }
        }
    }

    /// Tries to place `card` on one of the four foundation stacks.
    /// Returns the foundation index on success, nil on failure.
    private func addCardToFoundation(card: Card) -> Int? {
        var foundIndex: Int? = nil

        for (index, stack) in self.foundationStacks.enumerated() {
            if stack.cards.canAccept(droppedCard: card) {
                stack.cards.addCard(card: card)
                foundIndex = index
                break
            }
        }

        if foundIndex != nil {
            checkForWin()
        }

        return foundIndex
    }
}

// MARK: Undo
extension SolitaireGameView {

    /// Reverses the most recent recorded move, restoring data stacks and refreshing views.
    @objc func undoAction() {
        guard !isAnimatingWin, Game.sharedInstance.canUndo else { return }
        let history = Game.sharedInstance.moveHistory
        let move = history.last!
        // Rebuild history without the popped move.
        Game.sharedInstance.clearMoveHistory()
        for m in history.dropLast() { Game.sharedInstance.recordMove(m) }

        switch move.type {
        case .dragDrop, .doubleTap:
            let destDataStack = dataStack(for: move.destination)
            let destViewStack = stackView(for: move.destination)
            let srcDataStack  = dataStack(for: move.source)
            let srcViewStack  = stackView(for: move.source)

            // Remove the moved cards from destination.
            destDataStack.cards.removeLast(move.cards.count)

            // Un-flip source top card if it was flipped as a side-effect.
            if move.didFlipSourceTopCard, let topCard = srcDataStack.topCard() {
                srcDataStack.cards.removeLast()
                srcDataStack.cards.append(Card(value: topCard.value, faceUp: false))
            }

            // Restore cards to source in original order.
            for card in move.cards {
                srcDataStack.cards.append(card)
            }

            srcViewStack.refresh()
            destViewStack.refresh()

        case .stockToTalon:
            let talonData = Model.sharedInstance.talonStack
            let stockData = Model.sharedInstance.stockStack
            // Pop from talon, push back to stock face-down.
            if let card = talonData.topCard() {
                talonData.cards.removeLast()
                stockData.cards.append(Card(value: card.value, faceUp: false))
            }
            talonStackView.refresh()
            stockStackView.refresh()

        case .recycleToStock:
            // Restore: clear stock, put saved talon cards back in talon face-up.
            Model.sharedInstance.stockStack.removeAllCards()
            for card in move.cards {
                Model.sharedInstance.talonStack.addCard(card: Card(value: card.value, faceUp: true))
            }
            talonStackView.refresh()
            stockStackView.refresh()
        }
    }
}

// MARK: Stack Identifier Helpers
extension SolitaireGameView {

    /// Maps a CardStackView instance to its StackIdentifier enum value.
    fileprivate func stackIdentifier(for stackView: CardStackView) -> StackIdentifier {
        if let index = tableauStackViews.firstIndex(where: { $0 === stackView }) {
            return .tableau(index)
        }
        if let index = foundationStacks.firstIndex(where: { $0 === stackView }) {
            return .foundation(index)
        }
        if stackView === talonStackView {
            return .talon
        }
        return .stock
    }

    /// Returns the data stack for a given StackIdentifier.
    fileprivate func dataStack(for identifier: StackIdentifier) -> CardDataStack {
        switch identifier {
        case .tableau(let i):    return Model.sharedInstance.tableauStacks[i]
        case .foundation(let i): return Model.sharedInstance.foundationStacks[i]
        case .talon:             return Model.sharedInstance.talonStack
        case .stock:             return Model.sharedInstance.stockStack
        }
    }

    /// Returns the view stack for a given StackIdentifier.
    fileprivate func stackView(for identifier: StackIdentifier) -> CardStackView {
        switch identifier {
        case .tableau(let i):    return tableauStackViews[i]
        case .foundation(let i): return foundationStacks[i]
        case .talon:             return talonStackView
        case .stock:             return stockStackView
        }
    }
}

// MARK: - Win Animation

/// Physics state for a single bouncing card during the win animation.
private struct WinCardPhysics {
    var position: CGPoint       // current top-left position of the card image
    var velocityX: CGFloat      // horizontal pts/sec
    var velocityY: CGFloat      // vertical pts/sec (negative = upward)
    var bounceCoefficient: CGFloat  // energy retained on floor bounce (0.70–0.85)
    var trailFrameCounter: Int  // incremented each frame; trail stamp every kTrailInterval frames
}

private let kGravity: CGFloat       = 800.0   // pts / sec^2, downward
private let kTrailInterval          = 4        // stamp a trail every N frames
private let kMaxTrailStamps         = 500      // cap total trail views to avoid memory pressure
private let kLaunchInterval: TimeInterval = 0.12   // seconds between successive card launches
private let kAnimationAutoEndDelay: TimeInterval = 11.0  // stop link after this many seconds

extension SolitaireGameView {

    // MARK: Win Detection

    private func checkForWin() {
        guard !isAnimatingWin else { return }
        let total = foundationStacks.reduce(0) { $0 + $1.cards.cards.count }
        if total == 52 {
            showFakeErrorThenWin()
        }
    }

    // MARK: Fake Error Prank

    private func showFakeErrorThenWin() {
        isAnimatingWin = true  // prevent re-triggering

        guard let vc = self.findViewController() else {
            startWinAnimation()
            return
        }

        let alert = UIAlertController(
            title: "\u{26A0}\u{FE0F} Error!",
            message: "You can't do that!",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            // Swap to the smiley face version
            let jk = UIAlertController(
                title: "\u{1F600}",
                message: "Just kidding!",
                preferredStyle: .alert
            )
            jk.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                self?.startWinAnimation()
            })
            vc.present(jk, animated: true)
        })
        vc.present(alert, animated: true)
    }

    // MARK: Animation Entry Point

    private func startWinAnimation() {
        // isAnimatingWin is already set by showFakeErrorThenWin; don't guard here.
        isAnimatingWin = true

        // Build the ordered launch queue: cycle through the 4 foundation stacks,
        // top card first (King → Ace), so the Kings launch first.
        // Each entry records the stack index so launchNextWinCard can pop the
        // top card from that stack, making the foundations visually count down.
        winCardsToLaunch.removeAll()
        for rankOffset in stride(from: 12, through: 0, by: -1) {
            for stackIndex in 0 ..< 4 {
                let stack = foundationStacks[stackIndex]
                guard rankOffset < stack.cards.cards.count else { continue }
                let card = stack.cards.cards[rankOffset]
                let cardSize = CGSize(width: CARD_WIDTH, height: CARD_HEIGHT)
                let cardImage = renderCardFace(cardValue: card.value, size: cardSize)
                let stackOrigin = stack.convert(CGPoint(x: 0, y: 0), to: self)
                winCardsToLaunch.append((image: cardImage, origin: stackOrigin, stackIndex: stackIndex))
            }
        }

        // Fire the launch timer — one card per tick.
        winLaunchTimer = Timer.scheduledTimer(
            timeInterval: kLaunchInterval,
            target: self,
            selector: #selector(launchNextWinCard),
            userInfo: nil,
            repeats: true
        )

        // Start the physics display link immediately so launched cards animate
        // from the very first frame.
        winLastTimestamp = 0
        winFrameCounter = 0
        let link = CADisplayLink(target: self, selector: #selector(winAnimationStep))
        link.add(to: .main, forMode: .common)
        winDisplayLink = link

        // Auto-cleanup after a fixed duration regardless of card state.
        Timer.scheduledTimer(
            timeInterval: kAnimationAutoEndDelay,
            target: self,
            selector: #selector(winAnimationAutoEnd),
            userInfo: nil,
            repeats: false
        )
    }

    // MARK: Per-Card Launch

    @objc private func launchNextWinCard() {
        guard !winCardsToLaunch.isEmpty else {
            winLaunchTimer?.invalidate()
            winLaunchTimer = nil
            // Show "You Win!" label ~1s after last card launches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showWinLabel()
            }
            return
        }

        let entry = winCardsToLaunch.removeFirst()

        // Pop the top card from this foundation stack so it visually counts down.
        let stack = foundationStacks[entry.stackIndex]
        if !stack.cards.cards.isEmpty {
            stack.cards.popCards(numberToPop: 1, makeNewTopCardFaceup: true)
            stack.refresh()
        }

        let imageView = UIImageView(image: entry.image)
        imageView.frame = CGRect(origin: entry.origin, size: CGSize(width: CARD_WIDTH, height: CARD_HEIGHT))
        imageView.layer.cornerRadius = 7.0
        imageView.clipsToBounds = true
        self.addSubview(imageView)
        winAnimationViews.append(imageView)

        // Random physics: upward burst + sideways drift.
        let vx = CGFloat.random(in: -320 ... 320)
        let vy = CGFloat.random(in: -580 ... -380)   // negative = upward
        let bounce = CGFloat.random(in: 0.70 ... 0.85)
        winCardPhysics.append(WinCardPhysics(
            position: entry.origin,
            velocityX: vx,
            velocityY: vy,
            bounceCoefficient: bounce,
            trailFrameCounter: 0
        ))
    }

    // MARK: Physics Step (CADisplayLink callback)

    @objc private func winAnimationStep(link: CADisplayLink) {
        // Compute dt; clamp to 1/30s to prevent huge jumps after backgrounding.
        let now = link.timestamp
        var dt: CGFloat
        if winLastTimestamp == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = CGFloat(min(now - winLastTimestamp, 1.0 / 30.0))
        }
        winLastTimestamp = now
        winFrameCounter += 1

        let screenBounds = self.bounds
        let floorY = screenBounds.maxY - CARD_HEIGHT   // bottom edge where cards bounce

        var indicesToRemove = [Int]()

        for i in 0 ..< winAnimationViews.count {
            var phys = winCardPhysics[i]
            let view = winAnimationViews[i]

            // Integrate velocity.
            phys.velocityY += kGravity * dt
            phys.position.x += phys.velocityX * dt
            phys.position.y += phys.velocityY * dt

            // Bounce off the floor.
            if phys.position.y >= floorY {
                phys.position.y = floorY
                phys.velocityY = -abs(phys.velocityY) * phys.bounceCoefficient
                // Small horizontal friction on bounce.
                phys.velocityX *= 0.92
                // Kill tiny bounces so cards don't jitter forever.
                if abs(phys.velocityY) < 40 {
                    phys.velocityY = 0
                }
            }

            // Update the view frame without Core Animation interpolation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.frame = CGRect(origin: phys.position, size: view.bounds.size)
            CATransaction.commit()

            // Stamp a trail every kTrailInterval frames if under the cap.
            phys.trailFrameCounter += 1
            if phys.trailFrameCounter >= kTrailInterval && winTrailViews.count < kMaxTrailStamps {
                phys.trailFrameCounter = 0
                let trail = UIImageView(image: view.image)
                trail.frame = view.frame
                trail.alpha = 0.45
                trail.layer.cornerRadius = 7.0
                trail.clipsToBounds = true
                // Insert just below the bouncing card so trails cover the game board.
                if let viewIndex = self.subviews.firstIndex(of: view) {
                    self.insertSubview(trail, at: viewIndex)
                } else {
                    self.addSubview(trail)
                }
                winTrailViews.append(trail)
            } else if phys.trailFrameCounter >= kTrailInterval {
                phys.trailFrameCounter = 0
            }

            // Remove cards that have drifted off the horizontal edges.
            if phys.position.x > screenBounds.maxX + 20
                || phys.position.x < screenBounds.minX - CARD_WIDTH - 20 {
                indicesToRemove.append(i)
            }

            winCardPhysics[i] = phys
        }

        // Remove out-of-bounds cards in reverse order to keep indices valid.
        for i in indicesToRemove.reversed() {
            winAnimationViews[i].removeFromSuperview()
            winAnimationViews.remove(at: i)
            winCardPhysics.remove(at: i)
        }
    }

    // MARK: "You Win!" Overlay

    private func showWinLabel() {
        guard winOverlayLabel == nil else { return }

        let label = UILabel(frame: CGRect.zero)
        label.text = "You Win!"
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.font = UIFont(name: "Palatino-Bold", size: scaled(value: 48.0))
            ?? UIFont.boldSystemFont(ofSize: scaled(value: 48.0))

        // Drop shadow for legibility over the card heap.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 2, height: 2)
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 4.0

        label.sizeToFit()
        label.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        self.addSubview(label)
        winOverlayLabel = label

        // Pulse the label in and out.
        label.alpha = 0
        UIView.animate(
            withDuration: 0.6,
            delay: 0,
            options: [.curveEaseIn],
            animations: { label.alpha = 1.0 }
        )
    }

    // MARK: Cleanup

    @objc private func winAnimationAutoEnd() {
        // Only remove the display link and launch timer; leave trail views and
        // the "You Win!" label so the user can see the result.
        winDisplayLink?.invalidate()
        winDisplayLink = nil
        winLaunchTimer?.invalidate()
        winLaunchTimer = nil
        winAnimationViews.forEach { $0.removeFromSuperview() }
        winAnimationViews.removeAll()
        winCardPhysics.removeAll()
        // Leave winTrailViews and winOverlayLabel until New Deal.
    }

    func cleanupWinAnimation() {
        winDisplayLink?.invalidate()
        winDisplayLink = nil
        winLaunchTimer?.invalidate()
        winLaunchTimer = nil
        winAnimationViews.forEach { $0.removeFromSuperview() }
        winAnimationViews.removeAll()
        winCardPhysics.removeAll()
        winTrailViews.forEach { $0.removeFromSuperview() }
        winTrailViews.removeAll()
        winOverlayLabel?.removeFromSuperview()
        winOverlayLabel = nil
        winCardsToLaunch.removeAll()
        isAnimatingWin = false
        winLastTimestamp = 0
        winFrameCounter = 0
    }

    // MARK: Card Face Rendering Helper

    /// Renders a card's face into a UIImage of the given size.
    /// Creates a temporary CardView off-screen, forces layout, then snapshots it.
    private func renderCardFace(cardValue: Int, size: CGSize) -> UIImage {
        let frame = CGRect(origin: .zero, size: size)
        let cardView = CardView(frame: frame, value: cardValue, faceUp: true)
        // Force the background image hidden so we always show the face.
        cardView.faceUp = true

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            cardView.drawHierarchy(in: frame, afterScreenUpdates: true)
        }
    }
}
