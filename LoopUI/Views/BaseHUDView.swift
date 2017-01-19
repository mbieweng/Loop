//
//  HUDView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/1/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

public class BaseHUDView: UIView {

    @IBOutlet weak var caption: UILabel! {
        didSet {
            caption?.text = "—"
        }
    }
    
    public func timeAgoString(date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short
        
        let ago = abs(min(0, date.timeIntervalSinceNow))
        if let timeString = formatter.string(from: ago) {
            return String(format: NSLocalizedString("%@ ago", comment: "Format string describing the time interval since now. (1: The localized date components"), timeString)
        } else {
            return String("—")
        }
    }
    

}
