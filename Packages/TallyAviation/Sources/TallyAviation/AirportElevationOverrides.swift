import Foundation

/// Field-elevation overrides for large airports whose runway-end
/// elevations are missing from the bundled `runways.csv`. Without these,
/// `NumiEngine.fieldElevationFt(forICAO:)` returns nil for these
/// airports — which is wrong for any commercial-airport query.
///
/// Source: the canonical OurAirports `airports.csv`
/// (`davidmegginson.github.io/ourairports-data`), `elevation_ft` column.
/// Same database we already use for lat/lon/IATA — authoritative for
/// our purposes. Values are in feet AGL above MSL, matching the
/// `runways.csv` column they substitute for.
///
/// Refresh recipe (run from repo root):
///
///     curl -sSL https://davidmegginson.github.io/ourairports-data/airports.csv \\
///       > /tmp/canonical_airports.csv
///     # Then re-run the generator that produced this file. See the
///     # accompanying conversation log for the script.
///
/// Coverage at write time: 74 of the 81 large airports whose runway
/// data was blank. The remaining 7 (BD-0044, BJ-0001, WPOC, YE-0012,
/// ZGZJ, ZLDH, ZSLG) are also blank in the canonical source — newer
/// or under-construction airports without published elevations.
public enum AirportElevationOverrides {
    /// ICAO ident → field elevation in feet (above mean sea level).
    public static let byIdent: [String: Int] = [
        "AU-0799":   262,   // [Duplicate] Western Sydney International Airport, Sydney, AU
        "DNAS":   305,   // Asaba International Airport, Asaba, NG
        "DNBC":  1965,   // Sir Abubakar Tafawa Balewa Bauchi State International Airport, Bauchi, NG
        "EES":   108,   // Berenice International Airport / Banas Cape Air Base, Berenice Troglodytica, EG
        "FDSK":  1092,   // King Mswati III International Airport, Mpaka, SZ
        "FNBJ":   550,   // Dr. Antonio Agostinho Neto International Airport, Luanda (Ícolo e Bengo), AO
        "FQTT":   525,   // Tete Airport, Tete, MZ
        "GMAZ":  2414,   // Zagora Airport, Zagora, MA
        "HAJJ":  5954,   // Gerad Wilwal International Airport, Jijiga, ET
        "HCMF":     3,   // Bender Qassim International Airport, Bosaso, SO
        "HESG":   322,   // Sohag International Airport, Suhaj, EG
        "HLGD":   267,   // Sirt International Airport / Ghardabiya Airbase, Sirt, LY
        "IN-0392":   644,   // Noida International Airport, Gautam Buddha Nagar, IN
        "KH-0001":    60,   // Dara Sakor International Airport, Ta Noun, KH
        "KH-0002":    20,   // Techo International Airport, Phnom Penh (Boeng Khyang), KH
        "LLER":   288,   // Ramon International Airport, Eilat, IL
        "LTCS":  2708,   // Şanlıurfa GAP Airport, Şanlıurfa, TR
        "MMTL":    66,   // Felipe Carrillo Puerto International Airport Tulum, Tulum, MX
        "NP-0003":  2595,   // Pokhara International Airport, Pokhara, NP
        "OCS":    55,   // Corisco International Airport, Corisco Island, GQ
        "OEAO":  2050,   // Al-Ula International Airport, Al-Ula, SA
        "OOSH":    20,   // Suhar International Airport, Suhar, OM
        "OPST":   837,   // Sialkot International Airport, Sialkot, PK
        "RJNS":   433,   // Mount Fuji Shizuoka Airport, Makinohara / Shimada, JP
        "RPLK":   319,   // Bicol International Airport, Legazpi, PH
        "RPVB":    82,   // Bacolod-Silay International Airport, Bacolod City, PH
        "RPVK":    14,   // Kalibo International Airport, Kalibo, PH
        "RSI":   140,   // Red Sea International Airport, Hanak, SA
        "SBBV":   276,   // Atlas Brasil Cantanhede International Airport, Boa Vista, BR
        "SBJP":   217,   // Presidente Castro Pinto International Airport, João Pessoa, BR
        "SBPV":   295,   // Governador Jorge Teixeira de Oliveira International Airport, Porto Velho, BR
        "SBRB":   633,   // Rio Branco-Plácido de Castro International Airport, Rio Branco, BR
        "SLAL": 10184,   // Alcantarí International Airport, Sucre, BO
        "SLOR": 12152,   // Juan Mendoza International Airport, Oruro, BO
        "TM-0002":   -26,   // Balkanabat International Airport, Balkanabat, TM
        "TRPG":   550,   // John A. Osborne Airport, Gerald's Park, MS
        "UACK":   900,   // Kokshetau International Airport, Kokshetau, KZ
        "UACP":   453,   // Petropavl International Airport, Petropavl, KZ
        "UAOL":   317,   // Baikonur Krayniy International Airport, Baikonur, KZ
        "URMG":   548,   // Akhmat Kadyrov Grozny International Airport, Grozny, RU
        "UTDT":  1473,   // Bokhtar International Airport, Bokhtar, TJ
        "UTFN":  1555,   // Namangan International Airport, Namangan, UZ
        "UTNN":   246,   // Nukus International Airport, Nukus, UZ
        "UUBW":   377,   // Zhukovsky International Airport, Moscow, RU
        "VAOZ":  1900,   // Nashik International Airport, Nashik, IN
        "VAPO":  1942,   // Pune International Airport, Pune, IN
        "VASU":    16,   // Surat International Airport, Surat, IN
        "VCRI":   157,   // Mattala Rajapaksa International Airport, Mattala, LK
        "VDSA":   191,   // Siem Reap-Angkor International Airport, Siem Reap, KH
        "VDSV":    33,   // Sihanouk International Airport, Preah Sihanouk, KH
        "VEBD":   412,   // Bagdogra Airport, Siliguri, IN
        "VICG":  1012,   // Shaheed Bhagat Singh International Airport, Chandigarh, IN
        "VIHR":   700,   // Maharaja Agrasen International Airport, Hisar, IN
        "VIHX":   790,   // Halwara International Airport, Halwara, IN
        "VN-0018":   249,   // Long Thanh International Airport (Under Construction), Ho Chi Minh City (Long Thanh), VN
        "VOKN":   330,   // Kannur International Airport, Kannur, IN
        "VTBS":     5,   // Suvarnabhumi Airport, Bangkok, TH
        "VVCT":     9,   // Can Tho International Airport, Can Tho, VN
        "VVPQ":    37,   // Phú Quốc International Airport, Phu Quoc Island, VN
        "VYNT":   302,   // Nay Pyi Taw International Airport, Naypyitaw, MM
        "WAHI":    24,   // Yogyakarta International Airport, Yogyakarta, ID
        "YSWS":   260,   // [Duplicate] Western Sydney International Airport, Sydney, AU
        "ZBDT":  3442,   // Datong Yungang International Airport, Datong, CN
        "ZBOW":  3321,   // Baotou Donghe International Airport, Baotou, CN
        "ZBYC":  1242,   // Yuncheng Yanhu International Airport, Yuncheng (Yanhu), CN
        "ZGDY":  8530,   // Zhangjiajie Hehua International Airport, Zhangjiajie (Yongding), CN
        "ZGSD":    23,   // Zhuhai Jinwan Airport, Zhuhai (Jinwan), CN
        "ZHEC":    86,   // Ezhou Huahu International Airport, Ezhou, CN
        "ZHLY":   840,   // Luoyang Beijiao Airport, Luoyang (Laocheng), CN
        "ZSFZ":    46,   // Fuzhou Changle International Airport, Fuzhou (Changle), CN
        "ZSWZ":    13,   // Wenzhou Longwan International Airport, Wenzhou (Longwan), CN
        "ZSYT":   154,   // Yantai Penglai International Airport, Yantai, CN
        "ZSZS":     6,   // Zhoushan Putuoshan International Airport, Zhoushan, CN
        "ZURK":  3782,   // Xigaze Peace Airport / Shigatse Air Base, Xigazê (Samzhubzê), CN
    ]
}
