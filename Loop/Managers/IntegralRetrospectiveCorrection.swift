//
//  IntegralRetrospectiveCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 10/21/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

/**
    Integral Retrospective Correction (IRC) calculates a correction effect in glucose prediction based on a timeline of past discrepancies between observed glucose movement and movement expected based on insulin and carb models. Integral retrospective correction acts as a proportional-integral-differential (PID) controller aimed at reducing modeling errors in glucose prediction.
 
    In the above summary, "discrepancy" is a difference between the actual glucose and the model predicted glucose over retrospective correction grouping interval (set to 30 min in LoopSettings), whereas "past discrepancies" refers to a timeline of discrepancies computed over retrospective correction integration interval (set to 180 min in Loop Settings).
 
 */
class IntegralRetrospectiveCorrection : RetrospectiveCorrection {

    /// RetrospectiveCorrection protocol variables
    /// Standard effect duration
    let standardEffectDuration: TimeInterval
    /// Overall retrospective correction effect
    var totalGlucoseCorrectionEffect: HKQuantity?
    
    /**
     Integral retrospective correction parameters:
     - currentDiscrepancyGain: Standard retrospective correction gain
     - persistentDiscrepancyGain: Gain for persistent long-term modeling errors, must be greater than or equal to currentDiscrepancyGain
     - correctionTimeConstant: How fast integral effect accumulates in response to persistent errors
     - differentialGain: Differential effect gain
     - delta: Glucose sampling time interval (5 min)
     - maximumCorrectionEffectDuration: Maximum duration of the correction effect in glucose prediction
    */
    static let currentDiscrepancyGain: Double = 1.0
    static let persistentDiscrepancyGain: Double = 4.0
    static let correctionTimeConstant: TimeInterval = TimeInterval(minutes: 90.0)
    static let differentialGain: Double = 2.0
    static let delta: TimeInterval = TimeInterval(minutes: 5.0)
    static let maximumCorrectionEffectDuration: TimeInterval = TimeInterval(minutes: 240.0)
    
    /// Initialize computed integral retrospective correction parameters
    static let integralForget: Double = exp( -delta.minutes / correctionTimeConstant.minutes )
    static let integralGain: Double = ((1 - integralForget) / integralForget) *
        (persistentDiscrepancyGain - currentDiscrepancyGain)
    static let proportionalGain: Double = currentDiscrepancyGain - integralGain
    
    /// All math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    
    /// State variables reported in diagnostic issue report
    private var recentDiscrepancyValues: [Double] = []
    private var integralCorrectionEffectDuration: TimeInterval?
    private var proportionalCorrection: Double = 0.0
    private var integralCorrection: Double = 0.0
    private var differentialCorrection: Double = 0.0
    private var currentDate: Date = Date()
    private var ircStatus: String = "-"
    
    /**
     Initialize integral retrospective correction settings based on current values of user settings
     
     - Parameters:
        - settings: User settings
        - insulinSensitivity: User insulin sensitivity schedule
        - basalRates: User basal rate schedule
     
     - Returns: Integral Retrospective Correction customized with controller parameters and user settings
    */
    init(_ standardCorrectionDuration: TimeInterval) {
        self.standardEffectDuration = standardCorrectionDuration
    }
    
    /**
     Calculates overall correction effect based on timeline of discrepancies, and updates glucoseCorrectionEffect
     
     - Parameters:
     - glucose: Most recent glucose
     - retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies
     
     - Returns:
     - totalRetrospectiveCorrection: Overall glucose effect
     */
    func updateRetrospectiveCorrectionEffect(_ glucose: GlucoseValue, _ retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?) -> [GlucoseEffect] {
        
        // Loop settings relevant for calculation of effect limits
        let settings = UserDefaults.appGroup?.loopSettings ?? LoopSettings()
        let insulinSensitivity = UserDefaults.appGroup?.insulinSensitivitySchedule
        let basalRates = UserDefaults.appGroup?.basalRateSchedule
        currentDate = Date()
        
        // Last discrepancy should be recent, otherwise clear the effect and return
        let glucoseDate = glucose.startDate
        var glucoseCorrectionEffect: [GlucoseEffect] = []
        guard let currentDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last,
            glucoseDate.timeIntervalSince(currentDiscrepancy.endDate) <= settings.recencyInterval
            else {
                ircStatus = "discrepancy not available, effect not computed."
                totalGlucoseCorrectionEffect = nil
                return( [] )
        }
        
        // Default values if we are not able to calculate integral retrospective correction
        ircStatus = "defaulted to standard RC, past discrepancies or user settings not available."
        let currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        var scaledCorrection = currentDiscrepancyValue
        totalGlucoseCorrectionEffect = HKQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        integralCorrectionEffectDuration = standardEffectDuration
        
        // Calculate integral retrospective correction if past discrepancies over integration interval are available and if user settings are available
        if  let pastDiscrepancies = retrospectiveGlucoseDiscrepanciesSummed?.filterDateRange(glucoseDate.addingTimeInterval(-settings.retrospectiveCorrectionIntegrationInterval), glucoseDate),
            let sensitivity = insulinSensitivity,
            let basals = basalRates,
            let correctionRange = settings.glucoseTargetRangeSchedule {
            
            ircStatus = "effect computed successfully."
            
            // To reduce response delay, integral retrospective correction is computed over an array of recent contiguous discrepancy values having the same sign as the latest discrepancy value
            recentDiscrepancyValues = []
            var nextDiscrepancy = currentDiscrepancy
            let currentDiscrepancySign = currentDiscrepancy.quantity.doubleValue(for: unit).sign
            for pastDiscrepancy in pastDiscrepancies.reversed() {
                let pastDiscrepancyValue = pastDiscrepancy.quantity.doubleValue(for: unit)
                if (pastDiscrepancyValue.sign == currentDiscrepancySign &&
                    nextDiscrepancy.endDate.timeIntervalSince(pastDiscrepancy.endDate)
                    <= settings.recencyInterval &&
                    abs(pastDiscrepancyValue) >= 0.1)
                {
                    recentDiscrepancyValues.append(pastDiscrepancyValue)
                    nextDiscrepancy = pastDiscrepancy
                } else {
                    break
                }
            }
            recentDiscrepancyValues = recentDiscrepancyValues.reversed()
     
            let currentSensitivity = sensitivity.quantity(at: glucoseDate).doubleValue(for: unit)
            let currentBasalRate = basals.value(at: glucoseDate)
            let correctionRangeMin = correctionRange.minQuantity(at: glucoseDate).doubleValue(for: unit)
            let correctionRangeMax = correctionRange.maxQuantity(at: glucoseDate).doubleValue(for: unit)
            let latestGlucoseValue = glucose.quantity.doubleValue(for: unit) // most recent glucose
            
            // Safety limit for (+) integral effect. The limit is set to a larger value if the current blood glucose is further away from the correction range because we have more time available for corrections
            let glucoseError = latestGlucoseValue - correctionRangeMax
            let zeroTempEffect = abs(currentSensitivity * currentBasalRate)
            let integralEffectPositiveLimit = min(max(glucoseError, 1.0 * zeroTempEffect), 4.0 * zeroTempEffect)
            
            // Limit for (-) integral effect: glucose prediction reduced by no more than 10 mg/dL below the correction range minimum
            let integralEffectNegativeLimit = -max(10.0, latestGlucoseValue - correctionRangeMin)
            
            // Integral effect math
            integralCorrection = 0.0
            var integralCorrectionEffectMinutes = standardEffectDuration.minutes - 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            for discrepancy in recentDiscrepancyValues {
                integralCorrection =
                    IntegralRetrospectiveCorrection.integralForget * integralCorrection +
                    IntegralRetrospectiveCorrection.integralGain * discrepancy
                integralCorrectionEffectMinutes += 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            }
            // Limits applied to integral correction effect and effect duration
            integralCorrection = min(max(integralCorrection, integralEffectNegativeLimit), integralEffectPositiveLimit)
            integralCorrectionEffectMinutes = min(integralCorrectionEffectMinutes, IntegralRetrospectiveCorrection.maximumCorrectionEffectDuration.minutes)
            
            // Differential effect math
            var differentialDiscrepancy: Double = 0.0
            if recentDiscrepancyValues.count > 1 {
                let previousDiscrepancyValue = recentDiscrepancyValues[recentDiscrepancyValues.count - 2]
                differentialDiscrepancy = currentDiscrepancyValue - previousDiscrepancyValue
            }
            
            // Overall glucose effect calculated as a sum of propotional, integral and differential effects
            proportionalCorrection = IntegralRetrospectiveCorrection.proportionalGain * currentDiscrepancyValue
            differentialCorrection = IntegralRetrospectiveCorrection.differentialGain * differentialDiscrepancy
            let totalCorrection = proportionalCorrection + integralCorrection + differentialCorrection
            totalGlucoseCorrectionEffect = HKQuantity(unit: unit, doubleValue: totalCorrection)
            integralCorrectionEffectDuration = TimeInterval(minutes: integralCorrectionEffectMinutes)
            
            // correction value scaled to account for extended effect duration
            scaledCorrection = totalCorrection * standardEffectDuration.minutes / integralCorrectionEffectDuration!.minutes
        }
        
        let retrospectionTimeInterval = currentDiscrepancy.endDate.timeIntervalSince(currentDiscrepancy.startDate)
        let discrepancyTime = max(retrospectionTimeInterval, settings.retrospectiveCorrectionGroupingInterval)
        let velocity = HKQuantity(unit: unit.unitDivided(by: .second()), doubleValue: scaledCorrection / discrepancyTime)
        
        // Update array of glucose correction effects
        glucoseCorrectionEffect = glucose.decayEffect(atRate: velocity, for: integralCorrectionEffectDuration!)
        
        // Return glucose correction effects
        return( glucoseCorrectionEffect )
    }
    
}

extension IntegralRetrospectiveCorrection {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        let settings = UserDefaults.appGroup?.loopSettings ?? LoopSettings()
        var report: [String] = [
            "## IntegralRetrospectiveCorrection",
            "",
            "Enabled: \(settings.integralRetrospectiveCorrectionEnabled)",
            "Last updated: \(currentDate)",
            "Status: \(ircStatus)",
            "currentDiscrepancyGain: \(IntegralRetrospectiveCorrection.currentDiscrepancyGain)",
            "persistentDiscrepancyGain: \(IntegralRetrospectiveCorrection.persistentDiscrepancyGain)",
            "correctionTimeConstant [min]: \(IntegralRetrospectiveCorrection.correctionTimeConstant.minutes)",
            "proportionalGain: \(IntegralRetrospectiveCorrection.proportionalGain)",
            "integralForget: \(IntegralRetrospectiveCorrection.integralForget)",
            "integralGain: \(IntegralRetrospectiveCorrection.integralGain)",
            "differentialGain: \(IntegralRetrospectiveCorrection.differentialGain)",
            "Integration performed over \(recentDiscrepancyValues.count) most recent discrepancies having the same sign as the latest discrepancy value. Earliest-to-most-recent recentDiscrepancyValues [mg/dL]: \(recentDiscrepancyValues)",
            "proportionalCorrection [mg/dL]: \(proportionalCorrection)",
            "integralCorrection [mg/dL]: \(integralCorrection)",
            "differentialCorrection [mg/dL]: \(differentialCorrection)",
            "totalGlucoseCorrectionEffect: \(String(describing: totalGlucoseCorrectionEffect))",
            "integralCorrectionEffectDuration [min]: \(String(describing: integralCorrectionEffectDuration?.minutes))"
        ]
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}
