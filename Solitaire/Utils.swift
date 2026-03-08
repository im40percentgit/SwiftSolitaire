// Utils.swift — Shared utility extensions and helpers used across the Solitaire
// app. Includes UIColor hex initialiser, a scale helper for adaptive layouts,
// file path utilities, and a UIView responder-chain walker used to present
// UIAlertControllers from within UIView subclasses.
//
//  LCFotos
//
//  Created by main on 4/11/16.
//  Copyright © 2016 Gary Hanson. All rights reserved.
//

import UIKit

let scaleFactor = UIScreen.main.bounds.height / 667.0



extension String {
    
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
    
    var lastPathComponent: String {
        return (self as NSString).lastPathComponent
    }
    
    var stringByDeletingLastPathComponent: String {
        return (self as NSString).deletingLastPathComponent
    }
}

extension UIColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((hex & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(hex & 0x0000FF) / 255.0,
            alpha: alpha )
    }
}

func scaled(value: CGFloat) -> CGFloat {
    return  value * scaleFactor
}

struct FileUtilities {
    
    static func documentsDirectory() -> String {
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }
}

// Example
//private extension Selector {
//    static let handlePan = #selector(GameController.handlePan(_:))
//
//}

extension UIView {
    /// Walks the responder chain upward to find the nearest UIViewController
    /// that contains this view. Used to present UIAlertControllers from within
    /// UIView subclasses that have no direct view-controller reference.
    func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController {
                return vc
            }
            responder = r.next
        }
        return nil
    }
}

