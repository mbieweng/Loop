//
//  NotificationManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/30/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import UserNotifications
import LoopKit

struct NotificationManager {

    enum Action: String {
        case retryBolus
    }

    enum UserInfoKey: String {
        case bolusAmount
        case bolusStartDate
    }
    
    private static var lastLowBGAlertTime : Date = Date(timeIntervalSince1970: 0);
    private static var lastHighBGAlertTime : Date = Date(timeIntervalSince1970: 0);
    private static var lastForecastErrorAlertTime : Date = Date(timeIntervalSince1970: 0);
    private static var lastRecommendBolusAlertTime : Date = Date(timeIntervalSince1970: 0);

    private static var notificationCategories: Set<UNNotificationCategory> {
        var categories = [UNNotificationCategory]()

        let retryBolusAction = UNNotificationAction(
            identifier: Action.retryBolus.rawValue,
            title: NSLocalizedString("Retry", comment: "The title of the notification action to retry a bolus command"),
            options: []
        )

        categories.append(UNNotificationCategory(
            identifier: LoopNotificationCategory.bolusFailure.rawValue,
            actions: [retryBolusAction],
            intentIdentifiers: [],
            options: []
        ))

        return Set(categories)
    }

    static func authorize(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()

        center.delegate = delegate
        center.requestAuthorization(options: [.badge, .sound, .alert], completionHandler: { _, _ in })
        center.setNotificationCategories(notificationCategories)
    }

    // MARK: - Notifications

    static func sendBolusFailureNotification(for error: Error, units: Double, at startDate: Date) {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Bolus", comment: "The notification title for a bolus failure")

        let sentenceFormat = NSLocalizedString("%@.", comment: "Appends a full-stop to a statement")

        switch error {
        case let error as SetBolusError:
            notification.subtitle = error.errorDescriptionWithUnits(units)

            let body = [error.failureReason, error.recoverySuggestion].compactMap({ $0 }).map({
                String(format: sentenceFormat, $0)
            }).joined(separator: " ")

            notification.body = body
        case let error as LocalizedError:
            if let subtitle = error.errorDescription {
                notification.subtitle = subtitle
            }
            let message = [error.failureReason, error.recoverySuggestion].compactMap({ $0 }).map({
                String(format: sentenceFormat, $0)
            }).joined(separator: "\n")
            notification.body = message.isEmpty ? String(describing: error) : message
        default:
            notification.body = error.localizedDescription
        }

        notification.sound = UNNotificationSound.default()

        if startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5) {
            notification.categoryIdentifier = LoopNotificationCategory.bolusFailure.rawValue
        }

        notification.userInfo = [
            UserInfoKey.bolusAmount.rawValue: units,
            UserInfoKey.bolusStartDate.rawValue: startDate
        ]

        let request = UNNotificationRequest(
            // Only support 1 bolus notification at once
            identifier: LoopNotificationCategory.bolusFailure.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
    
    static func sendLowGlucoseNotification(quantity: Double, time:Date, currentGlucose:Double) {
       
        if(-self.lastLowBGAlertTime.timeIntervalSinceNow < 8*60)  {
            NSLog("Only %f min since last low glucose alert...snoozing", -self.lastLowBGAlertTime.timeIntervalSinceNow/60)
            return
        }
        
        let minutes = time.timeIntervalSinceNow.minutes
        let notification = UNMutableNotificationContent()
        
        notification.title = NSLocalizedString("Low", comment: "The notification title for a predicted low glucose")
        
        //notification.body = NSLocalizedString("Low BG expected within 1 hour", comment: "The notification alert describing a low glucose")
        notification.body = String(format: NSLocalizedString("%.0f in %.0f min (%.0f now)", comment: "The notification alert describing a low glucose"), quantity, minutes, currentGlucose)

        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.lowGluc.rawValue
        
        let request = UNNotificationRequest(
            identifier: "\(LoopNotificationCategory.lowGluc.rawValue)\(UUID().uuidString)",
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
 
        self.lastLowBGAlertTime = Date.init();
    }
    
    static func sendHighGlucoseNotification(quantity: Double, time:Date, currentGlucose:Double) {
        
        if(-self.lastHighBGAlertTime.timeIntervalSinceNow < 60*60)  {
            NSLog("Only %f min since last high glucose alert...snoozing", -self.lastHighBGAlertTime.timeIntervalSinceNow/60)
            return
        }
       
        let minutes = time.timeIntervalSinceNow.minutes
        let notification = UNMutableNotificationContent()
        
        notification.title = NSLocalizedString("High", comment: "The notification title for a predicted high glucose")
        
        notification.body = String(format: NSLocalizedString("%.0f in %.0f min (%.0f now)", comment: "The notification alert describing a high glucose"), quantity, minutes, currentGlucose)
        
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.highGluc.rawValue
        
        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.highGluc.rawValue,
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
        
        self.lastHighBGAlertTime = Date.init();
        
    }
    
    static func sendForecastErrorNotification(quantity: Double) {
        
        if(-self.lastForecastErrorAlertTime.timeIntervalSinceNow < 60*60)  {
            NSLog("Only %f min since lastForecastErrorAlertTime...snoozing", -self.lastForecastErrorAlertTime.timeIntervalSinceNow/60)
            return
        }
        
        let notification = UNMutableNotificationContent()
        notification.title = NSLocalizedString("Prediction Differential", comment: "The notification title for a large prediction error")
        notification.body = String(format: NSLocalizedString("BG currently %.0f from predicted", comment: "The notification alert describing a high prediction error"), quantity)
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.forecastError.rawValue
        
        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.forecastError.rawValue,
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
        
        self.lastForecastErrorAlertTime = Date.init();
        
    }
    
    static func sendRecommendBolusNotification(quantity: Double) {
        
        if(-self.lastRecommendBolusAlertTime.timeIntervalSinceNow < 30*60)  {
            NSLog("Only %f min since lastBolusAlertTime...snoozing", -self.lastRecommendBolusAlertTime.timeIntervalSinceNow/60)
            return
        }
        
        let notification = UNMutableNotificationContent()
        notification.title = NSLocalizedString("Bolus Recommended", comment: "The notification title for a bolus recommended")
        notification.body = String(format: NSLocalizedString("Consider %.1f U bolus", comment: "The notification alert describing a bolus recommended"), quantity)
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.bolusRecommend.rawValue
        
        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.bolusRecommend.rawValue,
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
        
        self.lastRecommendBolusAlertTime = Date.init();
        
    }


    // Cancel any previous scheduled notifications in the Loop Not Running category
    static func clearPendingNotificationRequests() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func scheduleLoopNotRunningNotifications() {
        // Give a little extra time for a loop-in-progress to complete
        let gracePeriod = TimeInterval(minutes: 0.5)

        for minutes: Double in [20, 40, 60, 120] {
            let notification = UNMutableNotificationContent()
            let failureInterval = TimeInterval(minutes: minutes)

            let formatter = DateComponentsFormatter()
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full

            if let failueIntervalString = formatter.string(from: failureInterval)?.localizedLowercase {
                notification.body = String(format: NSLocalizedString("Loop has not completed successfully in %@", comment: "The notification alert describing a long-lasting loop failure. The substitution parameter is the time interval since the last loop"), failueIntervalString)
            }

            notification.title = NSLocalizedString("Loop Failure", comment: "The notification title for a loop failure")
            notification.sound = UNNotificationSound.default()
            notification.categoryIdentifier = LoopNotificationCategory.loopNotRunning.rawValue
            notification.threadIdentifier = LoopNotificationCategory.loopNotRunning.rawValue

            let request = UNNotificationRequest(
                identifier: "\(LoopNotificationCategory.loopNotRunning.rawValue)\(failureInterval)",
                content: notification,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: failureInterval + gracePeriod,
                    repeats: false
                )
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

    static func clearLoopNotRunningNotifications() {
        // Clear out any existing not-running notifications
        UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
            let loopNotRunningIdentifiers = notifications.filter({
                $0.request.content.categoryIdentifier == LoopNotificationCategory.loopNotRunning.rawValue
            }).map({
                $0.request.identifier
            })

            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: loopNotRunningIdentifiers)
        }
    }

    static func sendPumpBatteryLowNotification() {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Battery Low", comment: "The notification title for a low pump battery")
        notification.body = NSLocalizedString("Change the pump battery immediately", comment: "The notification alert describing a low pump battery")
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.pumpBatteryLow.rawValue

        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.pumpBatteryLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
    
    static func clearPumpBatteryLowNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LoopNotificationCategory.pumpBatteryLow.rawValue])
    }

    static func sendPumpReservoirEmptyNotification() {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Reservoir Empty", comment: "The notification title for an empty pump reservoir")
        notification.body = NSLocalizedString("Change the pump reservoir now", comment: "The notification alert describing an empty pump reservoir")
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.pumpReservoirEmpty.rawValue

        let request = UNNotificationRequest(
            // Not a typo: this should replace any pump reservoir low notifications
            identifier: LoopNotificationCategory.pumpReservoirLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
    
    

    static func sendPumpReservoirLowNotificationForAmount(_ units: Double, andTimeRemaining remaining: TimeInterval?) {
        let notification = UNMutableNotificationContent()

        notification.title = NSLocalizedString("Pump Reservoir Low", comment: "The notification title for a low pump reservoir")

        let unitsString = NumberFormatter.localizedString(from: NSNumber(value: units), number: .decimal)

        let intervalFormatter = DateComponentsFormatter()
        intervalFormatter.allowedUnits = [.hour, .minute]
        intervalFormatter.maximumUnitCount = 1
        intervalFormatter.unitsStyle = .full
        intervalFormatter.includesApproximationPhrase = true
        intervalFormatter.includesTimeRemainingPhrase = true

        if let remaining = remaining, let timeString = intervalFormatter.string(from: remaining) {
            notification.body = String(format: NSLocalizedString("%1$@ U left: %2$@", comment: "Low reservoir alert with time remaining format string. (1: Number of units remaining)(2: approximate time remaining)"), unitsString, timeString)
        } else {
            notification.body = String(format: NSLocalizedString("%1$@ U left", comment: "Low reservoir alert format string. (1: Number of units remaining)"), unitsString)
        }

        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.pumpReservoirLow.rawValue

        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.pumpReservoirLow.rawValue,
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func clearPumpReservoirNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LoopNotificationCategory.pumpReservoirLow.rawValue])
    }
    
    //add notifications for remotes
    static func sendRemoteTempSetNotification(lowTarget: String, highTarget: String, multiplier: String, duration: String) {
        let notification = UNMutableNotificationContent()
        
        notification.title = NSLocalizedString("Remote Temporary Override Set", comment: "The notification title for Remote Temp")
        notification.body = NSLocalizedString("BGTargets(" + lowTarget + ":" + highTarget + ") | M:" + multiplier + " | min:" + duration, comment: "details of remote target")
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.remoteTempSet.rawValue
        
        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.remoteTempSet.rawValue,
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    static func sendRemoteTempCancelNotification() {
        let notification = UNMutableNotificationContent()
        
        notification.title = NSLocalizedString("Remote Temporary Override Canceled", comment: "The notification title for Remote Temp Cancel")
        notification.body = NSLocalizedString("", comment: "details of remote target cancel")
        notification.sound = UNNotificationSound.default()
        notification.categoryIdentifier = LoopNotificationCategory.remoteTempCancel.rawValue
        
        let request = UNNotificationRequest(
            identifier: LoopNotificationCategory.remoteTempCancel.rawValue,
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    
    
    
    
}
