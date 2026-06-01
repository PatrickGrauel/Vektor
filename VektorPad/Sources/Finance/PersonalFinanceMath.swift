import Foundation

/// Maths for the new personal-finance tools. Loan + real-estate
/// math stay in their existing files; this is fresh territory
/// (savings goals, retirement projection, inflation) so it lives
/// here to keep the surface area obvious.

enum SavingsMath {

    struct Inputs {
        /// What the user already has saved towards this goal.
        var presentValue: Double
        /// What they want to have at `monthsToGoal` from now.
        var targetValue: Double
        /// Time horizon in months.
        var monthsToGoal: Int
        /// Expected nominal annual return on the savings vehicle.
        /// Stored as a fraction (0.05 = 5%).
        var annualReturn: Double
    }

    struct Outputs {
        /// What you have to put in every month to hit the target.
        /// Negative when present value already overshoots the goal
        /// (the user is "over-saving" — surface that gently in the UI).
        var requiredMonthlyContribution: Double
        /// Projected per-month balance over the horizon, useful
        /// for plotting a line chart later.
        var projectedBalance: [Double]
        /// Total of all monthly contributions (excluding interest).
        var totalContributions: Double
        /// Interest earned over the horizon.
        var totalInterest: Double
    }

    /// Solve for required monthly contribution given target FV,
    /// horizon, and return rate. Then simulate the balance trajectory.
    static func solve(_ inputs: Inputs) -> Outputs {
        let n = max(0, inputs.monthsToGoal)
        guard n > 0 else {
            return Outputs(
                requiredMonthlyContribution: 0,
                projectedBalance: [inputs.presentValue],
                totalContributions: 0,
                totalInterest: 0
            )
        }
        let r = inputs.annualReturn / 12.0
        let fvOfPV: Double
        let annuityFactor: Double
        if abs(r) < 1e-9 {
            fvOfPV = inputs.presentValue
            annuityFactor = Double(n)
        } else {
            fvOfPV = inputs.presentValue * pow(1 + r, Double(n))
            annuityFactor = (pow(1 + r, Double(n)) - 1) / r
        }
        let pmt = (inputs.targetValue - fvOfPV) / max(annuityFactor, 1e-9)

        // Simulate the actual monthly walk so we can plot it later
        // and report contribution + interest totals exactly.
        var balance = inputs.presentValue
        var trajectory: [Double] = [balance]
        var totalContrib = 0.0
        for _ in 0..<n {
            balance += pmt
            totalContrib += pmt
            balance *= (1 + r)
            trajectory.append(balance)
        }
        let totalInterest = balance - inputs.presentValue - totalContrib
        return Outputs(
            requiredMonthlyContribution: pmt,
            projectedBalance: trajectory,
            totalContributions: totalContrib,
            totalInterest: totalInterest
        )
    }
}

enum RetirementMath {

    struct Inputs {
        var currentAge: Int
        var retirementAge: Int
        var currentSavings: Double
        var monthlyContribution: Double
        /// Pre-retirement expected return (fraction).
        var growthReturn: Double
        /// Annual spending in retirement.
        var annualRetirementSpending: Double
        /// Post-retirement (more conservative) expected return.
        var withdrawalReturn: Double
        /// Annual inflation assumption — spending grows at this rate
        /// during retirement.
        var inflation: Double
    }

    struct Outputs {
        /// Balance at the moment of retirement.
        var balanceAtRetirement: Double
        /// Years the balance survives at the requested spending
        /// (inflation-adjusted, withdrawal return applied).
        var yearsFunded: Double
        /// "Are you going to be okay?" verdict.
        var verdict: Verdict
        /// One value per year (current age → end of withdrawal),
        /// useful for a future line chart.
        var yearlyBalance: [Double]
    }

    enum Verdict {
        case shortfall      // funded < 20 years
        case adequate       // 20–35 years
        case fullyFunded    // 35+ years
    }

    static func project(_ inputs: Inputs) -> Outputs {
        let accumulationYears = max(0, inputs.retirementAge - inputs.currentAge)
        let monthlyGrowthR = inputs.growthReturn / 12.0
        var balance = inputs.currentSavings
        var yearly: [Double] = [balance]

        // Accumulation: compound monthly contributions for the
        // pre-retirement window.
        for _ in 0..<accumulationYears {
            for _ in 0..<12 {
                balance += inputs.monthlyContribution
                balance *= (1 + monthlyGrowthR)
            }
            yearly.append(balance)
        }
        let balanceAtRetirement = balance

        // Withdrawal: draw inflated annual spending until the pot
        // hits zero (or we hit a sane cap at 60 years).
        var withdrawalYears = 0.0
        var spending = inputs.annualRetirementSpending
        for year in 0..<60 {
            let prev = balance
            balance = (balance - spending) * (1 + inputs.withdrawalReturn)
            if balance <= 0 {
                // Partial-year credit: how much of `year` did we
                // actually fund before going negative?
                let partial = prev / max(spending, 1)
                withdrawalYears = Double(year) + min(1.0, max(0.0, partial))
                yearly.append(0)
                break
            }
            yearly.append(balance)
            withdrawalYears = Double(year + 1)
            spending *= (1 + inputs.inflation)
        }

        let verdict: Verdict
        switch withdrawalYears {
        case ..<20:  verdict = .shortfall
        case ..<35:  verdict = .adequate
        default:     verdict = .fullyFunded
        }
        return Outputs(
            balanceAtRetirement: balanceAtRetirement,
            yearsFunded: withdrawalYears,
            verdict: verdict,
            yearlyBalance: yearly
        )
    }
}

enum InflationMath {

    /// Future cost of something that costs `presentValue` today,
    /// `years` from now, with an annual `inflationRate` (fraction).
    static func futureCost(presentValue: Double,
                           years: Double,
                           inflationRate: Double) -> Double {
        presentValue * pow(1 + inflationRate, years)
    }

    /// Present-day purchasing power of a future nominal amount.
    static func presentValueOf(future: Double,
                               years: Double,
                               inflationRate: Double) -> Double {
        future / pow(1 + inflationRate, years)
    }

    /// Nominal return needed to break even against inflation (the
    /// real return is the gap between this and the inflation rate).
    /// For e.g. inflation 3% and target real return 1% → 4.03%.
    static func breakEvenRate(realReturn: Double,
                              inflationRate: Double) -> Double {
        // (1 + nominal) = (1 + real)(1 + inflation)
        (1 + realReturn) * (1 + inflationRate) - 1
    }
}
