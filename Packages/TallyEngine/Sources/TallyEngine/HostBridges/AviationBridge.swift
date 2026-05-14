import Foundation
import JavaScriptCore
import TallyAviation
import os

/// Registers aviation-flavoured functions inside math.js so they can be
/// called from calculator expressions:
///
///   density_altitude(8000, 25, 29.92)      // PA ft, OAT °C, altimeter inHg
///   pressure_altitude(5000, 29.42)         // indicated ft, altimeter inHg
///   isa_temp(10000)                        // °C at altitude
///   ground_speed(360, 100, 280, 15)        // course, TAS, wind from, wind speed
///   crosswind(270, 300, 10)                // runway hdg, wind from, wind speed
///   headwind(270, 300, 10)
///   ete(180, 120)                          // distance, ground speed → hours
///   tod(10000, 500, 120)                   // alt to lose ft, descent rate fpm, GS → distance
public enum AviationBridge {
    private static let logger = Logger(subsystem: "app.tally.Tally", category: "aviation-bridge")

    public static func register(on context: JSContext) {
        // Stage 1: Park Swift closures on a temp JS global.
        let densityAltitude: @convention(block) (Double, Double, Double) -> Double = { pa, oat, alt in
            Atmosphere.densityAltitudeFt(indicatedAltitudeFt: pa, altimeterInHg: alt, oatC: oat)
        }
        let pressureAltitude: @convention(block) (Double, Double) -> Double = { ind, alt in
            Atmosphere.pressureAltitudeFt(indicatedAltitudeFt: ind, altimeterInHg: alt)
        }
        let isaTemp: @convention(block) (Double) -> Double = { Atmosphere.isaTempC(altitudeFt: $0) }
        let groundSpeed: @convention(block) (Double, Double, Double, Double) -> Double = { course, tas, wfrom, wspd in
            E6B.windTriangle(courseDeg: course, tas: tas, windFromDeg: wfrom, windSpeed: wspd).groundSpeed
        }
        let heading: @convention(block) (Double, Double, Double, Double) -> Double = { course, tas, wfrom, wspd in
            E6B.windTriangle(courseDeg: course, tas: tas, windFromDeg: wfrom, windSpeed: wspd).headingDeg
        }
        let crosswind: @convention(block) (Double, Double, Double) -> Double = { rwy, wfrom, wspd in
            Runway.components(runwayHeadingDeg: rwy, windFromDeg: wfrom, windSpeed: wspd).crosswind
        }
        let headwind: @convention(block) (Double, Double, Double) -> Double = { rwy, wfrom, wspd in
            Runway.components(runwayHeadingDeg: rwy, windFromDeg: wfrom, windSpeed: wspd).headwind
        }
        let ete: @convention(block) (Double, Double) -> Double = { dist, gs in
            Fuel.eteHours(distance: dist, groundSpeed: gs)
        }
        let tod: @convention(block) (Double, Double, Double) -> Double = { lose, rate, gs in
            Fuel.topOfDescentDistance(altitudeToLoseFt: lose, descentRateFpm: rate, groundSpeed: gs)
        }
        let endurance: @convention(block) (Double, Double) -> Double = { fuel, burn in
            Fuel.enduranceHours(fuelQty: fuel, burnRate: burn)
        }

        guard let bridge = JSValue(newObjectIn: context) else {
            // `JSValue(newObjectIn:)` only returns nil if the context is
            // already in an error state (e.g. JS engine failed to start).
            // Bail out cleanly rather than crash — calculator math still
            // works without aviation functions, only e6b/density_altitude/
            // crosswind/etc. fail to register.
            logger.error("register: JSContext rejected new object; aviation bridge not installed")
            return
        }
        bridge.setValue(densityAltitude, forProperty: "density_altitude")
        bridge.setValue(pressureAltitude, forProperty: "pressure_altitude")
        bridge.setValue(isaTemp,           forProperty: "isa_temp")
        bridge.setValue(groundSpeed,       forProperty: "ground_speed")
        bridge.setValue(heading,           forProperty: "heading")
        bridge.setValue(crosswind,         forProperty: "crosswind")
        bridge.setValue(headwind,          forProperty: "headwind")
        bridge.setValue(ete,               forProperty: "ete")
        bridge.setValue(tod,               forProperty: "tod")
        bridge.setValue(endurance,         forProperty: "endurance")
        context.setObject(bridge, forKeyedSubscript: "_avbridge" as NSString)

        // Stage 2: Use math.import() to register them inside math.js's own scope.
        // We re-wrap each as a JS function whose only job is to forward to _avbridge.
        let importScript = """
        math.import({
          density_altitude:  function(pa, oat, alt)              { return _avbridge.density_altitude(pa, oat, alt); },
          pressure_altitude: function(ind, alt)                  { return _avbridge.pressure_altitude(ind, alt); },
          isa_temp:          function(ft)                        { return _avbridge.isa_temp(ft); },
          ground_speed:      function(course, tas, wfrom, wspd)  { return _avbridge.ground_speed(course, tas, wfrom, wspd); },
          heading:           function(course, tas, wfrom, wspd)  { return _avbridge.heading(course, tas, wfrom, wspd); },
          crosswind:         function(rwy, wfrom, wspd)          { return _avbridge.crosswind(rwy, wfrom, wspd); },
          headwind:          function(rwy, wfrom, wspd)          { return _avbridge.headwind(rwy, wfrom, wspd); },
          ete:               function(distance, gs)              { return _avbridge.ete(distance, gs); },
          tod:               function(lose, rate, gs)            { return _avbridge.tod(lose, rate, gs); },
          endurance:         function(fuel, burn)                { return _avbridge.endurance(fuel, burn); }
        }, { override: true });
        """
        _ = context.evaluateScript(importScript)
    }
}
