//
//  AppDelegate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/15/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import Intents
import LoopKit
import UserNotifications

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private lazy var log = DiagnosticLogger.shared.forCategory("AppDelegate")

    var window: UIWindow?

    private(set) lazy var deviceManager = DeviceDataManager()

    private var rootViewController: RootNavigationController! {
        return window?.rootViewController as? RootNavigationController
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        window?.tintColor = UIColor.tintColor

        NotificationManager.authorize(delegate: self)

        log.info(#function)

        AnalyticsManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)

        rootViewController.rootViewController.deviceManager = deviceManager

        GarminConnectManager.shared.deviceManager = deviceManager
        GarminConnectManager.shared.setup()
 

        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey : Any] = [:]) -> Bool {
        /// Handle Garmin device list 
        NSLog("Open url");
        return GarminConnectManager.shared.processDeviceUrl(url: url, options:options)
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        deviceManager.pumpManager?.updateBLEHeartbeatPreference()
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    // MARK: - Continuity

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]?) -> Void) -> Bool {

        if #available(iOS 12.0, *) {
            if userActivity.activityType == NewCarbEntryIntent.className {
                log.default("Restoring \(userActivity.activityType) intent")
                rootViewController.restoreUserActivityState(.forNewCarbEntry())
                return true
            }
        }

        switch userActivity.activityType {
        case NSUserActivity.newCarbEntryActivityType,
             NSUserActivity.viewLoopStatusActivityType:
            log.default("Restoring \(userActivity.activityType) activity")
            restorationHandler([rootViewController])
            return true
        default:
            return false
        }
    }
}


extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case NotificationManager.Action.retryBolus.rawValue:
            if  let units = response.notification.request.content.userInfo[NotificationManager.UserInfoKey.bolusAmount.rawValue] as? Double,
                let startDate = response.notification.request.content.userInfo[NotificationManager.UserInfoKey.bolusStartDate.rawValue] as? Date,
                startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5)
            {
                AnalyticsManager.shared.didRetryBolus()

                deviceManager.enactBolus(units: units, at: startDate) { (_) in
                    completionHandler()
                }
                return
            }
        default:
            break
        }
        
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.badge, .sound, .alert])
    }
}
