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
        NSLog("Garmin setup")
        self.restoreDevicesFromFileSystem()
        registerDevices()
        if(self.devices.count == 0) {
            ConnectIQ.sharedInstance().showDeviceSelection()
        }
        
    }
    
    func processDeviceUrl(url: URL, options: [UIApplicationOpenURLOptionsKey : Any] = [:]) -> Bool {
        
        NSLog("Garmin processDeviceURL")
        
        let sourceApplicationBundleID = options[.sourceApplication] as? String
        if (url.scheme != GarminConnectManager.ReturnURLScheme  ||  sourceApplicationBundleID != IQGCMBundle) { return false }
            
        let dlist = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url)
        if (dlist != nil) {
            self.devices = dlist as! [IQDevice];
            self.registerDevices()
            self.saveDevicesToFileSystem()
        }
        return true
    }
    
    private func registerDevices() {
        NSLog("Garmin register devices.  Device list: \(String(describing: self.devices))")
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        for device in self.devices {
            ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self )
            self.garminLoopApp = IQApp(uuid: UUID(uuidString: "0180e520-5f7e-11e4-9803-0800200c9a67"), store: UUID(), device: device)
            ConnectIQ.sharedInstance().getAppStatus(self.garminLoopApp, completion: { (appStatus: IQAppStatus?) in
                NSLog("Garmin App status \(String(describing: appStatus?.version)) \(String(describing: appStatus?.isInstalled))")
                
            })
            ConnectIQ.sharedInstance().register(forAppMessages: self.garminLoopApp, delegate: self)
            
        }
    }
    
    
    public func receivedMessage(_ message: Any!, from app: IQApp!) {
        NSLog("Garmin received message \(String(describing: message))")
        
        sendContext()

                
    }


    private func sendContext() {
        NSLog("Garmin send context")
        if(devices.count == 0 ) { return }
        let defaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)
        
        self.deviceManager.loopManager.getLoopState { (manager, state) in
            //let maximumBolus = manager.settings.maximumBolus
            let activeCarbohydrates = state.carbsOnBoard?.quantity.doubleValue(for: .gram())
            //let bolusRecommendation: BolusRecommendation?
            
            manager.doseStore.insulinOnBoard(at: Date()) { (result) in
                let activeInsulin: Double?
                switch result {
                    case .success(let value):
                        activeInsulin = value.value
                    case .failure:
                        activeInsulin = nil
                }
             
                if let context = defaults?.statusExtensionContext {
                    var data : Dictionary = [String: Any]();
                    
                    data["iob"] = activeInsulin
                    data["cob"] = activeCarbohydrates

                    if let glucose = context.glucose {
                        data["lastGlucose"] = glucose.last?.value
                        data["lastGlucoseTime"] = glucose.last?.startDate.timeIntervalSince1970
                        data["glucose"] =  Array((glucose.map {$0.value}).suffix(6))
                        data["predictionDelta"] = 0;
                        /*
                        if let retroVal = state.retrospectivePredictedGlucose?.last,
                            let currentVal = self.deviceManager.loopManager.glucoseStore.latestGlucose {
                            data["predictiondelta"] = currentVal.quantity.doubleValue(for: HKUnit.milligramsPerDeciliter())-retroVal.quantity.doubleValue(for: HKUnit.milligramsPerDeciliter())
                        }
                        */
                        
                    }
                    
                    if let predictedGlucose = context.predictedGlucose {
                        data["glucoseForecast"] = Array(predictedGlucose.values.prefix(12))
                        data["eventualGlucose"] = predictedGlucose.values.last;
                    }
                    
                    if let loop = context.loop {
                        data["lastLoopTime"] = loop.lastCompleted?.timeIntervalSince1970
                    }
                    
                    if let netbasal = context.netBasal {
                        data["netBasal"] = netbasal.rate
                        
                    }
                    
                    NSLog("Garmin sending context: \(data)")
                    ConnectIQ.sharedInstance().sendMessage(data, to: self.garminLoopApp, progress: {(sentBytes: UInt32, totalBytes: UInt32) -> Void in
                        let percent: Double = 100.0 * Double(sentBytes / totalBytes)
                        print("Garmin progress: \(percent)% sent \(sentBytes) bytes of \(totalBytes)")
                    }, completion: {(result: IQSendMessageResult) -> Void in
                        NSLog("Garmin send message finished with result: \(NSStringFromSendMessageResult(result))")
                    })
                    
                }
                
                
                
            }
            
            
            
        }
        
        
    }
    
    func sendRecentData(samples: [GlucoseValue], unit: HKUnit, predictionDelta: Double) {
        
        if(devices.count == 0 ) { return }
        
        var data : Dictionary = [String: Any]();
        //data["glucose"] = value;
        data["glucosetime"] = samples.last?.startDate.timeIntervalSince1970
        data["predictiondelta"] = predictionDelta
        data["glucosevalues"] = samples.map{ $0.quantity.doubleValue(for: unit)}
      
        NSLog("Garmin Sending message: \(data)")
        ConnectIQ.sharedInstance().sendMessage(data, to: self.garminLoopApp, progress: {(sentBytes: UInt32, totalBytes: UInt32) -> Void in
            let percent: Double = 100.0 * Double(sentBytes / totalBytes)
            print("Garmin Progress: \(percent)% sent \(sentBytes) bytes of \(totalBytes)")
        }, completion: {(result: IQSendMessageResult) -> Void in
            NSLog("Garmin Send message finished with result: \(NSStringFromSendMessageResult(result))")
        })
        
        
    }

    func saveDevicesToFileSystem() {
        print("Saving known devices to \(self.devicesFilePath())")
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
        return appSupportDirectory.appendingPathComponent(kDevicesFileName).path
    }


}

  
