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

/**
    Integral Retrospective Correction (IRC) calculates a correction effect in glucose prediction based on a timeline of past discrepancies between observed glucose movement and movement expected based on insulin and carb models. Integral retrospective correction acts as a proportional-integral-differential (PID) controller aimed at reducing modeling errors in glucose prediction.
 
    In the above summary, "discrepancy" is a difference between the actual glucose and the model predicted glucose over retrospective correction grouping interval (set to 30 min in LoopSettings), whereas "past discrepancies" refers to a timeline of discrepancies computed over retrospective correction integration interval (set to 180 min in Loop Settings).
 
 */
class IntegralRetrospectiveCorrection {
    
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
    static let persistentDiscrepancyGain: Double = 5.0
    static let correctionTimeConstant: TimeInterval = TimeInterval(minutes: 120.0)
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
    
    /// User settings relevant for calculation of effect limits
    private let settings: LoopSettings
    private let insulinSensitivity: InsulinSensitivitySchedule?
    private let basalRates: BasalRateSchedule?
    
    /// State variables reported in diagnostic issue report
    private var recentDiscrepancyValues: [Double] = []
    private var totalRetrospectiveCorrection: HKQuantity
    private var integralCorrectionEffectDuration: TimeInterval = TimeInterval.minutes(60.0)
    private var proportionalCorrection: Double = 0.0
    private var integralCorrection: Double = 0.0
    private var differentialCorrection: Double = 0.0
    
    /**
     Initialize integral retrospective correction settings based on current values of user settings
     
     - Parameters:
        - settings: User Loop settings
        - insulinSensitivity: User insulin sensitivity schedule
        - basalRates: User basal rate schedule
     
     - Returns: Integral Retrospective Correction customized with controller parameters and user settings
    */
    init(_ settings: LoopSettings, _ insulinSensitivity: InsulinSensitivitySchedule?, _ basalRates: BasalRateSchedule?) {
        self.settings = settings
        self.insulinSensitivity = insulinSensitivity
        self.basalRates = basalRates
        totalRetrospectiveCorrection = HKQuantity(unit: unit, doubleValue: 0.0)
    }
    
    /**
     Calculate correction effect and correction effect duration based on timeline of past discrepancies
     
     - Parameters:
        - effectDuration: Effect duration for standard retrospective correction
        - currentDate: Date when timeline of past discrepancies is computed
        - currentDiscrepancy: Most recent discrepancy
        - latestGlucose: Most recent glucose
        - pastDiscrepancies: Timeline of past discepancies
     
     - Returns:
        - totalRetrospectiveCorrection: Overall glucose effect
        - integralCorrectionEffectDuration: Effect duration
     
    */
    func updateIntegralRetrospectiveCorrection(_ effectDuration: TimeInterval, _ currentDate: Date, _ currentDiscrepancy: GlucoseChange, _ latestGlucose: GlucoseValue, _ pastDiscrepancies: [GlucoseChange]) -> (HKQuantity, TimeInterval) {
        
        /// To reduce response delay, integral retrospective correction is computed over an array of recent contiguous discrepancy values having the same sign as the latest discrepancy value
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
        
        /// Return standard retrospective correction if user settings are not available
        let currentDiscrepancyValue = currentDiscrepancy.quantity.doubleValue(for: unit)
        totalRetrospectiveCorrection = HKQuantity(unit: unit, doubleValue: currentDiscrepancyValue)
        integralCorrectionEffectDuration = effectDuration
        
        /// Calculate integral retrospective correction if user settings are defined
        if
            let sensitivity = insulinSensitivity,
            let basalRates = basalRates,
            let correctionRange = settings.glucoseTargetRangeSchedule {
            
            let currentSensitivity = sensitivity.quantity(at: currentDate).doubleValue(for: unit)
            let currentBasalRate = basalRates.value(at: currentDate)
            let correctionRangeMin = correctionRange.minQuantity(at: currentDate).doubleValue(for: unit)
            let correctionRangeMax = correctionRange.maxQuantity(at: currentDate).doubleValue(for: unit)
            
            let latestGlucoseValue = latestGlucose.quantity.doubleValue(for: unit) // most recent glucose
            
            /// Safety limit for (+) integral effect. The limit is set to a larger value if the current blood glucose is further away from the correction range because we have more time available for corrections
            let glucoseError = latestGlucoseValue - correctionRangeMax
            let zeroTempEffect = abs(currentSensitivity * currentBasalRate)
            let integralEffectPositiveLimit = min(max(glucoseError, 1.0 * zeroTempEffect), 4.0 * zeroTempEffect)
            
            /// Limit for (-) integral effect: glucose prediction reduced by no more than 10 mg/dL below the correction range minimum
            let integralEffectNegativeLimit = -max(10.0, latestGlucoseValue - correctionRangeMin)
            
            /// Integral effect math
            integralCorrection = 0.0
            var integralCorrectionEffectMinutes = effectDuration.minutes - 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            for discrepancy in recentDiscrepancyValues {
                integralCorrection =
                    IntegralRetrospectiveCorrection.integralForget * integralCorrection +
                    IntegralRetrospectiveCorrection.integralGain * discrepancy
                integralCorrectionEffectMinutes += 2.0 * IntegralRetrospectiveCorrection.delta.minutes
            }
            /// Limits applied to integral correction effect and effect duration
            integralCorrection = min(max(integralCorrection, integralEffectNegativeLimit), integralEffectPositiveLimit)
            integralCorrectionEffectMinutes = min(integralCorrectionEffectMinutes, IntegralRetrospectiveCorrection.maximumCorrectionEffectDuration.minutes)
            
            /// Differential effect math
            var differentialDiscrepancy: Double = 0.0
            if recentDiscrepancyValues.count > 1 {
                let previousDiscrepancyValue = recentDiscrepancyValues[recentDiscrepancyValues.count - 2]
                differentialDiscrepancy = currentDiscrepancyValue - previousDiscrepancyValue
            }
            
            /// Overall glucose effect calculated as a sum of propotional, integral and differential effects
            proportionalCorrection = IntegralRetrospectiveCorrection.proportionalGain * currentDiscrepancyValue
            differentialCorrection = IntegralRetrospectiveCorrection.differentialGain * differentialDiscrepancy
            let totalCorrection = proportionalCorrection + integralCorrection + differentialCorrection
            totalRetrospectiveCorrection = HKQuantity(unit: unit, doubleValue: totalCorrection)
            integralCorrectionEffectDuration = TimeInterval(minutes: integralCorrectionEffectMinutes)
        }

        /// Return overall retrospective correction effect and effect duration
        return((totalRetrospectiveCorrection, integralCorrectionEffectDuration))
    }
    
}

extension IntegralRetrospectiveCorrection {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        var report: [String] = [
            "## IntegralRetrospectiveCorrection",
            "",
            "currentDiscrepancyGain: \(IntegralRetrospectiveCorrection.currentDiscrepancyGain)",
            "persistentDiscrepancyGain: \(IntegralRetrospectiveCorrection.persistentDiscrepancyGain)",
            "correctionTimeConstant [min]: \(IntegralRetrospectiveCorrection.correctionTimeConstant.minutes)",
            "proportionalGain: \(IntegralRetrospectiveCorrection.proportionalGain)",
            "integralForget: \(IntegralRetrospectiveCorrection.integralForget)",
            "integralGain: \(IntegralRetrospectiveCorrection.integralGain)",
            "differentialGain: \(IntegralRetrospectiveCorrection.differentialGain)",
            "recentDiscrepancyValues [mg/dL] (array of recent earliest-to-most-recent discrepancy values having the same sign as the latest discrepancy value): \(recentDiscrepancyValues)",
            "proportionalCorrection [mg/dL]: \(proportionalCorrection)",
            "integralCorrection [mg/dL]: \(integralCorrection)",
            "differentialCorrection [mg/dL]: \(differentialCorrection)",
            "totalRetrospectiveCorrection: \(totalRetrospectiveCorrection)",
            "integralCorrectionEffectDuration [min]: \(integralCorrectionEffectDuration.minutes)"
        ]
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}
