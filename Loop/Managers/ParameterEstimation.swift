//
//  ParameterEstimation.swift
//  Loop
//
//  Created by Dragan Maksimovic on 7/16/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

class ParameterEstimation {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue] = []
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var carbStatuses: [CarbStatus<StoredCarbEntry>] = []
    var estimationIntervals: [EstimationInterval] = []
    var status: String = ""
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
    
    func updateParameterEstimates() {
        assembleEstimationIntervals()
        print("myLoop: number of estimation intervals: ", estimationIntervals.count)
        for estimationInterval in estimationIntervals {
            let startInterval = estimationInterval.startDate
            let endInterval = estimationInterval.endDate
            estimationInterval.estimatedMultipliers = estimationInterval.estimateParameterMultipliers(startInterval, endInterval)

            // add estimation subIntervals to fasting estimation intervals
            if estimationInterval.estimationIntervalType == .fasting {
                var startSubInterval = estimationInterval.startDate
                while startSubInterval.addingTimeInterval(.minutes(60)) <
                    estimationInterval.endDate {
                        var endSubInterval = startSubInterval.addingTimeInterval(.minutes(60))
                        if endSubInterval.addingTimeInterval(.minutes(60)) > estimationInterval.endDate {
                            endSubInterval = estimationInterval.endDate
                        }
                        let estimatedMultipliers = estimationInterval.estimateParameterMultipliers(startSubInterval, endSubInterval)
                        estimationInterval.estimatedMultipliersSubIntervals.append(estimatedMultipliers)
                        startSubInterval = endSubInterval.addingTimeInterval(.minutes(-30))
                }
            }
            
        }
    }
    
    func assembleEstimationIntervals() {
        var runningEndDate = self.endDate
        for carbStatus in carbStatuses {
            guard
                let entryStart = carbStatus.absorption?.observedDate.start,
                let entryEnd = carbStatus.absorption?.observedDate.end,
                let enteredCarbs = carbStatus.absorption?.total,
                let observedCarbs = carbStatus.absorption?.observed,
                let timeRemaining = carbStatus.absorption?.estimatedTimeRemaining
                else {
                    self.status = "*** Err: a carbStatus field not available"
                    continue
            }
            
            if timeRemaining > 0 {
                // if an active carb absorption entry is detected, clean-up and terminate interval assembly
                print("myLoop detected active entry starting at: ", entryStart)
                
                if entryStart < self.startDate {
                    self.endDate = self.startDate
                    self.status = "*** Err: active carb absorption started before start of estimation"
                    print("myLoop xxx Err active absorption started before start of estimation xxx, startDate:", self.startDate, "endDate:", self.endDate)
                    return // if active carb absorption started before start of the estimation interval we have no valid intervals available for estimation
                }
                
                if entryStart > self.endDate {
                    // active absorption starts after the end of the estimation
                    // if need be, insert a trailing fasting interval and return
                    if runningEndDate < self.endDate {
                        //add a fasting interval from runningEndDate to self.endDate
                        let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
                        let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
                        let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
                        estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                        print("myLoop: added trailing fasting interval starting at: ", runningEndDate)
                    }
                    self.status = "*** Estimation interval assembly completed with a fasting interval after active absorption detected after estimation end"
                    print("myLoop completed assembly, startDate:", self.startDate, "endDate:", self.endDate)
                    return
                }
                
                if entryStart > runningEndDate {
                    //add a fasting interval from runningEndDate to self.endDate
                    self.endDate = entryStart
                    let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
                    let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
                    let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
                    estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                    print("myLoop: added trailing fasting interval starting at: ", runningEndDate)
                    self.status = "*** Estimation interval assembly completed with a fasting interval after active absorption detected before estimation end"
                    print("myLoop completed assembly, startDate:", self.startDate, "endDate:", self.endDate)
                    return
                }
                
                runningEndDate = entryStart
                var lastAbsorptionEnd = self.startDate
                for (index, estimationInterval) in self.estimationIntervals.enumerated() {
                    // remove any completed carb absorption that overlaps with active carb absorption
                    if estimationInterval.estimationIntervalType == .carbAbsorption {
                        if estimationInterval.endDate > runningEndDate {
                            print("myLoop removed carbAbsorbing interval", index)
                            self.estimationIntervals.remove(at: index)
                            runningEndDate = min( runningEndDate, estimationInterval.startDate )
                        } else {
                            lastAbsorptionEnd = max( lastAbsorptionEnd, estimationInterval.endDate )
                        }
                    }
                }
                self.endDate = runningEndDate
                
                self.status = "*** Completed assembly of estimation intervals after trimming out active absorptions"
                print("myLoop assembly completed after trimming trailing absorptions, startDate:", self.startDate, "endDate: ", self.endDate)
                return
            }
            
            if entryStart < self.startDate {
                // carbs started before startDate; move startDate to entryEnd
                self.startDate = max( entryEnd, self.startDate )
                print("myLoop detected entry prior to start, moved start to ", self.startDate)
                continue
            }
            
            print("myLoop valid entry, start assembly...")
            if estimationIntervals.count == 0 {
                // no intervals setup yet and entryStart is greater than self.startDate
                // add first fasting interval between self.startDate and entryStart
                let glucoseFasting = self.glucose.filterDateRange(self.startDate, entryStart)
                let insulinEffectFasting = self.insulinEffect?.filterDateRange(self.startDate, entryStart)
                let basalEffectFasting = self.basalEffect?.filterDateRange(self.startDate, entryStart)
                estimationIntervals.append(EstimationInterval(startDate: self.startDate, endDate: entryStart, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
                print("myLoop: added first fasting interval ending at:", entryStart)

                // add first carbAbsorption interval entryStart to entryEnd
                let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                runningEndDate = entryEnd
                print("myLoop: added first carbAbsorption interval at: ", entryStart)
            } else {
                // at least one interval has already been setup
                if estimationIntervals.last!.estimationIntervalType == .fasting {
                    estimationIntervals.last!.endDate = entryStart // terminate fasting interval
                    // add carbAbsorption interval from entryStart to entryEnd
                    let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                    let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                    let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                    estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                    runningEndDate = entryEnd
                    print("myLoop: added new carbAbsorption interval at: ", entryStart)
                } else {
                    // here previous estimaton interval must be .carbAbsorption
                    if entryStart > estimationIntervals.last!.endDate {
                        // add fasting interval between last endDate and entryStart
                        let glucoseFasting = self.glucose.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let insulinEffectFasting = self.insulinEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let basalEffectFasting = self.basalEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        estimationIntervals.append(EstimationInterval(startDate: estimationIntervals.last!.endDate, endDate: entryStart, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
                        print("myLoop added fasting ending at:", entryStart)
                        //** add carbAbsorption interval from entryStart to entryEnd
                        let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                        let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                        let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                        estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                        runningEndDate = entryEnd
                        print("myLoop added carbAbsorption ending at:", entryEnd)
                        print("myLoop added new fasting followed by new carbAbsorption interval")
                    } else {
                        // merge entry into existing carbAbsorption interval
                        runningEndDate = max(estimationIntervals.last!.endDate, entryEnd)
                        estimationIntervals.last!.endDate = runningEndDate
                        let mergedAbsorptionStartDate = min(estimationIntervals.last!.startDate, entryStart)
                        estimationIntervals.last!.startDate = mergedAbsorptionStartDate
                        let previouslyEnteredCarbGrams = estimationIntervals.last!.enteredCarbs!.doubleValue(for: .gram())
                        let enteredCarbGrams = enteredCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.enteredCarbs = HKQuantity(unit: .gram(), doubleValue: enteredCarbGrams + previouslyEnteredCarbGrams)
                        let previouslyObservedCarbGrams = estimationIntervals.last!.observedCarbs!.doubleValue(for: .gram())
                        let observedCarbGrams = observedCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.observedCarbs = HKQuantity(unit: .gram(), doubleValue: observedCarbGrams + previouslyObservedCarbGrams)
                        let glucoseAbsorbing = self.glucose.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        let basalEffectAbsorbing = self.basalEffect?.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        estimationIntervals.last!.glucose = glucoseAbsorbing
                        estimationIntervals.last!.insulinEffect = insulinEffectAbsorbing
                        estimationIntervals.last!.basalEffect = basalEffectAbsorbing
                        print("myLoop: merged carbs of entry ending at: ", entryEnd)
                    }
                    
                }

            }
        }
        // No more meal entries, the last previously entered interval must be carbAbsorption
        if runningEndDate < self.endDate {
            //add a fasting interval from runningEndDate to self.endDate
            let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
            let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
            let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
            estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
            print("myLoop: added trailing fasting interval starting at: ", runningEndDate)
        }
        
        self.status = "*** Estimation interval assembly completed with a fasting interval"
        print("myLoop completed assembly, startDate:", self.startDate, "endDate:", self.endDate)
        return
    }
}

// dm61 parameter estimation wip, new class July 15 collect all wip
class EstimationInterval {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue]?
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var enteredCarbs: HKQuantity?
    var observedCarbs: HKQuantity?
    var estimatedMultipliers: EstimatedMultipliers?
    var estimatedMultipliersSubIntervals: [EstimatedMultipliers?] = []
    var estimationIntervalType: EstimationIntervalType

    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date, type: EstimationIntervalType, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect]?, basalEffect: [GlucoseEffect]? = nil, enteredCarbs: HKQuantity? = nil, observedCarbs: HKQuantity? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.estimationIntervalType = type
        self.insulinEffect = insulinEffect
        self.glucose = glucose
        self.basalEffect = basalEffect
        self.enteredCarbs = enteredCarbs
        self.observedCarbs = observedCarbs
    }
    
    func estimateParameterMultipliers(_ start: Date, _ end: Date) -> EstimatedMultipliers? {
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            let basalEffect = self.basalEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return( nil )
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let startBasal = basalEffect.first?.quantity.doubleValue(for: unit),
            let endBasal = basalEffect.last?.quantity.doubleValue(for: unit)
            else {
                return( nil )
        }
        
        print("myLoop startGlucose:", startGlucose, "endGlucose:", endGlucose)
        
        let deltaGlucose = endGlucose - startGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        let deltaGlucoseBasal = endBasal - startBasal
        
        //a = -deltaBG;
        //b = alpha*(deltaBG + deltaBGInsulin);
        //c = deltaBGBasal;
        //d = deltaBGBasal + deltaBGInsulin;
        
        var actualOverObservedRatio = 0.0
        if let observedCarbs = self.observedCarbs?.doubleValue(for: .gram()),
            let enteredCarbs = self.enteredCarbs?.doubleValue(for: .gram()),
            enteredCarbs > 0 {
            let observedOverEnteredRatio = observedCarbs / enteredCarbs
            actualOverObservedRatio = (1.0 / observedOverEnteredRatio).squareRoot()
        }
        
        let insulinWeight = -deltaGlucose
        let carbWeight = actualOverObservedRatio * (deltaGlucose + deltaGlucoseInsulin)
        let basalWeight = deltaGlucoseBasal
        let insulinBasalWeight = deltaGlucoseInsulin + deltaGlucoseBasal
        
        //isfMultiplierX = 1/p1
        //crMultiplierX = 1/p2
        //basalMultiplierX = p3
        
        let (insulinSensitivityMultiplierInverse, carbRatioMultiplierInverse, basalMultiplier) = projectionToPlane(a: insulinWeight, b: carbWeight, c: basalWeight, d: insulinBasalWeight)
        let insulinSensitivityMultiplier = 1.0 / insulinSensitivityMultiplierInverse
        let carbRatioMultiplier = 1.0 / carbRatioMultiplierInverse
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: start, endDate: end, basalMultiplier: basalMultiplier, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: insulinSensitivityMultiplier, carbRatioMultiplier: carbRatioMultiplier, deltaGlucose: deltaGlucose, deltaGlucoseInsulin: deltaGlucoseInsulin, deltaGlucoseBasal: deltaGlucoseBasal)
        
        // self.estimatedMultipliers = estimatedMultipliers
        return( estimatedMultipliers )
    }
    
    /*
    func estimateParametersDuringFasting(start: Date, end: Date) {
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            let basalEffect = self.basalEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let startBasal = basalEffect.first?.quantity.doubleValue(for: unit),
            let endBasal = basalEffect.last?.quantity.doubleValue(for: unit)
            else {
                return
        }
        
        print("myLoop fasting startGlucose:", startGlucose, "endGlucose:", endGlucose)
        
        let deltaGlucose = endGlucose - startGlucose
        self.deltaGlucose = deltaGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        self.deltaGlucoseInsulin = deltaGlucoseInsulin
        let deltaGlucoseBasal = endBasal - startBasal
        self.deltaGlucoseBasal = deltaGlucoseBasal
        
        let (basalMultiplier, insulinSensitivityMultiplierInverse) = projectionToLine(a: deltaGlucoseBasal, b: -deltaGlucose, c: deltaGlucoseBasal + deltaGlucoseInsulin)
        let insulinSensitivityMultiplier = 1.0 / insulinSensitivityMultiplierInverse
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: startDate, endDate: endDate, basalMultiplier: basalMultiplier, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: insulinSensitivityMultiplier, carbRatioMultiplier: 1.0)
        
        self.estimatedMultipliers = estimatedMultipliers
    }
    */
    
    /*
    func estimateParametersForCarbEntries() {
        
        let start = self.startDate
        let end = self.endDate
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            let basalEffect = self.basalEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let startBasal = basalEffect.first?.quantity.doubleValue(for: unit),
            let endBasal = basalEffect.last?.quantity.doubleValue(for: unit),
            let observedCarbs = self.observedCarbs?.doubleValue(for: .gram()),
            let enteredCarbs = self.enteredCarbs?.doubleValue(for: .gram()),
            enteredCarbs > 0.0
            else {
                return
        }
        
        print("myLoop absorbing startGlucose:", startGlucose, "endGlucose:", endGlucose)
        
        //dm61 July 7-12 notes: redo cr, csf, isf multipliers
        // notes in ParameterEstimationNotes.pptx
        
        let observedOverEnteredRatio = observedCarbs / enteredCarbs
        let deltaGlucose = endGlucose - startGlucose
        self.deltaGlucose = deltaGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        self.deltaGlucoseInsulin = deltaGlucoseInsulin
        let deltaGlucoseBasal = endBasal - startBasal
        self.deltaGlucoseBasal = deltaGlucoseBasal
        
        let deltaGlucoseCounteraction = deltaGlucose + deltaGlucoseInsulin
        guard
            deltaGlucoseCounteraction != 0.0,
            observedOverEnteredRatio != 0.0
            else {
                return
        }
        
        // sqrt models the assumption that observed/entered is a product of mis-estimated carbs factor and a mimatched parameters factor
        let actualOverObservedRatio = (1.0 / observedOverEnteredRatio).squareRoot() // c
        let csfWeight = deltaGlucose / deltaGlucoseCounteraction // a
        let crWeight = 1.0 - csfWeight // b
        
        let (csfMultiplierInverse, crMultiplier) = projectionToLine(a: csfWeight, b: crWeight, c: actualOverObservedRatio)
        
        let carbSensitivityMultiplier = 1.0 / csfMultiplierInverse
        let insulinSensitivityMultiplier = crMultiplier / csfMultiplierInverse
        
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: startDate, endDate: endDate, basalMultiplier: 1.0, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: carbSensitivityMultiplier, carbRatioMultiplier: crMultiplier)
        
        self.estimatedMultipliers = estimatedMultipliers
        
        return
    }
    */
    
}

class EstimatedMultipliers {
    var startDate: Date
    var endDate: Date
    var basalMultiplier: Double
    var insulinSensitivityMultiplier: Double
    var carbSensitivityMultiplier: Double
    var carbRatioMultiplier: Double
    var deltaGlucose: Double
    var deltaGlucoseInsulin: Double
    var deltaGlucoseBasal: Double
    
    init(startDate: Date, endDate: Date, basalMultiplier: Double, insulinSensitivityMultiplier: Double, carbSensitivityMultiplier: Double, carbRatioMultiplier: Double, deltaGlucose: Double, deltaGlucoseInsulin: Double, deltaGlucoseBasal: Double) {
        self.startDate = startDate
        self.endDate = endDate
        self.basalMultiplier = basalMultiplier
        self.insulinSensitivityMultiplier = insulinSensitivityMultiplier
        self.carbSensitivityMultiplier = carbSensitivityMultiplier
        self.carbRatioMultiplier = carbRatioMultiplier
        self.deltaGlucose = deltaGlucose
        self.deltaGlucoseInsulin = deltaGlucoseInsulin
        self.deltaGlucoseBasal = deltaGlucoseBasal
    }
    
}

struct EstimationIntervalType: OptionSet {
    let rawValue: Int
    
    static let carbAbsorption = EstimationIntervalType(rawValue: 1 << 0)
    static let fasting = EstimationIntervalType(rawValue: 1 << 1)
}

/// projection of point (1, 1) to line a * x + b * y = c
fileprivate func projectionToLine(a: Double, b: Double, c: Double) -> (Double, Double) {
    let dotProduct = pow(a, 2.0) + pow(b, 2.0)
    if dotProduct == 0.0 {
        return(1.0, 1.0)
    } else {
        let x = (pow(b, 2.0) - a * b + a * c) / dotProduct
        let y = (pow(a, 2.0) - a * b + b * c) / dotProduct
        return(x, y)
    }
}

/// projection of point (1, 1, 1) to plane a * x + b * y + c * z = d
fileprivate func projectionToPlane(a: Double, b: Double, c: Double, d: Double) -> (Double, Double, Double) {
    let dotProduct = pow(a, 2.0) + pow(b, 2.0) + pow(c, 2.0)
    if dotProduct == 0.0 {
        return(1.0, 1.0, 1.0)
    } else {
        let p1 = (pow(b, 2.0) + pow(c, 2.0) - a * (b + c - d) ) / dotProduct
        let p2 = (pow(a, 2.0) + pow(c, 2.0) - b * (a + c - d) ) / dotProduct
        let p3 = (pow(a, 2.0) + pow(b, 2.0) - c * (a + b - d) ) / dotProduct
        return(p1, p2, p3)
    }
}

/// filterDataRange for [GlucoseValue]
extension Collection where Iterator.Element == GlucoseValue {
    func filterDateRange(_ startDate: Date?, _ endDate: Date?) -> [Iterator.Element] {
        return filter { (value) -> Bool in
            if let startDate = startDate, value.endDate < startDate {
                return false
            }
            
            if let endDate = endDate, value.startDate > endDate {
                return false
            }
            
            return true
        }
    }
}

extension ParameterEstimation {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .short

        var report: [String] = []
        
        report += ["=================================="]
        report += ["Settings Review Period\n\(dateFormatter.string(from: self.startDate)) to \(dateFormatter.string(from: self.endDate))"]
        report += ["=================================="]
        
        for estimationInterval in estimationIntervals {
            guard
                var insulinSensitivityMultiplier = estimationInterval.estimatedMultipliers?.insulinSensitivityMultiplier,
                var carbRatioMultiplier = estimationInterval.estimatedMultipliers?.carbRatioMultiplier,
                var basalMultiplier = estimationInterval.estimatedMultipliers?.basalMultiplier,
                let deltaGlucose = estimationInterval.estimatedMultipliers?.deltaGlucose,
                let deltaGlucoseBasal = estimationInterval.estimatedMultipliers?.deltaGlucoseBasal,
                let deltaGlucoseInsulin = estimationInterval.estimatedMultipliers?.deltaGlucoseInsulin
                else { continue }
            insulinSensitivityMultiplier = (insulinSensitivityMultiplier * 100).rounded() / 100
            carbRatioMultiplier = (carbRatioMultiplier * 100).rounded() / 100
            basalMultiplier = (basalMultiplier * 100).rounded() / 100
            
            if estimationInterval.estimationIntervalType == .fasting {
                var isfTag = ""
                if deltaGlucose * deltaGlucoseInsulin > 0 {
                    isfTag = "❌"
                }
                if deltaGlucose * deltaGlucoseInsulin < 0 && deltaGlucoseInsulin > 0.5 * deltaGlucoseBasal && basalMultiplier < 1.5 && basalMultiplier > 0.5 {
                    isfTag = "✅"
                }
                var basalTag = ""
                if basalMultiplier < 1.5 && basalMultiplier > 0.5 && deltaGlucoseBasal > 0.5 * deltaGlucoseInsulin {
                    basalTag = "✅"
                }
                report += ["** Fasting **\n\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
                if insulinSensitivityMultiplier > 1.5 || insulinSensitivityMultiplier < 0.5 {
                    report += ["ISF multiplier: not available"]
                } else {
                    report += ["ISF multiplier: \(insulinSensitivityMultiplier) \(isfTag)"]
                }
                report += ["Basal multiplier: \(basalMultiplier) \(basalTag)"]
                if basalMultiplier > 1.5 {
                    report += ["Warning: unannounced meals?"]
                }
                if insulinSensitivityMultiplier > 1.5 || insulinSensitivityMultiplier < 0.5 || basalMultiplier > 1.5 || basalMultiplier < 0.5 {
                    report += ["Check fasting subintervals"]
                }
            } else {
                report += ["** Meal absorption **\n\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
                report += ["CR multiplier: \(carbRatioMultiplier)"]
                report += ["ISF multiplier: \(insulinSensitivityMultiplier)"]
                report += ["Basal multiplier: \(basalMultiplier)"]
                report += ["Review meal entries for accuracy"]
            }
            report += ["----------------------------------"]
        }
        
        report += ["\n=================================="]
        report += ["Fasting subintervals"]
        report += ["=================================="]
        
        for estimationInterval in estimationIntervals {
            if estimationInterval.estimationIntervalType == .fasting {
                report += ["----------------------------------"]
                report += ["\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
                report += ["----------------------------------"]
                for estimationSubInterval in estimationInterval.estimatedMultipliersSubIntervals {
                    guard
                        var insulinSensitivityMultiplier = estimationSubInterval?.insulinSensitivityMultiplier,
                        var carbRatioMultiplier = estimationSubInterval?.carbRatioMultiplier,
                        var basalMultiplier = estimationSubInterval?.basalMultiplier,
                        let deltaGlucose = estimationSubInterval?.deltaGlucose,
                        let deltaGlucoseBasal = estimationSubInterval?.deltaGlucoseBasal,
                        let deltaGlucoseInsulin = estimationSubInterval?.deltaGlucoseInsulin
                        else { continue }
                    insulinSensitivityMultiplier = (insulinSensitivityMultiplier * 100).rounded() / 100
                    carbRatioMultiplier = (carbRatioMultiplier * 100).rounded() / 100
                    basalMultiplier = (basalMultiplier * 100).rounded() / 100
                    var isfTag = ""
                    if deltaGlucose * deltaGlucoseInsulin > 0 {
                        isfTag = "❌"
                    }
                    if deltaGlucose * deltaGlucoseInsulin < 0 && deltaGlucoseInsulin > 0.5 * deltaGlucoseBasal && basalMultiplier < 1.5 && basalMultiplier > 0.5 {
                        isfTag = "✅"
                    }
                    var basalTag = ""
                    if basalMultiplier < 1.5 && basalMultiplier > 0.5 && deltaGlucoseBasal > 0.5 * deltaGlucoseInsulin {
                        basalTag = "✅"
                    }
                    report += ["\(dateFormatter.string(from: estimationSubInterval?.startDate ?? Date())) to \(dateFormatter.string(from: estimationSubInterval?.endDate ?? Date()))"]
                    if insulinSensitivityMultiplier > 1.5 || insulinSensitivityMultiplier < 0.5 {
                        report += ["ISF multiplier: not available"]
                    } else {
                        report += ["ISF multiplier: \(insulinSensitivityMultiplier) \(isfTag)"]
                    }
                    report += ["Basal multiplier: \(basalMultiplier) \(basalTag)"]
                    if basalMultiplier > 1.5 {
                        report += ["Warning: unannounced meals?"]
                    }
                    report += ["---"]
                }
            }
        }
        report += ["\n=================================="]
        report += ["Paramater estimation diagnostics"]
        report += ["=================================="]
        report += [
            "## Settings Review \n", "From: \(dateFormatter.string(from: self.startDate)) \n", "To: \(dateFormatter.string(from: self.endDate)) \n", self.status,
            estimationIntervals.reduce(into: "", { (entries, entry) in
                entries.append("\n ---------- \n \(dateFormatter.string(from: entry.startDate)), \(dateFormatter.string(from: entry.endDate)), \(entry.estimationIntervalType), \(String(describing: entry.enteredCarbs?.doubleValue(for: .gram()))), \(String(describing: entry.observedCarbs?.doubleValue(for: .gram()))), \n deltaBG: \(String(describing: entry.estimatedMultipliers?.deltaGlucose)), \n deltaBGinsulin: \(String(describing: entry.estimatedMultipliers?.deltaGlucoseInsulin)), \n deltaBGbasal: \(String(describing: entry.estimatedMultipliers?.deltaGlucoseBasal)), \n ISF multiplier: \(String(describing: entry.estimatedMultipliers?.insulinSensitivityMultiplier)), \n CR multiplier: \(String(describing: entry.estimatedMultipliers?.carbRatioMultiplier)), \n Basal multiplier: \(String(describing: entry.estimatedMultipliers?.basalMultiplier))"
            )}),
            "",
        ]
        

        
        
        report += ["\n -- Additional paramater estimation diagnostics -- \n"]
        
        // Glucose values
        report += ["\n *** Glucose values (start, mg/dL) \n",
        self.glucose.reduce(into: "", { (entries, entry) in
        entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
        })]
        
        // Insulin effects
        report += ["\n *** Insulin effects (start, mg/dL) \n",
                   (self.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                   })]
        
        // Zero basal effects
        report += ["\n *** Zero basal effects (start, mg/dL) \n",
                   (self.basalEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                   })]
        
        // Carb entry statuses
        report += ["\n *** carbStatuses: \(self.carbStatuses) \n"]
        
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}

