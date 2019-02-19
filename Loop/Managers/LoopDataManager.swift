//
//  LoopDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/12/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }

    // MB AutoSens
    //var averageRetroError = 0.0
    var lastAutoSensUpdate : Date = Date.init(timeIntervalSince1970: 0)
    //
    
    // MB Alerts
    var bolusAlertStartTime = Date.init()
    //
    
    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    let carbStore: CarbStore

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore

    weak var delegate: LoopDataManagerDelegate?

    private let logger: CategoryLogger

    // References to registered notification center observers
    private var notificationObservers: [Any] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // Make overall retrospective effect available for display to the user
    var totalRetrospectiveCorrection: HKQuantity?

    init(
        lastLoopCompleted: Date?,
        lastTempBasal: DoseEntry?,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
    ) {
        self.logger = DiagnosticLogger.shared.forCategory("LoopDataManager")
        self.lockedLastLoopCompleted = Locked(lastLoopCompleted)
        self.lastTempBasal = lastTempBasal
        self.settings = settings

        let healthStore = HKHealthStore()
        let cacheStore = PersistenceController.controllerInAppGroupDirectory()

        carbStore = CarbStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            defaultAbsorptionTimes: (
                fast: TimeInterval(hours: 0.5),
                medium: TimeInterval(hours: 1.5),
                slow: TimeInterval(hours: 3)
            ),
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )
        
        totalRetrospectiveCorrection = nil
        
        doseStore = DoseStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule
        )

        glucoseStore = GlucoseStore(healthStore: healthStore, cacheStore: cacheStore, cacheLength: .hours(24))

        cacheStore.delegate = self

        // Observe changes
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: .CarbEntriesDidUpdate,
                object: carbStore,
                queue: nil
            ) { (note) -> Void in
                self.dataAccessQueue.async {
                    self.logger.default("Received notification of carb entries updating")

                    self.carbEffect = nil
                    self.carbsOnBoard = nil
                    self.notify(forChange: .carbs)
                }
            },
            NotificationCenter.default.addObserver(
                forName: .GlucoseSamplesDidChange,
                object: glucoseStore,
                queue: nil
            ) { (note) in
                self.dataAccessQueue.async {
                    self.logger.default("Received notification of glucose samples changing")

                    self.glucoseMomentumEffect = nil

                    self.notify(forChange: .glucose)
                }
            }
        ]
    }

    /// Loop-related settings
    ///
    /// These are not thread-safe.
    var settings: LoopSettings {
        didSet {
            if settings.scheduleOverride != oldValue.scheduleOverride {
                doseStore.scheduleOverride = settings.scheduleOverride
                carbStore.scheduleOverride = settings.scheduleOverride
                // Invalidate cached effects affected by the override
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil
            }
            UserDefaults.appGroup.loopSettings = settings
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .utility)

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }
    private var insulinEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var glucoseMomentumEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil
        }
    }
    private var retrospectiveGlucoseEffect: [GlucoseEffect] = [] {
        didSet {
            predictedGlucose = nil
        }
    }

    private var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]? {
        didSet {
            retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies?.combinedSums(of: settings.retrospectiveCorrectionGroupingInterval * 1.01)
        }
    }
    private var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?

    fileprivate var predictedGlucose: [GlucoseValue]? {
        didSet {
            recommendedTempBasal = nil
            recommendedBolus = nil
        }
    }

    fileprivate var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)?
    fileprivate var recommendedBolus: (recommendation: BolusRecommendation, date: Date)?

    fileprivate var carbsOnBoard: CarbValue?

    fileprivate var lastTempBasal: DoseEntry?
    fileprivate var lastRequestedBolus: (units: Double, date: Date)?

    /// The last date at which a loop completed, from prediction to dose (if dosing is enabled)
    var lastLoopCompleted: Date? {
        get {
            return lockedLastLoopCompleted.value
        }
        set {
            lockedLastLoopCompleted.value = newValue

            NotificationManager.clearLoopNotRunningNotifications()
            NotificationManager.scheduleLoopNotRunningNotifications()
            AnalyticsManager.shared.loopDidSucceed()
        }
    }
    private let lockedLastLoopCompleted: Locked<Date?>

    fileprivate var lastLoopError: Error? {
        didSet {
            if lastLoopError != nil {
                AnalyticsManager.shared.loopDidError()
            }
        }
    }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    fileprivate var insulinCounteractionEffects: [GlucoseEffectVelocity] = [] {
        didSet {
            carbEffect = nil
            carbsOnBoard = nil
        }
    }

    // MARK: - Background task management

    private var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid

    private func startBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PersistenceController save") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != UIBackgroundTaskInvalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = UIBackgroundTaskInvalid
        }
    }
}

// MARK: Background task management
extension LoopDataManager: PersistenceControllerDelegate {
    func persistenceControllerWillSave(_ controller: PersistenceController) {
        startBackgroundTask()
    }

    func persistenceControllerDidSave(_ controller: PersistenceController, error: PersistenceController.PersistenceControllerError?) {
        endBackgroundTask()
    }
}

// MARK: - Preferences
extension LoopDataManager {

    /// The daily schedule of basal insulin rates
    var basalRateSchedule: BasalRateSchedule? {
        get {
            return doseStore.basalProfile
        }
        set {
            doseStore.basalProfile = newValue
            UserDefaults.appGroup.basalRateSchedule = newValue
            notify(forChange: .preferences)

            if let newValue = newValue, let oldValue = doseStore.basalProfile, newValue.items != oldValue.items {
                AnalyticsManager.shared.didChangeBasalRateSchedule()
            }
        }
    }

    /// The basal rate schedule, applying the most recently enabled override if active
    var basalRateScheduleApplyingOverrideIfActive: BasalRateSchedule? {
        return doseStore.basalProfileApplyingOverrideIfActive
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil

            notify(forChange: .preferences)
        }
    }

    /// The carb ratio schedule, applying the most recently enabled override if active
    var carbRatioScheduleApplyingOverrideIfActive: CarbRatioSchedule? {
        return carbStore.carbRatioScheduleApplyingOverrideIfActive
    }

    /// The length of time insulin has an effect on blood glucose
    var insulinModelSettings: InsulinModelSettings? {
        get {
            guard let model = doseStore.insulinModel else {
                return nil
            }

            return InsulinModelSettings(model: model)
        }
        set {
            doseStore.insulinModel = newValue?.model
            UserDefaults.appGroup.insulinModelSettings = newValue

            self.dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }

            AnalyticsManager.shared.didChangeInsulinModel()
        }
    }

    /// The daily schedule of insulin sensitivity (also known as ISF)
    /// This is measured in <blood glucose>/Unit
    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        get {
            return carbStore.insulinSensitivitySchedule
        }
        set {
            carbStore.insulinSensitivitySchedule = newValue
            doseStore.insulinSensitivitySchedule = newValue

            UserDefaults.appGroup.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }
        }
    }
    
    // MB Autosens
    /// The daily schedule of insulin sensitivity (also known as ISF)
    /// This is measured in <blood glucose>/Unit
    var autoSensFactor: Double {
        get {
            return UserDefaults.appGroup.autoSensFactor
        }
        set {
            UserDefaults.appGroup.autoSensFactor = Swift.min(3.0, Swift.max(0.9, newValue))
            self.updateAutoSens()
            /*dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil
                
                self.notify(forChange: .preferences)
            }
            */
        }
    }

    /// The insulin sensitivity schedule, applying the most recently enabled override if active
    var insulinSensitivityScheduleApplyingOverrideIfActive: InsulinSensitivitySchedule? {
        return carbStore.insulinSensitivityScheduleApplyingOverrideIfActive
    }

    /// Sets a new time zone for a the schedule-based settings
    ///
    /// - Parameter timeZone: The time zone
    func setScheduleTimeZone(_ timeZone: TimeZone) {
        if timeZone != basalRateSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            basalRateSchedule?.timeZone = timeZone
        }

        if timeZone != carbRatioSchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            carbRatioSchedule?.timeZone = timeZone
        }

        if timeZone != insulinSensitivitySchedule?.timeZone {
            AnalyticsManager.shared.punpTimeZoneDidChange()
            insulinSensitivitySchedule?.timeZone = timeZone
        }

        if timeZone != settings.glucoseTargetRangeSchedule?.timeZone {
            settings.glucoseTargetRangeSchedule?.timeZone = timeZone
        }
    }

    /// All the HealthKit types to be read and shared by stores
    private var sampleTypes: Set<HKSampleType> {
        return Set([
            glucoseStore.sampleType,
            carbStore.sampleType,
            doseStore.sampleType,
        ].compactMap { $0 })
    }

    /// True if any stores require HealthKit authorization
    var authorizationRequired: Bool {
        return glucoseStore.authorizationRequired ||
               carbStore.authorizationRequired ||
               doseStore.authorizationRequired
    }

    /// True if the user has explicitly denied access to any stores' HealthKit types
    private var sharingDenied: Bool {
        return glucoseStore.sharingDenied ||
               carbStore.sharingDenied ||
               doseStore.sharingDenied
    }

    func authorize(_ completion: @escaping () -> Void) {
        // Authorize all types at once for simplicity
        carbStore.healthStore.requestAuthorization(toShare: sampleTypes, read: sampleTypes) { (success, error) in
            if success {
                // Call the individual authorization methods to trigger query creation
                self.carbStore.authorize({ _ in })
                self.doseStore.insulinDeliveryStore.authorize({ _ in })
                self.glucoseStore.authorize({ _ in })
            }

            completion()
        }
    }
}


// MARK: - Intake
extension LoopDataManager {
    /// Adds and stores glucose data
    ///
    /// - Parameters:
    ///   - samples: The new glucose samples to store
    ///   - completion: A closure called once upon completion
    ///   - result: The stored glucose values
    func addGlucose(
        _ samples: [NewGlucoseSample],
        completion: ((_ result: Result<[GlucoseValue]>) -> Void)? = nil
    ) {
        glucoseStore.addGlucose(samples) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let samples):
                    if let endDate = samples.sorted(by: { $0.startDate < $1.startDate }).first?.startDate {
                        // Prune back any counteraction effects for recomputation
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filter { $0.endDate < endDate }
                    }

                    completion?(.success(samples))
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Adds and stores carb data, and recommends a bolus if needed
    ///
    /// - Parameters:
    ///   - carbEntry: The new carb value
    ///   - completion: A closure called once upon completion
    ///   - result: The bolus recommendation
    func addCarbEntryAndRecommendBolus(_ carbEntry: NewCarbEntry, replacing replacingEntry: StoredCarbEntry? = nil, completion: @escaping (_ result: Result<BolusRecommendation?>) -> Void) {
        let addCompletion: (CarbStoreResult<StoredCarbEntry>) -> Void = { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success:
                    // Remove the active pre-meal target override
                    self.settings.clearOverride(matching: .preMeal)

                    self.carbEffect = nil
                    self.carbsOnBoard = nil

                    do {
                        try self.update()

                        completion(.success(self.recommendedBolus?.recommendation))
                    } catch let error {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }

        if let replacingEntry = replacingEntry {
            carbStore.replaceCarbEntry(replacingEntry, withEntry: carbEntry, completion: addCompletion)
        } else {
            carbStore.addCarbEntry(carbEntry, completion: addCompletion)
        }
    }

    /// Adds a bolus requested of the pump, but not confirmed.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was requested
    func addRequestedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.lastRequestedBolus = (units: units, date: date)
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Adds a bolus enacted by the pump, but not fully delivered.
    ///
    /// - Parameters:
    ///   - units: The bolus amount, in units
    ///   - date: The date the bolus was enacted
    func addConfirmedBolus(units: Double, at date: Date, completion: (() -> Void)?) {
        self.doseStore.addPendingPumpEvent(.enactedBolus(units: units, at: date)) {
            self.dataAccessQueue.async {
                self.lastRequestedBolus = nil
                self.insulinEffect = nil
                self.notify(forChange: .bolus)

                completion?()
            }
        }
    }

    /// Adds and stores new pump events
    ///
    /// - Parameters:
    ///   - events: The pump events to add
    ///   - completion: A closure called once upon completion
    ///   - error: An error explaining why the events could not be saved.
    func addPumpEvents(_ events: [NewPumpEvent], completion: @escaping (_ error: DoseStore.DoseStoreError?) -> Void) {
        doseStore.addPumpEvents(events) { (error) in
            self.dataAccessQueue.async {
                if error == nil {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    if let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }
                }

                completion(error)
            }
        }
    }

    /// Adds and stores a pump reservoir volume
    ///
    /// - Parameters:
    ///   - units: The reservoir volume, in units
    ///   - date: The date of the volume reading
    ///   - completion: A closure called once upon completion
    ///   - result: The current state of the reservoir values:
    ///       - newValue: The new stored value
    ///       - lastValue: The previous new stored value
    ///       - areStoredValuesContinuous: Whether the current recent state of the stored reservoir data is considered continuous and reliable for deriving insulin effects after addition of this new value.
    func addReservoirValue(_ units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        doseStore.addReservoirValue(units, at: date) { (newValue, previousValue, areStoredValuesContinuous, error) in
            if let error = error {
                completion(.failure(error))
            } else if let newValue = newValue {
                self.dataAccessQueue.async {
                    self.insulinEffect = nil
                    // Expire any bolus values now represented in the insulin data
                    if areStoredValuesContinuous, let bolusDate = self.lastRequestedBolus?.date, bolusDate.timeIntervalSinceNow < TimeInterval(minutes: -5) {
                        self.lastRequestedBolus = nil
                    }

                    if let newDoseStartDate = previousValue?.startDate {
                        // Prune back any counteraction effects for recomputation, after the effect delay
                        self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(nil, newDoseStartDate.addingTimeInterval(.minutes(10)))
                    }

                    completion(.success((
                        newValue: newValue,
                        lastValue: previousValue,
                        areStoredValuesContinuous: areStoredValuesContinuous
                    )))
                }
            } else {
                assertionFailure()
            }
        }
    }

    // Actions

    func enactRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dataAccessQueue.async {
            self.setRecommendedTempBasal(completion)
        }
    }

    /// Runs the "loop"
    ///
    /// Executes an analysis of the current data, and recommends an adjustment to the current
    /// temporary basal rate.
    func loop() {
        self.dataAccessQueue.async {
            self.logger.default("Loop running")
            NotificationCenter.default.post(name: .LoopRunning, object: self)

            self.lastLoopError = nil

            do {
                try self.update()

                if self.settings.dosingEnabled {
                    self.setRecommendedTempBasal { (error) -> Void in
                        self.lastLoopError = error

                        if let error = error {
                            self.logger.error(error)
                        } else {
                            self.lastLoopCompleted = Date()
                        }
                        self.logger.default("Loop ended")
                        self.notify(forChange: .tempBasal)
                    }

                    // Delay the notification until we know the result of the temp basal
                    return
                } else {
                    self.lastLoopCompleted = Date()
                }
            } catch let error {
                self.lastLoopError = error
            }

            self.logger.default("Loop ended")
            self.notify(forChange: .tempBasal)
        }
    }

    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func update() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))
        let updateGroup = DispatchGroup()

        // Fetch glucose effects as far back as we want to make retroactive analysis
        var latestGlucoseDate: Date?
        updateGroup.enter()
        glucoseStore.getCachedGlucoseSamples(start: Date(timeIntervalSinceNow: -settings.recencyInterval)) { (values) in
            latestGlucoseDate = values.last?.startDate
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)

        guard let lastGlucoseDate = latestGlucoseDate else {
            throw LoopError.missingDataError(.glucose)
        }

        let retrospectiveStart = lastGlucoseDate.addingTimeInterval(-settings.retrospectiveCorrectionIntegrationInterval)

        let earliestEffectDate = Date(timeIntervalSinceNow: .hours(-24))
        let nextEffectDate = insulinCounteractionEffects.last?.endDate ?? earliestEffectDate

        if glucoseMomentumEffect == nil {
            updateGroup.enter()
            glucoseStore.getRecentMomentumEffect { (effects) -> Void in
                self.glucoseMomentumEffect = effects
                updateGroup.leave()
            }
        }

        if insulinEffect == nil {
            updateGroup.enter()
            doseStore.getGlucoseEffects(start: nextEffectDate) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.insulinEffect = nil
                case .success(let effects):
                    self.insulinEffect = effects
                }

                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if nextEffectDate < lastGlucoseDate, let insulinEffect = insulinEffect {
            updateGroup.enter()
            self.logger.debug("Fetching counteraction effects after \(nextEffectDate)")
            glucoseStore.getCounteractionEffects(start: nextEffectDate, to: insulinEffect) { (velocities) in
                self.insulinCounteractionEffects.append(contentsOf: velocities)
                self.insulinCounteractionEffects = self.insulinCounteractionEffects.filterDateRange(earliestEffectDate, nil)

                updateGroup.leave()
            }

            _ = updateGroup.wait(timeout: .distantFuture)
        }

        if carbEffect == nil {
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: retrospectiveStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffect = nil
                case .success(let effects):
                    self.carbEffect = effects
                }

                updateGroup.leave()
            }
        }

        if carbsOnBoard == nil {
            updateGroup.enter()
            carbStore.carbsOnBoard(at: Date(), effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil) { (result) in
                switch result {
                case .failure:
                    // Failure is expected when there is no carb data
                    self.carbsOnBoard = nil
                case .success(let value):
                    self.carbsOnBoard = value
                }
                updateGroup.leave()
            }
        }

        _ = updateGroup.wait(timeout: .distantFuture)

        if retrospectiveGlucoseDiscrepancies == nil {
            do {
                try updateRetrospectiveGlucoseEffect()
            } catch let error {
                logger.error(error)
            }
        }

        if predictedGlucose == nil {
            do {
                try updatePredictedGlucoseAndRecommendedBasalAndBolus()
            } catch let error {
                logger.error(error)

                throw error
            }
        }
        
        // MB Custom
        checkAlerts()
        updateAutoSens();
        
    }
    
    // MB Autosens
    func updateAutoSens() {
        
        let adjustmentFactor = 0.0 // 0.0005/10 0.5% per 10 mg/dL
        let minLimit : Double = 0.90
        let maxLimit : Double = 3.00
        let minWaitMinutes  : Double = 4.0
        
        var autoSensFactor = UserDefaults.appGroup.autoSensFactor
        
        if(-self.lastAutoSensUpdate.timeIntervalSinceNow < minWaitMinutes*60) {
            return
        }
       
        
        let unit = HKUnit.milligramsPerDeciliter
        
        if let lastDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last?.quantity.doubleValue(for: unit) { //} retrospectiveGlucoseDiscrepancies?.last?.quantity.doubleValue(for: unit) {
            
            let workoutmode = self.settings.scheduleOverrideEnabled()
            if(workoutmode && autoSensFactor > 1.0) {
                DiagnosticLogger.shared.forCategory("MBAutoSens").debug("AutoSens decay paused due to workout mode and asf > 1")
            } else {
                //autoSensFactor = pow(autoSensFactor, 0.995) // Trend to zero
            }
            
            let adjustment = -lastDiscrepancy*adjustmentFactor
            autoSensFactor = autoSensFactor + adjustment
            
            lastAutoSensUpdate = Date.init()
            autoSensFactor = Swift.max(minLimit, Swift.min(maxLimit, autoSensFactor))
            UserDefaults.appGroup.autoSensFactor = autoSensFactor
            DiagnosticLogger.shared.forCategory("MBAutoSens").debug("AutoSens updated.  Current retro error:\(lastDiscrepancy), ASF now: \(autoSensFactor)")
            
            // Update Insulin Sensitivity
            if let defaultInsulinSensitivitySchedule = UserDefaults.appGroup.insulinSensitivitySchedule {
                DiagnosticLogger.shared.forCategory("MBAutoSens").debug("Default sensitivity \(defaultInsulinSensitivitySchedule.debugDescription)")
                
                var adjustedInsulinItems : [RepeatingScheduleValue<Double>] = []
                defaultInsulinSensitivitySchedule.items.forEach{ item in
                    adjustedInsulinItems.append(RepeatingScheduleValue<Double>.init(startTime: item.startTime, value: item.value*autoSensFactor))
                }
                var adjustedInsulinSensSched : InsulinSensitivitySchedule = InsulinSensitivitySchedule.init( unit:defaultInsulinSensitivitySchedule.unit, dailyItems:adjustedInsulinItems)!
                if let timeZone = carbStore.insulinSensitivitySchedule?.timeZone {
                    adjustedInsulinSensSched.timeZone  = timeZone
                }
                carbStore.insulinSensitivitySchedule = adjustedInsulinSensSched;
                doseStore.insulinSensitivitySchedule = adjustedInsulinSensSched;
                DiagnosticLogger.shared.forCategory("MBAutoSens").debug("Sensitivity now \(adjustedInsulinSensSched.debugDescription)")
            }
            
            // Update Carb Ratio
            if let defaultCarbRatioSchedule = UserDefaults.appGroup.carbRatioSchedule {
                DiagnosticLogger.shared.forCategory("MBAutoSens").debug("Default carbratio \(defaultCarbRatioSchedule.debugDescription)")
                
                var adjustedCarbItems : [RepeatingScheduleValue<Double>] = []
                defaultCarbRatioSchedule.items.forEach{ item in
                    adjustedCarbItems.append(RepeatingScheduleValue<Double>.init(startTime: item.startTime, value: item.value*autoSensFactor))
                }
                var adjustedCarbRatioSchedule : CarbRatioSchedule = CarbRatioSchedule.init( unit:defaultCarbRatioSchedule.unit, dailyItems:adjustedCarbItems)!
                
                if let timeZone = carbStore.carbRatioSchedule?.timeZone {
                    adjustedCarbRatioSchedule.timeZone  = timeZone
                }
                carbStore.carbRatioSchedule = adjustedCarbRatioSchedule;
                //doseStore.carbRatioSchedule = adjustedCarbRatioSchedule;
                DiagnosticLogger.shared.forCategory("MBAutoSens").debug("Carb ratio now \(carbStore.carbRatioSchedule.debugDescription)")
            }
            
            
        }
    }

    public func currentSuspendThreshold() -> HKQuantity {
        
        var activeSuspend = settings.suspendThreshold?.quantity ?? HKQuantity(unit:HKUnit.milligramsPerDeciliter,  doubleValue:80)
        
//        let workoutmode = self.settings.glucoseTargetRangeSchedule?.overrideEnabledForContext(.workout) ?? false;
        let workoutmode = self.settings.scheduleOverrideEnabled()
        
        if (workoutmode) {
            let currentValue = activeSuspend.doubleValue(for: HKUnit.milligramsPerDeciliter)
            let rangeMin = settings.glucoseTargetRangeScheduleApplyingOverrideIfActive?.minQuantity(at: Date()).doubleValue(for:HKUnit.milligramsPerDeciliter) ?? 170.0
            activeSuspend = HKQuantity(unit:HKUnit.milligramsPerDeciliter,  doubleValue:max(currentValue, rangeMin - 20.0))
            //activeSuspend = workoutSuspendQuantity
            NSLog("Workout mode, suspend threshold \(activeSuspend)")
        } else {
            NSLog("Suspend threshold \(activeSuspend)")
        }
        return activeSuspend
    }
    
    // MB Alerts
    private func checkAlerts() {
        
        NSLog("MB Custom alerts")
        // Prediction differential alert
        let unit = HKUnit.milligramsPerDeciliter
        if let lastDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last?.quantity.doubleValue(for: unit) { // retrospectiveGlucoseDiscrepancies?.last?.quantity.doubleValue(for: unit) {
            if(abs(lastDiscrepancy) > 40) {
                //NSLog("MB Prediction error alert: %.0f", currentVal-retroVal)
                NotificationManager.sendForecastErrorNotification(quantity: lastDiscrepancy);
            } else {
                NSLog("MB Prediction error ok %.0f", lastDiscrepancy)
            }
            
        }
    
        
        // High and low alerts
        if let glucose = predictedGlucose {
            
            // 45 min check
            if let nextHourMinGlucose = (glucose.filter { $0.startDate <= Date().addingTimeInterval(45*60) }.min{ $0.quantity < $1.quantity }) {
                let lowAlertThreshold = GlucoseThreshold (unit: unit, value:80)
                if nextHourMinGlucose.quantity <= lowAlertThreshold.quantity {
                    // alert
                    NotificationManager.sendLowGlucoseNotification(quantity: nextHourMinGlucose.quantity.doubleValue(for: unit), time:nextHourMinGlucose.startDate, currentGlucose:glucoseStore.latestGlucose?.quantity.doubleValue(for: unit) ?? nextHourMinGlucose.quantity.doubleValue(for: unit));
                    DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 45 min low glucose ALERT: min \(nextHourMinGlucose.quantity) threshold \(lowAlertThreshold)")

                } else {
                    //DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 45 min low glucose ok: min \(nextHourMinGlucose.quantity) threshold \(lowAlertThreshold)")
                }
            }

            // one hour check
            if let nextHourMinGlucose = (glucose.filter { $0.startDate <= Date().addingTimeInterval(60*60) }.min{ $0.quantity < $1.quantity }) {
                let lowAlertThreshold = GlucoseThreshold (unit: unit, value:60)
                if nextHourMinGlucose.quantity <= lowAlertThreshold.quantity {
                    // alert
                    //NSLog("MB Next hour low glucose alert: min %@ threshold %@", nextHourMinGlucose.quantity, lowAlertThreshold.quantity)
                    NotificationManager.sendLowGlucoseNotification(quantity: nextHourMinGlucose.quantity.doubleValue(for: unit), time:nextHourMinGlucose.startDate, currentGlucose:glucoseStore.latestGlucose?.quantity.doubleValue(for: unit) ?? nextHourMinGlucose.quantity.doubleValue(for: unit));
                    DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 60 min low glucose ALERT: min \(nextHourMinGlucose.quantity) threshold \(lowAlertThreshold)")
                } else {
                    //DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 60 min low glucose ok: min \(nextHourMinGlucose.quantity) threshold \(lowAlertThreshold)")

                }
            }
            
            // High glucose
            let highAlertThreshold = GlucoseThreshold (unit: unit, value:220)
            if let nextHourMaxGlucose = (glucose.filter { $0.startDate <= Date().addingTimeInterval(30*60) }.last) {
                if nextHourMaxGlucose.quantity >= highAlertThreshold.quantity {
                    // alert
                    //NSLog("MB Next 30 min high glucose alert: last %@ threshold %@", nextHourMaxGlucose.quantity, highAlertThreshold.quantity)
                    NotificationManager.sendHighGlucoseNotification(quantity: nextHourMaxGlucose.quantity.doubleValue(for: unit), time:nextHourMaxGlucose.startDate, currentGlucose:glucoseStore.latestGlucose?.quantity.doubleValue(for: unit) ?? nextHourMaxGlucose.quantity.doubleValue(for: unit));
                    DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 30 min high glucose ALERT: min \(nextHourMaxGlucose.quantity) threshold \(highAlertThreshold)")
                } else {
                    //DiagnosticLogger.shared.forCategory("MBAlerts").debug("MB Next 30 min high glucose ok: min \nextHourMaxGlucose.quantity) threshold \(highAlertThreshold)")

                }
            }
            
            // Bolus needed
            do {
                let minAlertBolus : Double = 2.0;
                let minTime : Double = 9 * 60 // sec;
                let bolusAmount : Double = recommendedBolus?.recommendation.amount ?? 0
                
                if(bolusAmount > minAlertBolus) {
                    if (bolusAlertStartTime.timeIntervalSinceNow < -minTime ) {
                        NotificationManager.sendRecommendBolusNotification(quantity: bolusAmount)
                        DiagnosticLogger.shared.forCategory("MBAlerts").debug("Recommend bolus alert \(bolusAmount)")
                        bolusAlertStartTime = Date.init();
                    } else {
                        //DiagnosticLogger.shared.forCategory("MBAlerts").debug("Recommend \(bolusAmount) bolus for past \(-bolusAlertStartTime.timeIntervalSinceNow/60) min, waiting for \(minTime/60) ")
                    }
                } else {
                    bolusAlertStartTime = Date.init();
                }
                
            }
            
        }
        
        NSLog("MB End custom alerts")
        // End MB Custom Alerts
    }
    

    private func notify(forChange context: LoopUpdateContext) {
        NotificationCenter.default.post(name: .LoopDataUpdated,
            object: self,
            userInfo: [
                type(of: self).LoopUpdateContextKey: context.rawValue
            ]
        )
    }

    /// Computes amount of insulin from boluses that have been issued and not confirmed, and
    /// remaining insulin delivery from temporary basal rate adjustments above scheduled rate
    /// that are still in progress.
    ///
    /// - Returns: The amount of pending insulin, in units
    /// - Throws: LoopError.configurationError
    private func getPendingInsulin() throws -> Double {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let basalRates = basalRateScheduleApplyingOverrideIfActive else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let lastTempBasal = lastTempBasal, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = lastTempBasal.endDate.timeIntervalSince(date)
            let remainingUnits = (lastTempBasal.unitsPerHour - normalBasalRate) * remainingTime.hours

            pendingTempBasalInsulin = max(0, remainingUnits)
        } else {
            pendingTempBasalInsulin = 0
        }

        let pendingBolusAmount: Double = lastRequestedBolus?.units ?? 0

        // All outstanding potential insulin delivery
        return pendingTempBasalInsulin + pendingBolusAmount
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError(.insulinModel)
        }

        guard let glucose = self.glucoseStore.latestGlucose else {
            throw LoopError.missingDataError(.glucose)
        }

        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []

        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }

        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }

        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }

        if inputs.contains(.retrospection) {
            effects.append(self.retrospectiveGlucoseEffect)
        }

        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return prediction
    }

    /// Generates an effect based on how large the discrepancy is between the current glucose and its predicted value.
    ///
    /// - Parameter effectDuration: The length of time to extend the effect
    /// - Throws: LoopError.missingDataError
    private func updateRetrospectiveGlucoseEffect(effectDuration: TimeInterval = TimeInterval(minutes: 60)) throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.carbEffect)
        }

        // Timeline of glucose discrepancies
        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)

        // Our last change should be recent, otherwise clear the effects
        let currentDate = Date()
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
            currentDate.timeIntervalSince(currentDiscrepancy.endDate) <= settings.recencyInterval
        else {
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            return
        }

        // Most recent glucose
        guard let latestGlucose = self.glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.glucose)
        }

        let unit = HKUnit.milligramsPerDeciliter // do all math in mg/dL

        // Standard retrospective correction
        let currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        var correctionEffectDuration = effectDuration
        var scaledCorrection = currentDiscrepancyValue
        self.totalRetrospectiveCorrection = HKQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        
        // If enabled, calculate integral retrospective correction
        if settings.integralRetrospectiveCorrectionEnabled {
            
            /// Calculate integral retrospective correction if user settings and past discrepancies over integration interval are available
            if  let correctionRange = settings.glucoseTargetRangeSchedule,
                let insulinSensitivity = insulinSensitivitySchedule,
                let basalRates = basalRateSchedule,
                let pastDiscrepancies = retrospectiveGlucoseDiscrepanciesSummed?.filterDateRange(currentDate.addingTimeInterval(-settings.retrospectiveCorrectionIntegrationInterval), currentDate) {
                
                let integralRC = IntegralRetrospectiveCorrection(effectDuration, settings, correctionRange, insulinSensitivity, basalRates)
                
                // Calculate overall retrospective correction effect and effect duration
                let (totalRC, integralCorrectionDuration) = integralRC.updateIntegralRetrospectiveCorrection(currentDate,                                                                                                   currentDiscrepancy, latestGlucose, pastDiscrepancies)
                
                self.totalRetrospectiveCorrection = totalRC
                correctionEffectDuration = integralCorrectionDuration
                
                // correction value scaled to account for extended effect duration
                scaledCorrection = totalRC.doubleValue(for: unit) * effectDuration.minutes / integralCorrectionDuration.minutes
            }
            
        }
        
        let retrospectionTimeInterval = currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate)
        let discrepancyTime = max(retrospectionTimeInterval, settings.retrospectiveCorrectionGroupingInterval)
        let velocity = HKQuantity(unit: unit.unitDivided(by: .second()), doubleValue: scaledCorrection / discrepancyTime)

        retrospectiveGlucoseEffect = latestGlucose.decayEffect(atRate: velocity, for: correctionEffectDuration)
    }

    /// Runs the glucose prediction on the latest effect data.
    ///
    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    private func updatePredictedGlucoseAndRecommendedBasalAndBolus() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let glucose = glucoseStore.latestGlucose else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.glucose)
        }

        guard let pumpStatusDate = doseStore.lastReservoirValue?.startDate else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.reservoir)
        }

        let startDate = Date()

        guard startDate.timeIntervalSince(glucose.startDate) <= settings.recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.glucoseTooOld(date: glucose.startDate)
        }

        guard startDate.timeIntervalSince(pumpStatusDate) <= settings.recencyInterval else {
            self.predictedGlucose = nil
            throw LoopError.pumpDataTooOld(date: pumpStatusDate)
        }

        guard glucoseMomentumEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.momentumEffect)
        }

        guard carbEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.carbEffect)
        }

        guard insulinEffect != nil else {
            self.predictedGlucose = nil
            throw LoopError.missingDataError(.insulinEffect)
        }

        let predictedGlucose = try predictGlucose(using: settings.enabledEffects)
        self.predictedGlucose = predictedGlucose

        guard
            let maxBasal = settings.maximumBasalRatePerHour,
            let glucoseTargetRange = settings.glucoseTargetRangeScheduleApplyingOverrideIfActive,
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideIfActive,
            let basalRates = basalRateScheduleApplyingOverrideIfActive,
            let maxBolus = settings.maximumBolus,
            let model = insulinModelSettings?.model
        else {
            throw LoopError.configurationError(.generalSettings)
        }
        
        guard lastRequestedBolus == nil
        else {
            // Don't recommend changes if a bolus was just requested.
            // Sending additional pump commands is not going to be
            // successful in any case.
            recommendedBolus = nil
            recommendedTempBasal = nil
            return
        }

        let tempBasal = predictedGlucose.recommendedTempBasal(
            to: glucoseTargetRange,
            suspendThreshold: currentSuspendThreshold(), // settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            basalRates: basalRates,
            maxBasalRate: maxBasal,
            lastTempBasal: lastTempBasal,
            isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
        )
        
        if let temp = tempBasal {
            recommendedTempBasal = (recommendation: temp, date: startDate)
        } else {
            recommendedTempBasal = nil
        }

        let pendingInsulin = try self.getPendingInsulin()

        let recommendation = predictedGlucose.recommendedBolus(
            to: glucoseTargetRange,
            suspendThreshold: currentSuspendThreshold(),  // settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus
        )
        recommendedBolus = (recommendation: recommendation, date: startDate)
    }

    /// *This method should only be called from the `dataAccessQueue`*
    private func setRecommendedTempBasal(_ completion: @escaping (_ error: Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        guard let recommendedTempBasal = self.recommendedTempBasal else {
            completion(nil)
            return
        }

        guard abs(recommendedTempBasal.date.timeIntervalSinceNow) < TimeInterval(minutes: 5) else {
            completion(LoopError.recommendationExpired(date: recommendedTempBasal.date))
            return
        }

        delegate?.loopDataManager(self, didRecommendBasalChange: recommendedTempBasal) { (result) in
            self.dataAccessQueue.async {
                switch result {
                case .success(let basal):
                    self.lastTempBasal = basal
                    self.recommendedTempBasal = nil

                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }
}


/// Describes a view into the loop state
protocol LoopState {
    /// The last-calculated carbs on board
    var carbsOnBoard: CarbValue? { get }

    /// An error in the current state of the loop, or one that happened during the last attempt to loop.
    var error: Error? { get }

    /// A timeline of average velocity of glucose change counteracting predicted insulin effects
    var insulinCounteractionEffects: [GlucoseEffectVelocity] { get }

    /// The last set temp basal
    var lastTempBasal: DoseEntry? { get }

    /// The calculated timeline of predicted glucose values
    var predictedGlucose: [GlucoseValue]? { get }

    /// The recommended temp basal based on predicted glucose
    var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? { get }

    var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? { get }

    /// The difference in predicted vs actual glucose over a recent period
    var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? { get }

    /// Calculates a new prediction from the current data using the specified effect inputs
    ///
    /// This method is intended for visualization purposes only, not dosing calculation. No validation of input data is done.
    ///
    /// - Parameter inputs: The effect inputs to include
    /// - Returns: An timeline of predicted glucose values
    /// - Throws: LoopError.missingDataError if prediction cannot be computed
    func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue]
}


extension LoopDataManager {
    private struct LoopStateView: LoopState {
        private let loopDataManager: LoopDataManager
        private let updateError: Error?

        init(loopDataManager: LoopDataManager, updateError: Error?) {
            self.loopDataManager = loopDataManager
            self.updateError = updateError
        }

        var carbsOnBoard: CarbValue? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.carbsOnBoard
        }

        var error: Error? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return updateError ?? loopDataManager.lastLoopError
        }

        var insulinCounteractionEffects: [GlucoseEffectVelocity] {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.insulinCounteractionEffects
        }

        var lastTempBasal: DoseEntry? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.lastTempBasal
        }

        var predictedGlucose: [GlucoseValue]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.predictedGlucose
        }

        var recommendedTempBasal: (recommendation: TempBasalRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedTempBasal
        }
        
        var recommendedBolus: (recommendation: BolusRecommendation, date: Date)? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.recommendedBolus
        }

        var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? {
            dispatchPrecondition(condition: .onQueue(loopDataManager.dataAccessQueue))
            return loopDataManager.retrospectiveGlucoseDiscrepanciesSummed
        }

        func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
            return try loopDataManager.predictGlucose(using: inputs)
        }
    }

    /// Executes a closure with access to the current state of the loop.
    ///
    /// This operation is performed asynchronously and the closure will be executed on an arbitrary background queue.
    ///
    /// - Parameter handler: A closure called when the state is ready
    /// - Parameter manager: The loop manager
    /// - Parameter state: The current state of the manager. This is invalid to access outside of the closure.
    func getLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        dataAccessQueue.async {
            var updateError: Error?

            do {
                try self.update()
            } catch let error {
                updateError = error
            }

            handler(self, LoopStateView(loopDataManager: self, updateError: updateError))
        }
    }
}


extension LoopDataManager {
    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        getLoopState { (manager, state) in

            var entries: [String] = [
                "## LoopDataManager",
                "settings: \(String(reflecting: manager.settings))",

                "insulinCounteractionEffects: [",
                "* GlucoseEffectVelocity(start, end, mg/dL/min)",
                manager.insulinCounteractionEffects.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n")
                }),
                "]",

                "insulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "carbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.carbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "predictedGlucose: [",
                "* PredictedGlucoseValue(start, mg/dL)",
                (state.predictedGlucose ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepancies: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepancies ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "retrospectiveGlucoseDiscrepanciesSummed: [",
                "* GlucoseChange(start, end, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepanciesSummed ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",

                "glucoseMomentumEffect: \(manager.glucoseMomentumEffect ?? [])",
                "retrospectiveGlucoseEffect: \(manager.retrospectiveGlucoseEffect)",
                "recommendedTempBasal: \(String(describing: state.recommendedTempBasal))",
                "recommendedBolus: \(String(describing: state.recommendedBolus))",
                "lastBolus: \(String(describing: manager.lastRequestedBolus))",
                "lastLoopCompleted: \(String(describing: manager.lastLoopCompleted))",
                "lastTempBasal: \(String(describing: state.lastTempBasal))",
                "carbsOnBoard: \(String(describing: state.carbsOnBoard))",
                "error: \(String(describing: state.error))",
                "",
                "cacheStore: \(String(reflecting: self.glucoseStore.cacheStore))",
                "",
            ]

            self.glucoseStore.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")

                self.carbStore.generateDiagnosticReport { (report) in
                    entries.append(report)
                    entries.append("")

                    self.doseStore.generateDiagnosticReport { (report) in
                        entries.append(report)
                        entries.append("")

                        completion(entries.joined(separator: "\n"))
                    }
                }
            }
        }
    }
}


extension Notification.Name {
    static let LoopDataUpdated = Notification.Name(rawValue:  "com.loudnate.Naterade.notification.LoopDataUpdated")

    static let LoopRunning = Notification.Name(rawValue: "com.loudnate.Naterade.notification.LoopRunning")
}


protocol LoopDataManagerDelegate: class {

    /// Informs the delegate that an immediate basal change is recommended
    ///
    /// - Parameters:
    ///   - manager: The manager
    ///   - basal: The new recommended basal
    ///   - completion: A closure called once on completion
    ///   - result: The enacted basal
    func loopDataManager(_ manager: LoopDataManager, didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date), completion: @escaping (_ result: Result<DoseEntry>) -> Void) -> Void
}


private extension TemporaryScheduleOverride {
    func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date), let basalRateMultiplier = settings.basalRateMultiplier else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
}
