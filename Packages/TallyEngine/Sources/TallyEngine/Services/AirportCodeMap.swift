import Foundation

/// Cross-references the most-trafficked airports by 3-letter IATA and
/// 4-letter ICAO codes so users can type either form for METAR / TAF /
/// ATIS lookups (`METAR JFK` resolves the same as `METAR KJFK`).
///
/// The list mirrors `AirportDB`'s `byIATA` / `byICAO` in `CityResolver.swift`
/// — keep them in sync when adding new airports. If a code is missing
/// here, the upstream API will still receive whatever the user typed
/// (since `canonicalICAO` passes valid 4-letter input through), so the
/// only downside of an absent IATA entry is "IATA lookup failed";
/// no incorrect data is ever served.
public enum AirportCodeMap {

    /// Returns the canonical 4-letter ICAO for an arbitrary user input.
    /// Strips non-alphanumerics and uppercases; then:
    /// - a 3-letter IATA in the table → its ICAO equivalent
    /// - a 4-letter token → passed through (valid ICAO format)
    /// - everything else → nil (caller can surface "invalid code")
    public static func canonicalICAO(from raw: String) -> String? {
        let cleaned = raw.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
        if cleaned.count == 4 { return cleaned }
        if cleaned.count == 3 { return iataToICAO[cleaned] }
        return nil
    }

    /// Direct IATA → ICAO lookup. Returns nil for unknown codes.
    public static func icao(forIATA raw: String) -> String? {
        iataToICAO[raw.uppercased()]
    }

    /// Reverse lookup: ICAO → IATA. Useful for UI hints like
    /// `KJFK (JFK)`. Returns nil if there's no IATA equivalent.
    public static func iata(forICAO raw: String) -> String? {
        icaoToIATA[raw.uppercased()]
    }

    // MARK: - Data

    private static let iataToICAO: [String: String] = [
        // North America — US contiguous (K-prefix)
        "JFK": "KJFK", "LGA": "KLGA", "EWR": "KEWR",
        "BOS": "KBOS", "DCA": "KDCA", "IAD": "KIAD",
        "ATL": "KATL", "MIA": "KMIA", "MCO": "KMCO",
        "ORD": "KORD", "MDW": "KMDW", "DFW": "KDFW",
        "IAH": "KIAH", "AUS": "KAUS", "MSP": "KMSP",
        "DEN": "KDEN", "PHX": "KPHX", "LAS": "KLAS",
        "LAX": "KLAX", "SFO": "KSFO", "OAK": "KOAK",
        "SJC": "KSJC", "SAN": "KSAN", "SEA": "KSEA",
        "PDX": "KPDX", "SLC": "KSLC", "CLT": "KCLT",
        "PHL": "KPHL", "TPA": "KTPA", "FLL": "KFLL",
        "DAL": "KDAL", "HOU": "KHOU", "STL": "KSTL",
        "MCI": "KMCI", "MEM": "KMEM", "BWI": "KBWI",
        "BNA": "KBNA", "RDU": "KRDU", "CLE": "KCLE",
        "PIT": "KPIT", "DTW": "KDTW", "CMH": "KCMH",
        "IND": "KIND", "MKE": "KMKE", "SDF": "KSDF",
        "ABQ": "KABQ", "OKC": "KOKC", "ELP": "KELP",
        // US Alaska / Pacific (P-prefix)
        "ANC": "PANC", "FAI": "PAFA", "HNL": "PHNL",
        "OGG": "PHOG", "KOA": "PHKO", "LIH": "PHLI",
        // Canada (C-prefix)
        "YYZ": "CYYZ", "YUL": "CYUL", "YVR": "CYVR",
        "YYC": "CYYC", "YEG": "CYEG", "YOW": "CYOW",
        "YHZ": "CYHZ", "YWG": "CYWG", "YQB": "CYQB",
        "YHM": "CYHM",
        // Mexico (MM-prefix)
        "MEX": "MMMX", "CUN": "MMUN", "GDL": "MMGL",
        "MTY": "MMMY", "TIJ": "MMTJ", "SJD": "MMSD",
        "PVR": "MMPR", "CZM": "MMCZ", "ACA": "MMAA",
        // Caribbean / Central America
        "SJU": "TJSJ", "PUJ": "MDPC", "MBJ": "MKJS",
        "NAS": "MYNN", "STT": "TIST", "STX": "TISX",
        "AUA": "TNCA", "CUR": "TNCC", "SDQ": "MDSD",
        "PTY": "MPTO", "SJO": "MROC",
        // South America
        "GRU": "SBGR", "GIG": "SBGL", "CGH": "SBSP",
        "BSB": "SBBR", "EZE": "SAEZ", "AEP": "SABE",
        "SCL": "SCEL", "LIM": "SPJC", "BOG": "SKBO",
        "UIO": "SEQM", "CCS": "SVMI", "MVD": "SUMU",
        // UK / Ireland
        "LHR": "EGLL", "LGW": "EGKK", "STN": "EGSS",
        "LTN": "EGGW", "LCY": "EGLC", "SEN": "EGMC",
        "MAN": "EGCC", "EDI": "EGPH", "GLA": "EGPF",
        "BHX": "EGBB", "BRS": "EGGD", "NCL": "EGNT",
        "LPL": "EGGP", "LBA": "EGNM", "DUB": "EIDW",
        "ORK": "EICK", "SNN": "EINN", "BFS": "EGAA",
        // France
        "CDG": "LFPG", "ORY": "LFPO", "NCE": "LFMN",
        "MRS": "LFML", "LYS": "LFLL", "TLS": "LFBO",
        "BOD": "LFBD", "NTE": "LFRS",
        // Benelux
        "AMS": "EHAM", "RTM": "EHRD", "EIN": "EHEH",
        "BRU": "EBBR", "CRL": "EBCI", "LUX": "ELLX",
        // Germany / Austria / Switzerland
        "FRA": "EDDF", "MUC": "EDDM", "BER": "EDDB",
        "HAM": "EDDH", "DUS": "EDDL", "STR": "EDDS",
        "CGN": "EDDK", "NUE": "EDDN", "LEJ": "EDDP",
        "HAJ": "EDDV", "BRE": "EDDW",
        "VIE": "LOWW", "SZG": "LOWS", "INN": "LOWI",
        "ZRH": "LSZH", "GVA": "LSGG", "BSL": "LFSB",
        // Iberia
        "MAD": "LEMD", "BCN": "LEBL", "PMI": "LEPA",
        "AGP": "LEMG", "VLC": "LEVC", "SVQ": "LEZL",
        "LIS": "LPPT", "OPO": "LPPR", "FAO": "LPFR",
        // Italy / Greece / Turkey
        "FCO": "LIRF", "MXP": "LIMC", "LIN": "LIML",
        "BGY": "LIME", "VCE": "LIPZ", "NAP": "LIRN",
        "BLQ": "LIPE", "CTA": "LICC",
        "ATH": "LGAV", "SKG": "LGTS", "HER": "LGIR",
        "IST": "LTFM", "SAW": "LTFJ", "AYT": "LTAI",
        "ESB": "LTAC", "ADB": "LTBJ",
        // Eastern Europe
        "PRG": "LKPR", "WAW": "EPWA", "KRK": "EPKK",
        "BUD": "LHBP", "OTP": "LROP", "SOF": "LBSF",
        "BEG": "LYBE", "ZAG": "LDZA",
        // Nordic / Baltic
        "CPH": "EKCH", "BLL": "EKBI", "OSL": "ENGM",
        "BGO": "ENBR", "ARN": "ESSA", "GOT": "ESGG",
        "HEL": "EFHK", "KEF": "BIKF",
        "RIX": "EVRA", "TLL": "EETN", "VNO": "EYVI",
        // Russia / CIS
        "SVO": "UUEE", "DME": "UUDD", "VKO": "UUWW",
        "LED": "ULLI",
        // Middle East
        "DXB": "OMDB", "AUH": "OMAA", "SHJ": "OMSJ",
        "DOH": "OTHH", "RUH": "OERK", "JED": "OEJN",
        "BAH": "OBBI", "KWI": "OKBK", "MCT": "OOMS",
        "TLV": "LLBG", "AMM": "OJAI", "BEY": "OLBA",
        // Africa
        "CAI": "HECA", "HRG": "HEGN", "SSH": "HESH",
        "JNB": "FAOR", "CPT": "FACT", "DUR": "FALE",
        "NBO": "HKJK", "DAR": "HTDA", "ADD": "HAAB",
        "LOS": "DNMM", "ABV": "DNAA", "ACC": "DGAA",
        "CMN": "GMMN", "RAK": "GMMX", "TUN": "DTTA",
        // South Asia
        "DEL": "VIDP", "BOM": "VABB", "BLR": "VOBL",
        "MAA": "VOMM", "HYD": "VOHS", "CCU": "VECC",
        "KHI": "OPKC", "LHE": "OPLA", "ISB": "OPIS",
        "CMB": "VCBI", "KTM": "VNKT", "DAC": "VGHS",
        // SE Asia / Pacific
        "BKK": "VTBS", "DMK": "VTBD", "HKT": "VTSP",
        "CNX": "VTCC", "SGN": "VVTS", "HAN": "VVNB",
        "SIN": "WSSS", "KUL": "WMKK", "PEN": "WMKP",
        "CGK": "WIII", "DPS": "WADD", "SUB": "WARR",
        "MNL": "RPLL", "CEB": "RPVM",
        // East Asia
        "HKG": "VHHH", "MFM": "VMMC",
        "TPE": "RCTP", "TSA": "RCSS", "KHH": "RCKH",
        "ICN": "RKSI", "GMP": "RKSS", "PUS": "RKPK",
        "NRT": "RJAA", "HND": "RJTT", "KIX": "RJBB",
        "ITM": "RJOO", "FUK": "RJFF", "CTS": "RJCC",
        "OKA": "ROAH", "NGO": "RJGG",
        "PEK": "ZBAA", "PKX": "ZBAD", "PVG": "ZSPD",
        "SHA": "ZSSS", "CAN": "ZGGG", "SZX": "ZGSZ",
        "CTU": "ZUUU", "XIY": "ZLXY", "CKG": "ZUCK",
        // Oceania
        "SYD": "YSSY", "MEL": "YMML", "BNE": "YBBN",
        "PER": "YPPH", "ADL": "YPAD", "CNS": "YBCS",
        "OOL": "YBCG",
        "AKL": "NZAA", "WLG": "NZWN", "CHC": "NZCH",
        "ZQN": "NZQN",
        "NAN": "NFFN", "PPT": "NTAA",
    ]

    /// Reverse map, built once. ICAO → IATA for UI hints.
    private static let icaoToIATA: [String: String] = {
        var r: [String: String] = [:]
        for (iata, icao) in iataToICAO {
            r[icao] = iata
        }
        return r
    }()
}
