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
import LoopCore


final class LoopDataManager {
    enum LoopUpdateContext: Int {
        case bolus
        case carbs
        case glucose
        case preferences
        case tempBasal
    }
    
    // MB Alerts
    var bolusAlertStartTime = Date.init()
    //
    
    static let LoopUpdateContextKey = "com.loudnate.Loop.LoopDataManager.LoopUpdateContext"

    let carbStore: CarbStore

    let doseStore: DoseStore

    let glucoseStore: GlucoseStore

    weak var delegate: LoopDataManagerDelegate?

    private let standardCorrectionEffectDuration = TimeInterval.minutes(60.0)

    private let integralRC: IntegralRetrospectiveCorrection

    private let standardRC: StandardRetrospectiveCorrection

    private let carbCorrection: CarbCorrection

    private let logger: CategoryLogger

    var suggestedCarbCorrection: Int?

    // References to registered notification center observers
    private var notificationObservers: [Any] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Make overall retrospective effect available for display to the user
    var totalRetrospectiveCorrection: HKQuantity?
    
    // dm61 variables for mean square error calculation
    var meanSquareError: Double = 0
    var nMSE: Double = 0.0
    var currentGlucoseValue: Double = 0
    var previouslyPredictedGlucoseValue: Double = 0
    var previouslyPredictedGlucose: GlucoseValue? = nil

    init(
        lastLoopCompleted: Date?,
        lastTempBasal: DoseEntry?,
        basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup?.basalRateSchedule,
        carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup?.carbRatioSchedule,
        insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup?.insulinModelSettings,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup?.insulinSensitivitySchedule,
        settings: LoopSettings = UserDefaults.appGroup?.loopSettings ?? LoopSettings(),
        overrideHistory: TemporaryScheduleOverrideHistory = UserDefaults.appGroup?.overrideHistory ?? .init()
    ) {
        self.logger = DiagnosticLogger.shared.forCategory("LoopDataManager")
        self.lockedLastLoopCompleted = Locked(lastLoopCompleted)
        self.lastTempBasal = lastTempBasal
        self.settings = settings
        self.overrideHistory = overrideHistory

        let healthStore = HKHealthStore()
        let cacheStore = PersistenceController.controllerInAppGroupDirectory()

        carbStore = CarbStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            defaultAbsorptionTimes: LoopSettings.defaultCarbAbsorptionTimes,
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            overrideHistory: overrideHistory,
            absorptionTimeOverrun: 1.5 // MB
            
        )
        totalRetrospectiveCorrection = nil

        doseStore = DoseStore(
            healthStore: healthStore,
            cacheStore: cacheStore,
            insulinModel: insulinModelSettings?.model,
            basalProfile: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            overrideHistory: overrideHistory
        )

        glucoseStore = GlucoseStore(healthStore: healthStore, cacheStore: cacheStore, cacheLength: .hours(24))

        integralRC = IntegralRetrospectiveCorrection(standardCorrectionEffectDuration)

        standardRC = StandardRetrospectiveCorrection(standardCorrectionEffectDuration)
        
        overrideHistory.delegate = self

        let carbCorrectionAbsorptionTime: TimeInterval = carbStore.defaultAbsorptionTimes.fast * carbStore.absorptionTimeOverrun
        carbCorrection = CarbCorrection(carbCorrectionAbsorptionTime)

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
                overrideHistory.recordOverride(settings.scheduleOverride)

                // Invalidate cached effects affected by the override
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil
            }
            UserDefaults.appGroup?.loopSettings = settings
            suggestedCarbCorrection = nil
            notify(forChange: .preferences)
            AnalyticsManager.shared.didChangeLoopSettings(from: oldValue, to: settings)
        }
    }

    let overrideHistory: TemporaryScheduleOverrideHistory

    // MARK: - Calculation state

    fileprivate let dataAccessQueue: DispatchQueue = DispatchQueue(label: "com.loudnate.Naterade.LoopDataManager.dataAccessQueue", qos: .utility)

    private var carbEffect: [GlucoseEffect]? {
        didSet {
            predictedGlucose = nil

            // Carb data may be back-dated, so re-calculate the retrospective glucose.
            retrospectiveGlucoseDiscrepancies = nil
        }
    }
    private var carbEffectFutureFood: [GlucoseEffect]?

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

    private var zeroTempEffect: [GlucoseEffect] = []
    
    private var fractionalZeroTempEffect: [GlucoseEffect] = []
    
    private var remainingZeroTempEffect: [GlucoseEffect] = []

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
    fileprivate var lastRequestedBolus: DoseEntry?
    
    
    //dm61 time series variables for parameter estimation
    private var historicalCarbEffect: [GlucoseEffect]?
    private var historicalCarbEffectAsEntered: [GlucoseEffect]?
    private var historicalInsulinEffect: [GlucoseEffect]?
    private var historicalGlucose: [GlucoseValue] = []
    private var carbStatuses: [CarbStatus<StoredCarbEntry>] = []
    private var carbStatusesCompleted: [CarbStatus<StoredCarbEntry>] = []
    private var absorbedCarbs: [AbsorbedCarbs] = []
    private var startEstimation: Date? = nil
    private var endEstimation: Date? = nil
    private var noCarbs: [NoCarbs] = []

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
            self.suggestedCarbCorrection = nil
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


// MARK: Override history tracking
extension LoopDataManager: TemporaryScheduleOverrideHistoryDelegate {
    func temporaryScheduleOverrideHistoryDidUpdate(_ history: TemporaryScheduleOverrideHistory) {
        UserDefaults.appGroup?.overrideHistory = history
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
            UserDefaults.appGroup?.basalRateSchedule = newValue
            notify(forChange: .preferences)

            if let newValue = newValue, let oldValue = doseStore.basalProfile, newValue.items != oldValue.items {
                AnalyticsManager.shared.didChangeBasalRateSchedule()
            }
        }
    }

    /// The basal rate schedule, applying recent overrides relative to the current moment in time.
    var basalRateScheduleApplyingOverrideHistory: BasalRateSchedule? {
        return doseStore.basalProfileApplyingOverrideHistory
    }

    /// The daily schedule of carbs-to-insulin ratios
    /// This is measured in grams/Unit
    var carbRatioSchedule: CarbRatioSchedule? {
        get {
            return carbStore.carbRatioSchedule
        }
        set {
            carbStore.carbRatioSchedule = newValue
            UserDefaults.appGroup?.carbRatioSchedule = newValue

            // Invalidate cached effects based on this schedule
            carbEffect = nil
            carbsOnBoard = nil

            notify(forChange: .preferences)
        }
    }

    /// The carb ratio schedule, applying recent overrides relative to the current moment in time.
    var carbRatioScheduleApplyingOverrideHistory: CarbRatioSchedule? {
        return carbStore.carbRatioScheduleApplyingOverrideHistory
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
            UserDefaults.appGroup?.insulinModelSettings = newValue

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

            UserDefaults.appGroup?.insulinSensitivitySchedule = newValue

            dataAccessQueue.async {
                // Invalidate cached effects based on this schedule
                self.carbEffect = nil
                self.carbsOnBoard = nil
                self.insulinEffect = nil

                self.notify(forChange: .preferences)
            }
        }
    }

    /// The insulin sensitivity schedule, applying recent overrides relative to the current moment in time.
    var insulinSensitivityScheduleApplyingOverrideHistory: InsulinSensitivitySchedule? {
        return carbStore.insulinSensitivityScheduleApplyingOverrideHistory
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
    ///   - dose: The DoseEntry representing the requested bolus
    func addRequestedBolus(_ dose: DoseEntry, completion: (() -> Void)?) {
        dataAccessQueue.async {
            self.lastRequestedBolus = dose
            self.notify(forChange: .bolus)

            completion?()
        }
    }

    /// Adds a bolus enacted by the pump, but not fully delivered.
    ///
    /// - Parameters:
    ///   - dose: The DoseEntry representing the confirmed bolus
    func addConfirmedBolus(_ dose: DoseEntry, completion: (() -> Void)?) {
        self.doseStore.addPendingPumpEvent(.enactedBolus(dose: dose)) {
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
                    // TODO: Ask pumpManager if dose represented in data
                    if let bolusEndDate = self.lastRequestedBolus?.endDate, bolusEndDate < Date() {
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
                    // TODO: Ask pumpManager if dose represented in data
                    if areStoredValuesContinuous, let bolusEndDate = self.lastRequestedBolus?.endDate, bolusEndDate < Date() {
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

            // effects due to future food entries, for carb-correction purposes
            let sampleStart = lastGlucoseDate.addingTimeInterval(.minutes(-20.0))
            updateGroup.enter()
            carbStore.getGlucoseEffects(
                start: sampleStart,
                sampleStart: sampleStart,
                effectVelocities: settings.dynamicCarbAbsorptionEnabled ? insulinCounteractionEffects : nil
            ) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.logger.error(error)
                    self.carbEffectFutureFood = nil
                case .success(let effects):
                    self.carbEffectFutureFood = effects
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

        do {
            try updateZeroTempEffect()
        } catch let error {
            logger.error(error)
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
        // dm61 carb correction recommendation
        if suggestedCarbCorrection == nil {
            carbCorrection.insulinEffect = insulinEffect
            carbCorrection.carbEffect = carbEffect
            carbCorrection.carbEffectFutureFood = carbEffectFutureFood
            carbCorrection.glucoseMomentumEffect = glucoseMomentumEffect
            carbCorrection.zeroTempEffect = zeroTempEffect
            carbCorrection.insulinCounteractionEffects = insulinCounteractionEffects
            carbCorrection.retrospectiveGlucoseEffect = retrospectiveGlucoseEffect
            if let latestGlucose = self.glucoseStore.latestGlucose {
                // dm61 mse calculation
                if let currentGlucose = predictedGlucose?.first {
                    if let predictedValue = previouslyPredictedGlucose?.quantity.doubleValue(for: .milligramsPerDeciliter) {
                        currentGlucoseValue = currentGlucose.quantity.doubleValue(for: .milligramsPerDeciliter)
                        previouslyPredictedGlucoseValue = predictedValue
                        nMSE += 1.0
                        meanSquareError = (meanSquareError * (nMSE - 1) + pow((currentGlucoseValue - previouslyPredictedGlucoseValue), 2)) / nMSE
                    }
                    previouslyPredictedGlucose = predictedGlucose?[1]
                }
                // dm61
                do {
                     try suggestedCarbCorrection = carbCorrection.updateCarbCorrection(latestGlucose)
                } catch let error {
                    logger.error(error)
                }
            }
        }

    }
    
    /// - Throws:
    ///     - LoopError.configurationError
    ///     - LoopError.glucoseTooOld
    ///     - LoopError.missingDataError
    ///     - LoopError.pumpDataTooOld
    fileprivate func updateParameterEstimates() throws {
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
        
        // dm61 collect data for parameter estimation
        // dm61 collect blood glucose values for parameter estimation over past 24 hours
        let startHistoricalGlucose = lastGlucoseDate.addingTimeInterval(.hours(-24.0))
        updateGroup.enter()
        glucoseStore.getCachedGlucoseSamples(start: startHistoricalGlucose) { (values) in
            self.historicalGlucose = values
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        
        
        // dm61 collect insulin effect time series for parameter estimation
        // effects due to insulin over past 24 hours
        let startHistoricalInsulinEffect = lastGlucoseDate.addingTimeInterval(.hours(-24.0))
        updateGroup.enter()
        doseStore.getGlucoseEffects(start: startHistoricalInsulinEffect) { (result) -> Void in
            switch result {
            case .failure(let error):
                self.logger.error(error)
                self.historicalInsulinEffect = nil
            case .success(let effects):
                self.historicalInsulinEffect = effects.filterDateRange(startHistoricalInsulinEffect, lastGlucoseDate)
            }
            
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        
        
        // dm61 collect carb effect time series for parameter estimation
        // effects due to food entries over past 24 hours
        let startHistoricalCarbEffect = lastGlucoseDate.addingTimeInterval(.hours(-24.0))
        updateGroup.enter()
        carbStore.getGlucoseEffects(
            start: startHistoricalCarbEffect,
            effectVelocities: insulinCounteractionEffects
        ) { (result) -> Void in
            switch result {
            case .failure(let error):
                self.logger.error(error)
                self.historicalCarbEffect = nil
            case .success(let effects):
                self.historicalCarbEffect = effects.filterDateRange(startHistoricalCarbEffect, lastGlucoseDate)
            }
            
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        
        // dm61 go through carb effects to determine start/end estimation boundaries
        var previousCarbEffect: GlucoseEffect? = nil
        if let carbs = self.historicalCarbEffect {
            if let startCarbs = carbs.first?.startDate {
                if startCarbs > startHistoricalCarbEffect.addingTimeInterval(.minutes(5)) {
                    startEstimation = startHistoricalCarbEffect
                } else {
                    for carbEffect in carbs {
                        if carbEffect.quantity == previousCarbEffect?.quantity {
                            startEstimation = carbEffect.startDate
                            break
                        } else {
                            previousCarbEffect = carbEffect
                        }
                    }
                }
            }
            previousCarbEffect = nil
            if let endCarbs = carbs.last?.startDate {
                if endCarbs < lastGlucoseDate.addingTimeInterval(.minutes(-5)) {
                    endEstimation = lastGlucoseDate
                } else {
                    for carbEffect in carbs.reversed() {
                        if carbEffect.quantity == previousCarbEffect?.quantity {
                            endEstimation = carbEffect.startDate
                            break
                        } else {
                            previousCarbEffect = carbEffect
                        }
                    }
                }
            }
        }
        
        let listStart = startHistoricalCarbEffect
        updateGroup.enter()
        carbStore.getCarbStatus(start: listStart, effectVelocities:  insulinCounteractionEffects) { (result) in
            switch result {
            case .success(let status):
                self.carbStatuses = status
            case .failure(let error):
                self.logger.error(error)
            }
            
            updateGroup.leave()
        }
        _ = updateGroup.wait(timeout: .distantFuture)
        
        carbStatusesCompleted = carbStatuses.filter { $0.absorption?.estimatedTimeRemaining ?? TimeInterval.minutes(1.0) == TimeInterval.minutes(0.0) }.filterDateRange(startEstimation, endEstimation)
        
        var activeCarbsStart = Date()
        let carbStatusesActive = carbStatuses.filter { $0.absorption?.estimatedTimeRemaining ?? TimeInterval.minutes(0.0) > TimeInterval.minutes(0.0) }
        for carbStatus in carbStatusesActive {
            activeCarbsStart = min(activeCarbsStart, carbStatus.startDate)
        }
        
        absorbedCarbs = []
        for carbStatus in carbStatusesCompleted {
            guard
                // carbStatus.endDate < activeCarbsStart
                let carbStatusEndTime = carbStatus.absorption?.observedDate.end, carbStatusEndTime < endEstimation ?? activeCarbsStart
                else {
                    continue
            }
            guard
                let startDate = carbStatus.absorption?.observedDate.start,
                let endDate = carbStatus.absorption?.observedDate.end,
                let enteredCarbs = carbStatus.absorption?.total,
                let observedCarbs = carbStatus.absorption?.observed
                else {
                    continue
            }
            guard
                absorbedCarbs.last != nil,
                absorbedCarbs.last!.endDate >= startDate
                else {
                    absorbedCarbs.append(AbsorbedCarbs(startDate: startDate, endDate: endDate, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                    continue
            }
            absorbedCarbs.last!.endDate = max( absorbedCarbs.last!.endDate, endDate )
            absorbedCarbs.last!.enteredCarbs = HKQuantity(unit: .gram(), doubleValue: enteredCarbs.doubleValue(for: .gram()) + absorbedCarbs.last!.enteredCarbs.doubleValue(for: .gram()))
            absorbedCarbs.last!.observedCarbs = HKQuantity(unit: .gram(), doubleValue: observedCarbs.doubleValue(for: .gram()) + absorbedCarbs.last!.observedCarbs.doubleValue(for: .gram()))
        }
        
        for absorbed in absorbedCarbs {
            absorbed.estimateParametersForEntry(glucose: historicalGlucose, insulin: historicalInsulinEffect, carbs: historicalCarbEffect, counteraction: insulinCounteractionEffects)
        }

        // dm61 construct no-carb segments
        noCarbs = []
        guard
            let startNoCarbs = startEstimation,
            let endNoCarbs = endEstimation else {
                return
        }
        var startNoCarbsSegment = startNoCarbs
        var endNoCarbsSegment = endNoCarbs
        for absorbed in absorbedCarbs {
            endNoCarbsSegment = absorbed.startDate
            let insulinEffectNoCarbs = historicalInsulinEffect?.filterDateRange(startNoCarbsSegment.addingTimeInterval(.minutes(-5.0)), endNoCarbsSegment) ?? []
            let glucoseNoCarbs = historicalGlucose.filter { (value) -> Bool in
                if value.startDate < startNoCarbsSegment {
                    return false
                }
                if value.startDate > endNoCarbsSegment {
                    return false
                }
                return true
            }
            if glucoseNoCarbs.count > 5 {
                let noCarbsSegment = NoCarbs(startDate: startNoCarbsSegment, endDate: endNoCarbsSegment, glucose: glucoseNoCarbs, insulinEffect: insulinEffectNoCarbs)
                noCarbs.append(noCarbsSegment)
            }
            startNoCarbsSegment = absorbed.endDate
        }
        endNoCarbsSegment = endNoCarbs
        let insulinEffectNoCarbs = historicalInsulinEffect?.filterDateRange(startNoCarbsSegment.addingTimeInterval(.minutes(-5.0)), endNoCarbsSegment) ?? []
        let glucoseNoCarbs = historicalGlucose.filter { (value) -> Bool in
            if value.startDate < startNoCarbsSegment {
                return false
            }
            if value.startDate > endNoCarbsSegment {
                return false
            }
            return true
        }
        if glucoseNoCarbs.count > 5 {
            let noCarbsSegment = NoCarbs(startDate: startNoCarbsSegment, endDate: endNoCarbsSegment, glucose: glucoseNoCarbs, insulinEffect: insulinEffectNoCarbs)
            noCarbs.append(noCarbsSegment)
        }
        
        for noCarbsSegment in noCarbs {
            noCarbsSegment.estimateParametersNoCarbs()
        }
        
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

        guard let basalRates = basalRateScheduleApplyingOverrideHistory else {
            throw LoopError.configurationError(.basalRateSchedule)
        }

        let pendingTempBasalInsulin: Double
        let date = Date()

        if let lastTempBasal = lastTempBasal, lastTempBasal.endDate > date {
            let normalBasalRate = basalRates.value(at: date)
            let remainingTime = min(lastTempBasal.endDate.timeIntervalSince(date), TimeInterval.minutes(5))  // MB Exlude pending basal except for about 5 min (1 loop) worth
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

        // dm61 hyperLoop
        effects.append(self.fractionalZeroTempEffect)
        if inputs.contains(.zeroTemp) {
            effects.append(self.remainingZeroTempEffect)
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

    /// Generates a correction effect based on how large the discrepancy is between the current glucose and its model predicted value. If integral retrospective correction is enabled, the retrospective correction effect is based on a timeline of past discrepancies.
    ///
    /// - Throws: LoopError.missingDataError
    private func updateRetrospectiveGlucoseEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        // Get carb effects, otherwise clear effect and throw error
        guard let carbEffects = self.carbEffect else {
            retrospectiveGlucoseDiscrepancies = nil
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.carbEffect)
        }

        // Get most recent glucose, otherwise clear effect and throw error
        guard let glucose = self.glucoseStore.latestGlucose else {
            retrospectiveGlucoseEffect = []
            totalRetrospectiveCorrection = nil
            throw LoopError.missingDataError(.glucose)
        }

        // Get timeline of glucose discrepancies
        retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects, withUniformInterval: carbStore.delta)

        // Calculate retrospective correction
        if settings.integralRetrospectiveCorrectionEnabled {
            // Integral retrospective correction, if enabled
            retrospectiveGlucoseEffect = integralRC.updateRetrospectiveCorrectionEffect(glucose, retrospectiveGlucoseDiscrepanciesSummed)
            totalRetrospectiveCorrection = integralRC.totalGlucoseCorrectionEffect
        } else {
            // Standard retrospective correction
            retrospectiveGlucoseEffect = standardRC.updateRetrospectiveCorrectionEffect(glucose, retrospectiveGlucoseDiscrepanciesSummed)
            totalRetrospectiveCorrection = standardRC.totalGlucoseCorrectionEffect
        }
    }

    /// Generates a glucose prediction effect of zero temping over duration of insulin action starting at current date
    ///
    /// - Throws: LoopError.configurationError
    private func updateZeroTempEffect() throws {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        // Get settings, otherwise clear effect and throw error
        guard
            let insulinModel = insulinModelSettings?.model,
            let insulinSensitivity = insulinSensitivitySchedule,
            let basalRateSchedule = basalRateSchedule
            else {
                zeroTempEffect = []
                throw LoopError.configurationError(.generalSettings)
        }

        let insulinActionDuration = insulinModel.effectDuration

        // use the new LoopKit method tempBasalGlucoseEffects to generate zero temp effects
        let startZeroTempDose = Date()
        let endZeroTempDose = startZeroTempDose.addingTimeInterval(insulinActionDuration)
        let zeroTemp = DoseEntry(type: .tempBasal, startDate: startZeroTempDose, endDate: endZeroTempDose, value: 0.0, unit: DoseUnit.unitsPerHour)
        zeroTempEffect = zeroTemp.tempBasalGlucoseEffects(insulinModel: insulinModel, insulinSensitivity: insulinSensitivity, basalRateSchedule: basalRateSchedule).filterDateRange(startZeroTempDose, endZeroTempDose)
        
        let hyperLoopAgressiveness = 0.75
        fractionalZeroTempEffect = zeroTempEffectFraction(glucoseEffect: zeroTempEffect, fraction: hyperLoopAgressiveness)
        remainingZeroTempEffect = zeroTempEffectFraction(glucoseEffect: zeroTempEffect, fraction: 1.0 - hyperLoopAgressiveness)
    }

    /// Generates a fraction of glucose effect of zero temping
    ///
    private func zeroTempEffectFraction(glucoseEffect: [GlucoseEffect], fraction: Double) -> [GlucoseEffect] {
        var fractionalEffect: [GlucoseEffect] = []
        for effect in glucoseEffect {
            let scaledEffect = GlucoseEffect(startDate: effect.startDate, quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: fraction * effect.quantity.doubleValue(for: .milligramsPerDeciliter)))
            fractionalEffect.append(scaledEffect)
        }
        return fractionalEffect
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

        let pumpStatusDate = doseStore.lastAddedPumpData

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
            let insulinSensitivity = insulinSensitivityScheduleApplyingOverrideHistory,
            let basalRates = basalRateScheduleApplyingOverrideHistory,
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

        let rateRounder = { (_ rate: Double) in
            return self.delegate?.loopDataManager(self, roundBasalRate: rate) ?? rate
        }

        let tempBasal = predictedGlucose.recommendedTempBasal(
            to: glucoseTargetRange,
            suspendThreshold: currentSuspendThreshold(), // settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            basalRates: basalRates,
            maxBasalRate: maxBasal,
            lastTempBasal: lastTempBasal,
            rateRounder: rateRounder,
            isBasalRateScheduleOverrideActive: settings.scheduleOverride?.isBasalRateScheduleOverriden(at: startDate) == true
        )

        if let temp = tempBasal {
            recommendedTempBasal = (recommendation: temp, date: startDate)
        } else {
            recommendedTempBasal = nil
        }

        let pendingInsulin = try self.getPendingInsulin()

        let volumeRounder = { (_ units: Double) in
            return self.delegate?.loopDataManager(self, roundBolusVolume: units) ?? units
        }

        let recommendation = predictedGlucose.recommendedBolus(
            to: glucoseTargetRange,
            suspendThreshold: currentSuspendThreshold(),  // settings.suspendThreshold?.quantity,
            sensitivity: insulinSensitivity,
            model: model,
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus,
            volumeRounder: volumeRounder
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

/// Describes retrospective correction interface
protocol RetrospectiveCorrection {
    /// Standard effect duration, nominally set to 60 min
    var standardEffectDuration: TimeInterval { get }

    /// Overall retrospective correction effect
    var totalGlucoseCorrectionEffect: HKQuantity? { get }

    /**
     Calculates overall correction effect based on timeline of discrepancies, and updates glucoseCorrectionEffect

     - Parameters:
        - glucose: Most recent glucose
        - retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies

     - Returns:
        - retrospectiveGlucoseEffect: Glucose correction effects
     */
    func updateRetrospectiveCorrectionEffect(_ glucose: GlucoseValue, _ retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?) -> [GlucoseEffect]
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
            
            /*
            do {
                try self.updateParameterEstimates()
            } catch let error {
                updateError = error
            }*/

            handler(self, LoopStateView(loopDataManager: self, updateError: updateError))
        }
    }
    
    /// Executes a closure with access to the current state of the loop and estimated parameters
    ///
    /// This operation is performed asynchronously and the closure will be executed on an arbitrary background queue.
    ///
    /// - Parameter handler: A closure called when the state is ready
    /// - Parameter manager: The loop manager
    /// - Parameter state: The current state of the manager. This is invalid to access outside of the closure.
    func getParameterEstimationLoopState(_ handler: @escaping (_ manager: LoopDataManager, _ state: LoopState) -> Void) {
        dataAccessQueue.async {
            var updateError: Error?
            
            do {
                try self.update()
            } catch let error {
                updateError = error
            }
            
            do {
                try self.updateParameterEstimates()
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
                // dm61 mse calculation
                "Latest glucose value: \(self.currentGlucoseValue)",
                "Predicted glucose value: \(self.previouslyPredictedGlucoseValue)",
                "n: \(self.nMSE)",
                "MeanSquareError: \(self.meanSquareError)\n",
                // dm61
                "settings: \(String(reflecting: manager.settings))",

                "insulinCounteractionEffects: [",
                "* GlucoseEffectVelocity(start, end, mg/dL/min)",
                manager.insulinCounteractionEffects.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate), \(entry.quantity.doubleValue(for: GlucoseEffectVelocity.unit))\n")
                }),
                "]",
                
                // dm61 historical data for parameter estimation
                // dm61 observed carb effects
                "historicalCarbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.historicalCarbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate),  \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                // dm61 insulin effects
                "historicalInsulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.historicalInsulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate),  \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                // dm61 historical glucose data (just to check), may not need
                "historicalGlucose: [",
                "* HistoricalGlucoseValues(start, mg/dL)",
                manager.historicalGlucose.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                // dm61 statuses of carb entries
                "\n carbStatuses: \(manager.carbStatuses) \n",
                "\n carbStatusesForEstimation: \(manager.carbStatusesCompleted) \n",
                "absorbedEntries: [",
                "* Carb entry (start, end, entered [g], obserbed [g]) followed by effects: ",
                manager.absorbedCarbs.reduce(into: "", { (entries, entry) in
                    entries.append("* \(entry.startDate), \(entry.endDate),  \(entry.enteredCarbs.doubleValue(for: .gram())), \(entry.observedCarbs.doubleValue(for: .gram())), Glucose:  \(String(describing: entry.startGlucose?.startDate)), \(String(describing: entry.startGlucose?.quantity.doubleValue(for: .milligramsPerDeciliter))),  \(String(describing: entry.endGlucose?.startDate)), \(String(describing: entry.endGlucose?.quantity.doubleValue(for: .milligramsPerDeciliter))), Insulin effects: ,\(String(describing: entry.startInsulinEffect?.startDate)), \(String(describing: entry.startInsulinEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), \(String(describing: entry.endInsulinEffect?.startDate)), \(String(describing: entry.endInsulinEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), Carb effects: \(String(describing: entry.startCarbEffect?.startDate)), \(String(describing: entry.startCarbEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), \(String(describing: entry.endCarbEffect?.startDate)), \(String(describing: entry.endCarbEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), Counteraction effects: \(String(describing: entry.counteractionEffect?.doubleValue(for: .milligramsPerDeciliter))), \n *** ISF multiplier: \(String(describing: entry.insulinSensitivityMultiplier)), \n *** CR multiplier: \(String(describing: entry.carbRatioMultiplier)), \n *** CSF multiplier: \(String(describing: entry.carbSensitivityMultiplier)) \n")
                }),
                "]\n",

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
                "",
                "retrospectiveGlucoseEffect: \(manager.retrospectiveGlucoseEffect)",
                "",
                "zeroTempEffect: \(manager.zeroTempEffect)",
                "",
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

            self.integralRC.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")
            }

            self.carbCorrection.generateDiagnosticReport { (report) in
                entries.append(report)
                entries.append("")
            }

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
    
    
    /// Generates a parameter estimation report
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateParameterEstimationReport(_ completion: @escaping (_ report: String) -> Void) {
        getParameterEstimationLoopState { (manager, state) in
            
            let dateFormatter = DateFormatter()
            dateFormatter.timeStyle = .medium
            dateFormatter.dateStyle = .medium
            let userCalendar = Calendar.current
            var defaultDateComponents = DateComponents()
            var defaultDate = Date()
            defaultDateComponents.year = 1000
            if let date = userCalendar.date(from: defaultDateComponents) {
                defaultDate = date
            }
            
            let entries: [String] = [
                "Estimation data start: \(dateFormatter.string(from: manager.startEstimation ?? defaultDate))",
                "\n Estimation data end: \(dateFormatter.string(from: manager.endEstimation ?? defaultDate))",
                "\n Estimates based on absorbed entries: [",
                "* Carb entry (start, end, entered [g], observed [g]) followed by glucose effects and estimated parameter mutipliers:",
                manager.absorbedCarbs.reduce(into: "", { (entries, entry) in
                    entries.append("\n ---------- \n \(dateFormatter.string(from: entry.startDate)), \(dateFormatter.string(from: entry.endDate)),  \(entry.enteredCarbs.doubleValue(for: .gram())), \(entry.observedCarbs.doubleValue(for: .gram())), Glucose:  \(String(describing: entry.startGlucose?.startDate)), \(String(describing: entry.startGlucose?.quantity.doubleValue(for: .milligramsPerDeciliter))),  \(String(describing: entry.endGlucose?.startDate)), \(String(describing: entry.endGlucose?.quantity.doubleValue(for: .milligramsPerDeciliter))), Insulin effects: \(String(describing: entry.startInsulinEffect?.startDate)), \(String(describing: entry.startInsulinEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), \(String(describing: entry.endInsulinEffect?.startDate)), \(String(describing: entry.endInsulinEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), Carb effects: \(String(describing: entry.startCarbEffect?.startDate)), \(String(describing: entry.startCarbEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), \(String(describing: entry.endCarbEffect?.startDate)), \(String(describing: entry.endCarbEffect?.quantity.doubleValue(for: .milligramsPerDeciliter))), Counteraction effects: \(String(describing: entry.counteractionEffect?.doubleValue(for: .milligramsPerDeciliter))), \n *** ISF multiplier: \(String(describing: entry.insulinSensitivityMultiplier)), \n *** CR multiplier: \(String(describing: entry.carbRatioMultiplier)), \n *** CSF multiplier: \(String(describing: entry.carbSensitivityMultiplier)) \n")
                }),
                "]\n",
                
                "\n Estimates based on no-carb intervals: [",
                manager.noCarbs.reduce(into: "", { (entries, entry) in
                    entries.append("\n ---------- \n \(dateFormatter.string(from: entry.startDate)), \(dateFormatter.string(from: entry.endDate)), \(String(describing: entry.regressionStatistics.slope)), \(String(describing: entry.regressionStatistics.slopeStandardError)),\(String(describing: entry.regressionStatistics.intercept)), \(String(describing: entry.regressionStatistics.interceptStandardError)), \(String(describing: entry.regressionStatistics.rSquared)), \(String(describing: entry.regressionStatistics.nSamples)) \n *** ISF multiplier: \(String(describing: entry.insulinSensitivityMultiplier)), \n *** Bias effect: \(String(describing: entry.biasEffect)) \n")
                }),
                "]\n",
                
                // dm61 no-carb sequencies
                "no-carb sequencies: [",
                "* start, end, glucose-count, insulin-eff-count",
                manager.noCarbs.reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)),  \(dateFormatter.string(from: entry.endDate)), \(String(describing: entry.glucose?.count)), \(String(describing: entry.insulinEffect?.count)), \n\(String(describing: entry.deltaGlucose)), \n\(String(describing: entry.deltaInsulinEffect)) \n")
                }),
                "]",

                // dm61 statuses of carb entries
                "\n carbStatuses: \(manager.carbStatuses) \n",
                "\n carbStatusesForEstimation: \(manager.carbStatusesCompleted) \n",
                
                // dm61 historical data for parameter estimation
                // dm61 observed carb effects
                "historicalCarbEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.historicalCarbEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)),  \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                // dm61 historical insulin effects
                "historicalInsulinEffect: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.historicalInsulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)),  \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                // dm61 historical glucose data (just to check), may not need
                "historicalGlucose: [",
                "* HistoricalGlucoseValues(start, mg/dL)",
                manager.historicalGlucose.reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]",
                
                "retrospectiveGlucoseDiscrepancies: [",
                "* GlucoseEffect(start, mg/dL)",
                (manager.retrospectiveGlucoseDiscrepancies ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                }),
                "]"
                
            ]
            completion(entries.joined(separator: "\n"))
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

    /// Asks the delegate to round a recommended basal rate to a supported rate
    ///
    /// - Parameters:
    ///   - rate: The recommended rate in U/hr
    /// - Returns: a supported rate of delivery in Units/hr. The rate returned should not be larger than the passed in rate.
    func loopDataManager(_ manager: LoopDataManager, roundBasalRate unitsPerHour: Double) -> Double

    /// Asks the delegate to round a recommended bolus volume to a supported volume
    ///
    /// - Parameters:
    ///   - units: The recommended bolus in U
    /// - Returns: a supported bolus volume in U. The volume returned should not be larger than the passed in rate.
    func loopDataManager(_ manager: LoopDataManager, roundBolusVolume units: Double) -> Double
}

extension DoseStore {
    var lastAddedPumpData: Date {
        return max(lastReservoirValue?.startDate ?? .distantPast, lastAddedPumpEvents)
    }
}


private extension TemporaryScheduleOverride {
    func isBasalRateScheduleOverriden(at date: Date) -> Bool {
        guard isActive(at: date), let basalRateMultiplier = settings.basalRateMultiplier else {
            return false
        }
        return abs(basalRateMultiplier - 1.0) >= .ulpOfOne
    }
// dm61 parameter estimation wip
class AbsorbedCarbs {
    var startDate: Date
    var endDate: Date
    var enteredCarbs: HKQuantity
    var observedCarbs: HKQuantity
    var startInsulinEffect: GlucoseEffect?
    var endInsulinEffect: GlucoseEffect?
    var startCarbEffect: GlucoseEffect?
    var endCarbEffect: GlucoseEffect?
    var startGlucose: GlucoseValue?
    var endGlucose: GlucoseValue?
    var counteractionEffect: HKQuantity?
    var insulinSensitivityMultiplier: Double?
    var carbSensitivityMultiplier: Double?
    var carbRatioMultiplier: Double?
    
    init(startDate: Date, endDate: Date, enteredCarbs: HKQuantity, observedCarbs: HKQuantity) {
        self.startDate = startDate
        self.endDate = endDate
        self.enteredCarbs = enteredCarbs
        self.observedCarbs = observedCarbs
    }
    
    func estimateParametersForEntry(glucose: [GlucoseValue]?, insulin: [GlucoseEffect]?, carbs: [GlucoseEffect]?, counteraction: [GlucoseEffectVelocity]?) {
        
        let unit = HKUnit.milligramsPerDeciliter
        let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
        
        self.startGlucose = glucose?.first(where: { $0.startDate >= self.startDate })
        self.endGlucose = glucose?.first(where: { $0.startDate >= self.endDate })
        self.startInsulinEffect = insulin?.first(where: { $0.startDate >= self.startDate })
        self.endInsulinEffect = insulin?.first(where: { $0.startDate >= self.endDate })
        self.startCarbEffect = carbs?.first(where: { $0.startDate >= self.startDate })
        self.endCarbEffect = carbs?.first(where: { $0.startDate >= self.endDate })
        guard let observedCounteraction = counteraction?.filterDateRange(self.startDate, self.endDate) else {
            return
        }
        var effect: Double = 0.0
        for glucoseVelocity in observedCounteraction {
            let effectTime = glucoseVelocity.endDate.timeIntervalSince(glucoseVelocity.startDate)
            effect += max(glucoseVelocity.quantity.doubleValue(for: velocityUnit), 0.0) * effectTime.minutes
        }
        self.counteractionEffect = HKQuantity(unit: unit, doubleValue: effect)
        
        guard
            let startGlucose = self.startGlucose?.quantity.doubleValue(for: unit),
            let endGlucose = self.endGlucose?.quantity.doubleValue(for: unit),
            let startInsulin = self.startInsulinEffect?.quantity.doubleValue(for: unit),
            let endInsulin = self.endInsulinEffect?.quantity.doubleValue(for: unit),
            startInsulin > endInsulin,
            self.enteredCarbs.doubleValue(for: .gram()) > 0.0
        else {
            return
        }
        
        //dm61 May 25 notes: isf and cr multipliers calculated so that observed carbs = entered carbs while limiting isf multiplier
        let ratioObserved = self.observedCarbs.doubleValue(for: .gram()) / self.enteredCarbs.doubleValue(for: .gram())
        let deltaGlucose = endGlucose - startGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        // ? let deltaGlucoseCorrection = min(max(1.0 - deltaGlucose / deltaGlucoseInsulin, 0.81), 1.21)
        let deltaGlucoseCorrection = 1.0
        let isfCorrection = ratioObserved * deltaGlucoseCorrection
        self.insulinSensitivityMultiplier = min(max(isfCorrection.squareRoot(), 0.9), 1.1)
        guard
            let isfMultiplier = self.insulinSensitivityMultiplier
            else {
                return
        }
        self.carbRatioMultiplier = min(max(isfMultiplier * (deltaGlucose + deltaGlucoseInsulin) / (ratioObserved * (deltaGlucose + isfMultiplier * deltaGlucoseInsulin)), 0.8), 1.2)
        guard
            let crMultiplier = self.carbRatioMultiplier
            else {
                return
        }
        self.carbSensitivityMultiplier = isfMultiplier / crMultiplier
    }
}

// dm61 parameter estimation wip
class NoCarbs {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue]?
    var insulinEffect: [GlucoseEffect]?
    var deltaGlucose: [Double]?
    var deltaInsulinEffect: [Double]?
    var insulinSensitivityMultiplier: Double?
    var biasEffect: Double?
    var basalMultiplier: Double?
    var regressionStatistics: RegressionStatistics = RegressionStatistics()
    
    init(startDate: Date, endDate: Date, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect]) {
        self.startDate = startDate
        self.endDate = endDate
        self.insulinEffect = insulinEffect
        self.glucose = glucose
    }
    
    func estimateParametersNoCarbs() {
        self.calculateDeltas()
        guard
            let deltaInsulinEffect = self.deltaInsulinEffect,
            let deltaGlucose = self.deltaGlucose else {
                return
        }
        let noCarbsFit = linearRegression(deltaInsulinEffect, deltaGlucose)
        self.biasEffect = noCarbsFit(0.0)
        self.insulinSensitivityMultiplier = noCarbsFit(1.0) - noCarbsFit(0.0)
    }
    
    private func calculateDeltas() {
        
        let unit = HKUnit.milligramsPerDeciliter
        
        guard
            let firstGlucose = self.glucose?.first else {
                return
        }
        self.deltaGlucose = []
        self.deltaInsulinEffect = []
        var previousGlucose = firstGlucose
        for glucose in self.glucose?.dropFirst() ?? [] {
            let deltaGlucose = glucose.quantity.doubleValue(for: unit) - previousGlucose.quantity.doubleValue(for: unit)
            guard
                let currentInsulinEffect = self.insulinEffect?.closestPriorToDate(glucose.startDate),
                let previousInsulinEffect = self.insulinEffect?.closestPriorToDate(previousGlucose.startDate)
                else {
                    for effect in self.insulinEffect ?? [] {
                        print("\(effect.startDate): \(effect.quantity.doubleValue(for: unit))")
                    }
                    continue
            }
            self.deltaGlucose?.append(deltaGlucose)
            let deltaInsulinEffect = currentInsulinEffect.quantity.doubleValue(for: unit) - previousInsulinEffect.quantity.doubleValue(for: unit)
            self.deltaInsulinEffect?.append(deltaInsulinEffect)
            previousGlucose = glucose
        }
        
    }
    
    private func average(_ input: [Double]) -> Double {
        return input.reduce(0, +) / Double(input.count)
    }
    
    private func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        return zip(a,b).map(*)
    }
    
    private func dotProduct(_ a: [Double], _ b: [Double]) -> Double {
        let c = multiply(a, b)
        return c.reduce(0, +)
    }
    
    private func scale(_ input: [Double], _ scale: Double) -> [Double] {
        return input.map{ $0 * scale }
    }
    
    private func addConstant(_ input: [Double], _ constant: Double) -> [Double] {
        return input.map{ $0 + constant }
    }
    
    private func add(_ a: [Double], _ b: [Double]) -> [Double] {
        return zip(a,b).map(+)
    }
    
    private func linearRegression(_ xs: [Double], _ ys: [Double]) -> (Double) -> Double {
        let sum1 = average(multiply(ys, xs)) - average(xs) * average(ys)
        let sum2 = average(multiply(xs, xs)) - pow(average(xs), 2)
        let slope = sum1 / sum2
        let intercept = average(ys) - slope * average(xs)
        let n = xs.count
        let err = addConstant(add(ys, scale(xs, -slope)), -intercept)
        let degreesOfFreedom = Double(n - 2)
        let xAverage = average(xs)
        let yAverage = average(ys)
        let xDevs = addConstant(xs, -xAverage)
        let slopeSE = ( dotProduct(err, err) / degreesOfFreedom / dotProduct(xDevs, xDevs)).squareRoot()
        let interceptSE = slopeSE * (dotProduct(xs, xs) / Double(n)).squareRoot()
        let rSquaredNumerator = pow(average(multiply(xs, ys)) - xAverage * yAverage, 2)
        let rSquaredDenominatorX = average(multiply(xs, xs)) - pow(xAverage, 2)
        let rSquaredDenominatorY = average(multiply(ys, ys)) - pow(yAverage, 2)
        let rSquared = rSquaredNumerator / rSquaredDenominatorX / rSquaredDenominatorY
        self.regressionStatistics.slope = slope
        self.regressionStatistics.slopeStandardError = slopeSE
        self.regressionStatistics.intercept = intercept
        self.regressionStatistics.interceptStandardError = interceptSE
        self.regressionStatistics.rSquared = rSquared
        self.regressionStatistics.nSamples = n
        return { x in intercept + slope * x }
    }
    
}

class RegressionStatistics {
    var slope: Double?
    var intercept: Double?
    var slopeStandardError: Double?
    var interceptStandardError: Double?
    var rSquared: Double?
    var nSamples: Int?
}
