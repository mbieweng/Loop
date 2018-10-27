//
//  TextFieldTableViewController.swift
//  Loop
//
//  Created by Nate Racklyeft on 7/31/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import LoopKitUI
import HealthKit


/// Convenience static constructors used to contain common configuration
extension TextFieldTableViewController {
    typealias T = TextFieldTableViewController
    
    private static let valueNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()

        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2

        return formatter
    }()

    static func autoSensFactor(_ value: Double?) -> T {
        let vc = T()
        
        vc.placeholder = NSLocalizedString("Enter an insulin sensitivity adjustment factor (1.0 = nomal)", comment: "The placeholder text instructing users how to enter a maximum bolus")
        vc.keyboardType = .decimalPad
        vc.unit = NSLocalizedString("times normal", comment: "The unit string for units")
        
        if let asf = value {
            vc.value = valueNumberFormatter.string(from: NSNumber(value:asf))
        }
        
        return vc
    }
    

}
