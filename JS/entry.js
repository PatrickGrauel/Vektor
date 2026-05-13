// Entry bundled by esbuild into mathjs.bundle.js.
// Result is loaded into JSContext at app launch; everything declared here is
// reachable from Swift via JSContext.evaluateScript / objectForKeyedSubscript.

import { create, all } from "mathjs";

// Use the full math.js feature set: units, currencies-as-units, percentages,
// trigonometry, statistics (sum/mean for our aggregates), complex, etc.
const math = create(all, {
  number: "number",
  precision: 14,
});

// Expose a friendly "evaluate" facade plus a host-extension hook so Swift can
// register currency rates and aviation functions at startup.
globalThis.math = math;

globalThis.tally = {
  /** Variables declared in the document survive across lines via this scope. */
  scope: {},

  /** Reset before re-evaluating the whole document. */
  resetScope() {
    globalThis.tally.scope = {};
  },

  /**
   * Evaluate a single expression and return a friendly-formatted string.
   * Precision = max number of significant digits to keep (default 14).
   * Returns `null` on error (caller falls back to mathjs's raw exception
   * via try/catch in `evalLine`).
   */
  format(value, precision) {
    if (value === undefined || value === null) return "";
    // Pre-formatted strings (e.g. from hms()/hm()) must pass through verbatim;
    // math.format would otherwise wrap them in quotes — and we don't want to
    // group thousands inside `01:48:00` either.
    if (typeof value === "string") return value;
    // Settings UI exposes this as "decimal places". Default = 14 means
    // "effectively unlimited"; users typically drop it to 2 for pretty
    // conversion output (`1 kt in km/h → 1.85 km/h`, `1 BTC in USD → 65 000.00`).
    const dp = (precision != null && precision >= 0) ? precision : 14;
    try {
      // `notation: "fixed"` makes precision mean "digits after the decimal
      // point" — what users expect from a "decimal places" setting.
      let s = math.format(value, {
        notation: "fixed",
        precision: dp,
      });
      // When the user has explicitly chosen a low precision (≤ 6), honour
      // it exactly: pad with trailing zeros so `1 BTC in USD` reads
      // `65 000.00 USD`, not `65 000`. For the default high-precision case
      // (14) we DO strip trailing zeros so a result like `1.85` doesn't
      // render as `1.85000000000000`.
      if (dp > 6) {
        s = s.replace(/(\d+)\.(\d*?)0+(?=\D|$)/g, (_, a, b) => b.length ? `${a}.${b}` : a);
        s = s.replace(/(\d+)\.(?=\D|$)/g, "$1");
      }
      // Thousands separator: insert a regular space every 3 digits in the
      // integer part of any numeric run (`10000000` → `10 000 000`,
      // `1850.5 m/s` → `1 850.5 m/s`). The lookbehind keeps us out of
      // identifiers / words; matches less than 4 digits long are skipped.
      s = s.replace(/(\d+)(\.\d+)?/g, (m, intPart, decPart) => {
        const grouped = intPart.length > 3
          ? intPart.replace(/\B(?=(\d{3})+(?!\d))/g, " ")
          : intPart;
        return grouped + (decPart || "");
      });
      return s;
    } catch (e) {
      return String(value);
    }
  },

  /**
   * Set a currency-as-unit conversion (called from FXBridge).
   * Registers both UPPER and lower case alias so users can type either
   * `100 EUR in USD` or `100 eur in usd`.
   */
  setCurrency(code, ratePerUSD) {
    // Reject garbage rates outright. A 0 or NaN rate from a flaky API would
    // produce `Infinity USD` / `NaN USD` unit definitions that silently
    // propagate Infinity through every downstream conversion.
    if (!isFinite(ratePerUSD) || ratePerUSD <= 0) return;
    const upper = String(code).toUpperCase();
    const lower = upper.toLowerCase();
    // math.js's createUnit accepts override via the THIRD argument
    // (`(name, definition, options)`). Passing
    // `{ definition: ..., override: true }` as the single second argument
    // looks reasonable, but math.js treats it as the definition object and
    // silently throws "unit already exists" — leaving stale 1:1 placeholder
    // rates in place and producing `1 EUR in USD = 1 USD` even after FX
    // rates load. See https://mathjs.org/docs/datatypes/units.html.
    try {
      math.createUnit(upper, `${1 / ratePerUSD} USD`, { override: true });
    } catch (e) { /* ignore */ }
    if (lower !== upper) {
      try { math.createUnit(lower, `1 ${upper}`, { override: true }); } catch (e) {}
    }
  },

  /** USD as base. No other currencies pre-registered — they come in either
   *  from FXService (live rate) or from `ensureCurrency` (placeholder, on
   *  first use). This ordering lets real rates win when present and lets
   *  variable assignments like `b = 5000 EUR` still work without a key. */
  initBaseCurrencies() {
    try { math.createUnit("USD"); } catch (e) {}
    try { math.createUnit("usd", "1 USD", { override: true }); } catch (e) {}
  },

  /** ISO codes we accept as currencies (matches OpenExchangeRates' list). */
  knownCurrencyCodes: new Set([
    "USD","EUR","GBP","JPY","CHF","CAD","AUD","NZD","CNY","HKD","SGD",
    "INR","RUB","BRL","MXN","ZAR","KRW","SEK","NOK","DKK","PLN",
    "CZK","HUF","TRY","ILS","AED","SAR","IDR","THB","MYR","PHP",
    "VND","TWD","NGN","EGP","ARS","CLP","COP","PEN","MAD","KES",
    "GHS","UAH","RON","BGN","ISK","RSD","BAM","BHD","KWD","OMR",
    "QAR","PKR","BDT","LKR","NPR","MMK","KHR","LAK","MOP","FJD",
    "XPF","XCD","CRC","DOP","JMD","TTD","BBD","PAB","GTQ","BOB",
    "PYG","UYU","VES","HNL","NIO","SVC",
    "BTC","ETH","SOL","ADA","DOGE","XRP","DOT","LTC","AVAX","BNB",
    "USDT","USDC"
  ]),

  /**
   * Register a placeholder currency unit (1:1 with USD) if no rate has been
   * set yet. Called from NumiEngine just before evaluating a line so that
   * expressions like `b = 5000 EUR; b * 2` work without an OXR key.
   *
   * If FXService has already registered the unit with a real rate, this is
   * a no-op and the real rate wins.
   */
  ensureCurrency(code) {
    if (!code) return;
    const upper = String(code).toUpperCase();
    if (!this.knownCurrencyCodes.has(upper)) return;
    if (math.Unit.UNITS[upper]) return;            // real rate already set
    try { math.createUnit(upper, { definition: "1 USD" }); } catch (e) {}
    const lower = upper.toLowerCase();
    if (lower !== upper && !math.Unit.UNITS[lower]) {
      try { math.createUnit(lower, { definition: `1 ${upper}` }); } catch (e) {}
    }
  },

  /** Common currency spellings → ISO codes, registered lazily once we
   *  know what ISO codes the user is actually touching. */
  spellings: {
    dollar: "USD", dollars: "USD",
    euro: "EUR", euros: "EUR",
    pound: "GBP", pounds: "GBP",
    yen: "JPY",
    yuan: "CNY", rmb: "CNY",
    rupee: "INR", rupees: "INR",
    peso: "MXN", pesos: "MXN",
    rand: "ZAR",
    won: "KRW",
    bitcoin: "BTC", bitcoins: "BTC",
    ether: "ETH",
  },

  /**
   * Aviation + general units that math.js doesn't ship (or doesn't alias).
   * Wrapped in try/catch because some bundles already include a few; passing
   * override:true on a built-in occasionally throws.
   */
  initAviationUnits() {
    const add = (name, def) => {
      try { math.createUnit(name, def, { override: true }); } catch (e) {}
    };
    // ── Aviation ────────────────────────────────────────────────
    add("NM",   "1852 m");
    add("nmi",  "1 NM");
    add("nautical_mile", "1 NM");
    add("kt",   "1 NM / hour");
    add("kts",  "1 kt");
    add("kn",   "1 kt");
    add("inHg", "3386.389 Pa");
    add("FL",   "100 ft");
    add("fpm",  "1 ft / minute");
    add("gph",  "1 gallon / hour");
    add("lph",  "1 litre / hour");
    add("rpm",  "1 / minute");

    // ── Speed aliases ───────────────────────────────────────────
    add("kmh",  "1 km / hour");
    add("kph",  "1 km / hour");
    add("mps",  "1 m / s");
    add("mph",  "1 mile / hour");          // math.js doesn't ship this

    // ── Length / Astronomy ──────────────────────────────────────
    // NOTE: math.js's createUnit rejects names with underscores, so any
    // alias defined here must be a single identifier of letters only.
    // `parsec` is the documented spelling; `pc` collides with gold prefix
    // disambiguation in math.js, so we register both names explicitly.
    add("micron",    "1 um");
    add("ly",        "9.4607304725808e15 m");   // light-year
    add("AU",        "149597870700 m");          // astronomical unit
    add("parsec",    "3.0857e16 m");             // canonical name in docs
    add("fathom",    "1.8288 m");
    add("furlong",   "201.168 m");
    add("league",    "4828.032 m");

    // ── Mass / Weight ───────────────────────────────────────────
    add("metric_ton", "1000 kg");
    add("ct",        "200 mg");                  // carat
    add("slug_mass", "14.5939 kg");

    // ── Volume ──────────────────────────────────────────────────
    // math.js's createUnit silently rejects names with underscores, so
    // `imperial_gallon` would never resolve. Use a single-identifier name.
    add("ml",        "1 milliliter");
    add("dl",        "100 milliliter");
    add("igallon",   "4.54609 liter");           // imperial gallon
    add("ipint",     "0.568261 liter");          // imperial pint
    add("tbsp",      "1 tablespoon");
    add("tsp",       "1 teaspoon");

    // ── Energy / Power ──────────────────────────────────────────
    // `cal` (gram calorie, 4.184 J) and `Cal` (food calorie / kcal, 4184 J)
    // — keep them as single-word identifiers; math.js's createUnit silently
    // rejects names with underscores so `cal_unit` would never resolve.
    add("ps",        "735.49875 W");             // metric horsepower
    add("cal",       "4.184 J");                 // gram calorie
    add("Cal",       "4184 J");                  // kcal / food calorie
    add("MWh",       "3.6e9 J");
    add("GWh",       "3.6e12 J");

    // ── Force ───────────────────────────────────────────────────
    add("kp",        "9.80665 N");               // kilopond
    add("kgf",       "1 kp");
    add("lbf_alias", "4.4482216 N");

    // ── Pressure aliases ────────────────────────────────────────
    add("psf",       "47.880259 Pa");            // pounds per sq foot
    add("kpsi",      "6894757.293 Pa");

    // ── Acceleration ────────────────────────────────────────────
    add("g_force",   "9.80665 m / s^2");         // standard gravity

    // ── Density / concentration ─────────────────────────────────
    add("ppm",       "1e-6");
    add("ppb",       "1e-9");
    add("ppt",       "1e-12");

    // ── Cooking / counting ──────────────────────────────────────
    add("dozen",     "12");
    add("gross_count", "144");
    add("score",     "20");
    add("ream",      "500");
    add("baker_dozen", "13");

    // ── Data sizes (math.js uses kB/MB/etc.; KB is the conventional spelling) ──
    add("KB",        "1 kB");                    // KB ↔ kB (1000 bytes)
    add("KiB",       "1024 byte");
    // ── Data rates ──────────────────────────────────────────────
    add("kbps",      "1000 b / s");
    add("Mbps",      "1000000 b / s");
    add("Gbps",      "1000000000 b / s");
    add("KBps",      "1000 B / s");
    add("MBps",      "1000000 B / s");

    // ── Plural & natural-language aliases ───────────────────────
    // SuggestionEngine proposes plural forms ("pounds", "meters", …) because
    // they read naturally. math.js only knows the singular, so define each
    // plural as `1 <singular>`. Safe to redefine if math.js already has them.
    const plural = {
      // Mass (math.js uses lbm for pound-mass; ounce works as-is)
      kilograms: "kg", grams: "g", milligrams: "mg",
      pounds: "lbm", pound: "lbm",
      ounces: "ounce",
      tons: "ton", tonnes: "tonne",
      stones: "stone", carats: "ct",
      // Length
      meters: "m", metres: "m", kilometers: "km", centimeters: "cm", millimeters: "mm",
      inches: "inch", feet: "foot", yards: "yard", miles: "mile",
      // Volume
      liters: "L", litres: "L", milliliters: "mL", deciliters: "dL",
      gallons: "gallon", pints: "pint", quarts: "quart", cups: "cup",
      tablespoons: "tablespoon", teaspoons: "teaspoon",
      // Time — math.js bundles `second`/`seconds`, but the plural map is
      // the safest place to guarantee they exist as Unit definitions for
      // mathjs.evaluate to recognise inside function arguments like
      // `hms(3725 seconds)`.
      seconds: "s", second_unit: "s",
      minutes: "minute", hours: "hour", days: "day",
      // Temperature — math.js uses degC / degF / K; offer natural names.
      celsius:    "degC",
      fahrenheit: "degF",
      kelvin:     "K",
      // Force
      newtons: "N", dynes: "dyne",
      pound_force: "lbf",
      // Energy / Power
      joules: "J", kilojoules: "kJ",
      calories: "cal_unit", kilocalories: "Cal",
      watt_hours: "Wh", kilowatt_hours: "kWh",
      watts: "W", kilowatts: "kW", horsepower: "hp", metric_horsepower: "ps",
      // Frequency
      hertz: "Hz", kilohertz: "kHz", megahertz: "MHz", gigahertz: "GHz",
      // Data
      bytes: "B", bits: "b",
      kilobytes: "kB", megabytes: "MB", gigabytes: "GB", terabytes: "TB",
      kibibytes: "KiB", mebibytes: "MiB", gibibytes: "GiB", tebibytes: "TiB",
      kilobits: "kbit", megabits: "Mbit", gigabits: "Gbit",
      // Angle
      degrees: "deg", radians: "rad", arcminutes: "arcmin", arcseconds: "arcsec",
      // Speed
      knots: "kt",
      // Area
      square_meters: "m^2", square_feet: "ft^2", square_yards: "yd^2",
      hectares: "hectare", acres: "acre",
      // Length aliases
      light_year: "9.4607304725808e15 m"
    };
    Object.entries(plural).forEach(([word, def]) => {
      try { math.createUnit(word, `1 ${def}`, { override: true }); } catch (e) {}
    });
  },

  /**
   * Format a duration as hh:mm:ss.
   * Accepts either a math.js Unit with a time dimension, or a plain number
   * (treated as seconds). Negative durations render with a leading "-".
   */
  formatHMS(value, withSeconds) {
    let seconds;
    if (value && typeof value === "object" && typeof value.toNumber === "function") {
      try { seconds = value.toNumber("seconds"); }
      catch (e) { seconds = Number(value.valueOf?.() ?? value); }
    } else {
      seconds = Number(value);
    }
    if (!isFinite(seconds)) return String(value);
    const sign = seconds < 0 ? "-" : "";
    seconds = Math.abs(seconds);
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.round(seconds % 60);
    const pad = (n) => String(n).padStart(2, "0");
    return withSeconds
      ? `${sign}${pad(h)}:${pad(m)}:${pad(s)}`
      : `${sign}${pad(h)}:${pad(m)}`;
  },

  /**
   * Evaluate `expr` against the shared scope. Used by NumiEngine so that
   * variable assignments stick across lines (`a = 12; a * b`).
   */
  evalLine(expr) {
    return math.evaluate(expr, globalThis.tally.scope);
  },
};

// Register hms() / hm() as math.js functions so the preprocessor can rewrite
// `1.8h in hh:mm:ss` to `hms(1.8h)` and get a "01:48:00" string back.
try {
  math.import({
    hms: (v) => globalThis.tally.formatHMS(v, true),
    hm:  (v) => globalThis.tally.formatHMS(v, false),
  }, { override: true });
} catch (e) { /* ignore */ }

// Calculator-convention logarithms. math.js ships `log(x)` as the natural
// log and provides `log10`/`log2`, but Tally's documentation promises the
// schoolbook convention: `log(x)` = base-10, `ln(x)` = natural, and the
// two-arg `log(x, base)` = base-N. Override so the engine matches the docs.
// Capture the originals first — calling `math.log` from inside the override
// would otherwise recurse infinitely.
try {
  const _origLog   = math.log;
  const _origLog10 = math.log10;
  math.import({
    ln:  (x) => _origLog(x),
    log: (x, base) => base === undefined ? _origLog10(x) : _origLog(x, base),
  }, { override: true });
} catch (e) { /* ignore */ }

// ─── Finance helpers ─────────────────────────────────────────────────────
//
// All four functions accept a plain number OR a math.js Unit (currency) for
// the monetary argument and return the same shape. Rate math is done in
// plain JS because mathjs's pow() is overkill for these scalars; only the
// final scale uses math.multiply / math.add so unit dimensionality is
// preserved (`loan(300 000 USD, 5.5%, 30) → 1 703.37 USD/month`).

function _toNumberRate(r) {
  // mathjs parses `5.5%` as 0.055 already; this just defends against being
  // handed a Unit object by mistake (e.g. someone passes `5.5%` after a
  // unit conversion).
  if (r && typeof r === "object" && typeof r.toNumber === "function") {
    try { return r.toNumber(); } catch (e) { return Number(r.valueOf?.() ?? r); }
  }
  return Number(r);
}

function _toNumberCount(n) {
  // Accept `30` or `30 years` — strip the unit and treat as years.
  if (n && typeof n === "object" && typeof n.toNumber === "function") {
    try { return n.toNumber("years"); }
    catch (e) {
      try { return n.toNumber(); }
      catch (_) { return Number(n.valueOf?.() ?? n); }
    }
  }
  return Number(n);
}

/**
 * Monthly payment on an amortising loan.
 *   loan(principal, annualRate, termYears)
 * Standard formula: M = P·r·(1+r)^n / ((1+r)^n − 1)
 * with r = monthly rate, n = number of months.
 */
function loanPayment(principal, annualRate, termYears) {
  const r = _toNumberRate(annualRate) / 12;
  const n = _toNumberCount(termYears) * 12;
  if (n <= 0) return math.multiply(principal, 0);
  if (r === 0) return math.divide(principal, n);
  const factor = Math.pow(1 + r, n);
  const coeff = r * factor / (factor - 1);
  return math.multiply(principal, coeff);
}

/**
 * Total interest paid over the life of a loan = monthly × n − principal.
 */
function loanInterest(principal, annualRate, termYears) {
  const n = _toNumberCount(termYears) * 12;
  const m = loanPayment(principal, annualRate, termYears);
  return math.subtract(math.multiply(m, n), principal);
}

/**
 * Future value of a savings/investment plan.
 *   compound(principal, annualRate, years, [monthlyContribution=0])
 * FV = P·(1+r)^n + PMT·((1+r)^n − 1)/r,  r monthly, n in months.
 */
function compoundFV(principal, annualRate, years, monthlyContribution) {
  const r = _toNumberRate(annualRate) / 12;
  const n = _toNumberCount(years) * 12;
  const factor = Math.pow(1 + r, n);
  const fvP = math.multiply(principal, factor);
  if (monthlyContribution == null) return fvP;
  const annuityFactor = r === 0 ? n : (factor - 1) / r;
  const fvM = math.multiply(monthlyContribution, annuityFactor);
  return math.add(fvP, fvM);
}

/** Tip amount (just the tip, not the total). */
function tipAmount(bill, percent) {
  return math.multiply(bill, _toNumberRate(percent) / 100);
}

/** Per-person share when splitting a bill. */
function splitAmount(total, people) {
  return math.divide(total, _toNumberCount(people));
}

try {
  math.import({
    loan:        loanPayment,
    loanPayment: loanPayment,
    mortgage:    loanPayment,    // friendly alias
    loanInterest: loanInterest,
    compound:    compoundFV,
    fv:          compoundFV,     // financial alias
    futureValue: compoundFV,
    tip:         tipAmount,
    split:       splitAmount,
  }, { override: true });
} catch (e) { /* ignore */ }

// ─── Construction helpers ────────────────────────────────────────────────

/**
 * Format any length value as feet-and-inches: `20'9"`. Architects use this
 * constantly. Accepts a math.js Unit (any length) or a plain number
 * (interpreted as inches).
 */
function feetInches(value) {
  let totalInches;
  if (value && typeof value === "object" && typeof value.toNumber === "function") {
    try { totalInches = value.toNumber("inch"); }
    catch (e) { totalInches = Number(value.valueOf?.() ?? value); }
  } else {
    totalInches = Number(value);
  }
  if (!isFinite(totalInches)) return String(value);
  const sign = totalInches < 0 ? "-" : "";
  totalInches = Math.abs(totalInches);
  const feet = Math.floor(totalInches / 12);
  let inches = totalInches - feet * 12;
  // Round to the nearest 1/16"; architects rarely care below that.
  const sixteenths = Math.round(inches * 16);
  if (sixteenths === 192) {
    // 192/16 = 12 → rolls over to next foot.
    return `${sign}${feet + 1}'0"`;
  }
  inches = sixteenths / 16;
  if (Number.isInteger(inches)) {
    return `${sign}${feet}'${inches}"`;
  }
  // Show as decimal to two places — easy on the eyes vs. fractions.
  return `${sign}${feet}'${inches.toFixed(2).replace(/\.?0+$/, "")}"`;
}

/**
 * Stair calculator. Given total rise (m or units), total run (m), and an
 * optional max riser height (defaults to 180 mm — common residential limit
 * in EU codes), returns risers, riser height, tread depth, slope, and the
 * 2R+T comfort check.
 */
function stairs(rise, run, maxRiser) {
  // Coerce to metres for the math.
  const toMeters = (v) => {
    if (v && typeof v === "object" && typeof v.toNumber === "function") {
      try { return v.toNumber("m"); }
      catch (e) { return Number(v.valueOf?.() ?? v); }
    }
    return Number(v);
  };
  const riseM = toMeters(rise);
  const runM  = toMeters(run);
  const maxR  = maxRiser ? toMeters(maxRiser) : 0.180;     // 180 mm default
  const minRisers = Math.ceil(riseM / maxR);
  const riserM = riseM / minRisers;
  const treads = minRisers - 1;
  const treadM = treads > 0 ? runM / treads : 0;
  const slopeDeg = Math.atan2(riseM, runM) * 180 / Math.PI;
  // Blondel rule: 2R + T should be 600–630 mm. Frank-Blondel = 2R + T.
  const blondel = 2 * riserM + treadM;
  const comfortOK = blondel >= 0.60 && blondel <= 0.66;
  return {
    risers:   minRisers,
    treads:   treads,
    riserMm:  riserM * 1000,
    treadMm:  treadM * 1000,
    slopeDeg: slopeDeg,
    blondelMm: blondel * 1000,
    comfortOK: comfortOK,
  };
}

try {
  math.import({
    ftin:        feetInches,
    feetInches:  feetInches,
    stairs:      stairs,
  }, { override: true });
} catch (e) { /* ignore */ }

globalThis.tally.initBaseCurrencies();
globalThis.tally.initAviationUnits();
