//
//  GarminConnectManager.swift
//  Loop
//
//  Created by Mike on 8/2/17.
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import ConnectIQ
import LoopKit
import HealthKit

let kDevicesFileName = "garmindevices"

final class GarminConnectManager : NSObject, IQDeviceEventDelegate, IQAppMessageDelegate {
    
    static let shared = GarminConnectManager()

    static let ReturnURLScheme = Bundle.main.bundleIdentifier
    let deviceManager = DeviceDataManager()
    
    var devices : Array = [IQDevice]()

    var garminLoopApp : IQApp = IQApp()
    
    override init() {
        NSLog("Garmin init with return url \(String(describing: GarminConnectManager.ReturnURLScheme))")
        ConnectIQ.sharedInstance().initialize(withUrlScheme: GarminConnectManager.ReturnURLScheme, uiOverrideDelegate: nil)
    }
        
    func setup() {
        //self.restoreDevicesFromFileSystem();
        NSLog("Garmin setup")
        if(self.devices.count == 0) {
            ConnectIQ.sharedInstance().showDeviceSelection()
        }
        
    }
    
    func processDeviceUrl(url: URL) {
        
        NSLog("Garmin Processdevice URL")
        let dlist = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url)
        if (dlist != nil) {
            self.devices = dlist as! [IQDevice];
            NSLog("Garmin device list: \(String(describing: self.devices))")
            
            ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
            for device in self.devices {
                ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self )
                self.garminLoopApp = IQApp(uuid: UUID(uuidString: "0180e520-5f7e-11e4-9803-0800200c9a67"), store: UUID(), device: device)
                ConnectIQ.sharedInstance().getAppStatus(self.garminLoopApp, completion: { (appStatus: IQAppStatus?) in
                    NSLog("Garmin App status \(String(describing: appStatus)) \(String(describing: appStatus?.isInstalled))")
                    
                })
                ConnectIQ.sharedInstance().register(forAppMessages: self.garminLoopApp, delegate: self)
                
            }
        }

    }
    
    public func receivedMessage(_ message: Any!, from app: IQApp!) {
        NSLog("Garmin received message \(String(describing: message))")
        //if((message: String == "ready")
        
        self.deviceManager.loopManager.getLoopState { (manager, state) in
            
            self.deviceManager.loopManager.glucoseStore.preferredUnit { (unit, error) in
                if let unit = unit {
                    
                    let delta : Double = 0
                    
                    /*
                    let retrospectivePredictedGlucose = state.retrospectivePredictedGlucose
                    let retroGlucose = retrospectivePredictedGlucose?.last
                    let currentGlucose = self.deviceManager.loopManager.glucoseStore.latestGlucose
                    
                    if let retroVal = retroGlucose?.quantity.doubleValue(for: unit) {
                        if let currentVal = currentGlucose?.quantity.doubleValue(for: unit) {
                            delta = currentVal-retroVal;
                        }
                    }
                    */
                    
                    self.deviceManager.loopManager.glucoseStore.getCachedGlucoseValues(start: Date(timeIntervalSinceNow:TimeInterval(minutes: -30)),
                                                                                       completion: {(samples) in
                                                                                        self.sendSamples(samples: samples, unit: unit, delta: delta)
                    }
                        
                    )
                    
                }
                
            }
        }
    }




    func sendSamples(samples: [GlucoseValue], unit: HKUnit, delta: Double) {
        NSLog("Garmin send sample count \(samples.count)")
       
        for val in samples {
            NSLog("Garmin sending sample \(String(describing: val.endDate))  \(val.quantity.doubleValue(for: unit)) ")
            sendCurrentGlucose(value: val.quantity.doubleValue(for: unit), date: val.endDate, predictionDelta: delta)
        }
        
        

        
    }

    
    func sendCurrentGlucose(value: Double, date: Date, predictionDelta: Double) {

        if(devices.count == 0 ) { return }
        
        var data : Dictionary = [String: Double]();
        data["glucose"] = value;
        data["glucosetime"] = date.timeIntervalSince1970
        data["predictiondelta"] = predictionDelta
        NSLog("Garmin Sending message: \(data)")
        ConnectIQ.sharedInstance().sendMessage(data, to: self.garminLoopApp, progress: {(sentBytes: UInt32, totalBytes: UInt32) -> Void in
            let percent: Double = 100.0 * Double(sentBytes / totalBytes)
            print("Garmin Progress: \(percent)% sent \(sentBytes) bytes of \(totalBytes)")
        }, completion: {(result: IQSendMessageResult) -> Void in
            NSLog("Garmin Send message finished with result: \(NSStringFromSendMessageResult(result))")
        })

        
    }
    
    func saveDevicesToFileSystem() {
        print("Saving known devices.")
        if !NSKeyedArchiver.archiveRootObject(devices, toFile: self.devicesFilePath()) {
            print("Failed to save devices file.")
        }
    }

    func restoreDevicesFromFileSystem() {
        guard let restoredDevices = NSKeyedUnarchiver.unarchiveObject(withFile: self.devicesFilePath()) as? [IQDevice] else {
            print("No device restoration file found.")
            return
        }
        
        if restoredDevices.count > 0 {
            print("Restored saved devices:")
            for device in restoredDevices {
                print("\(device)")
            }
            self.devices = restoredDevices
        }
        else {
            print("No saved devices to restore.")
            self.devices.removeAll()
        }
        //self.delegate!.devicesChanged()
    }

    
    
    // Fenix 37B64C865-3D53-4169-8C09-993605464717
    
    func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
      //  if status != .connected {
      //      ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
      //  }
    }
    
    func devicesFilePath() -> String {
        var paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        let appSupportDirectory = URL(fileURLWithPath: paths[0])
        let dirExists = (try? appSupportDirectory.checkResourceIsReachable()) ?? false
        if !dirExists {
            print("DeviceManager.devicesFilePath appSupportDirectory \(appSupportDirectory) does not exist, creating... ")
            do {
                try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            catch let error {
                print("There was an error creating the directory \(appSupportDirectory) with error: \(error)")
            }
        }
        return appSupportDirectory.appendingPathComponent(kDevicesFileName).absoluteString
    }


}

  
