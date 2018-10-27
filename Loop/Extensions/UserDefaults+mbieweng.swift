//
//  UserDefaults+mbieweng.swift
//  Loop
//
//  Created by Mike on 10/27/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit



extension UserDefaults {
    private enum Key: String {
        // MB Extensions
        case autoSensFactor = "com.loopkit.Loop.autoSensFactor"
        //
    }
    
   
    // MB Extensions
    var autoSensFactor : Double {
        get {
            let value : Double = double(forKey:Key.autoSensFactor.rawValue)
            if(value != 0)  {
                return value
            } else {
                return 1.0
            }
        }
        set {
            set(newValue.rawValue, forKey: Key.autoSensFactor.rawValue)
        }
    }
}
