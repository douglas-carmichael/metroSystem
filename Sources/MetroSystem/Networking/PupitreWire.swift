import Foundation

// PUPITRE LINK WIRE.
//
// The PCC side of VALPupitreSim's PCC link (its PCC_API.md, protocol 1):
// newline-delimited JSON over TCP, advertised over Bonjour as
// `_valpupitre._tcp`, one object per line led by its "type". The cab owns
// the protocol. These types decode only what this PCC uses and ignore the
// rest, as the specification asks of clients, so additive changes on the
// cab side never break the link. Nothing here rides the peer wire.

enum PupitreWire {
    static let serviceType = "_valpupitre._tcp"
    static let protocolVersion = 1
    static let defaultPort: UInt16 = 5206
}

/// First pass over any line from a cab: just enough to pick the type.
struct CabEnvelope: Decodable {
    let type: String
}

/// A line description, as a cab reports it: in full in `hello` and the
/// `line` event, as just `id` + `loop` inside `state`.
struct CabLine: Decodable {
    let id: String
    var name: String?
    var lengthM: Double?
    let loop: Bool
}

/// `hello` -- sent by the cab as soon as the connection opens.
struct CabHello: Decodable {
    let `protocol`: Int
    let cab: Identity
    let authority: String
    let line: CabLine
    var geometry: Geometry?
    var limits: Limits?

    struct Identity: Decodable {
        let id: String
        let rame: String
        let name: String
    }

    /// Where the cab's rame lies around the position it reports (the
    /// centre of its car 1): its AV end `avEndM` above it, its AR end
    /// `arEndM` below.
    struct Geometry: Decodable {
        let lengthM: Double
        let avEndM: Double
        let arEndM: Double

        /// A VAL 206: two 12.8 m cars, centres 13.2 m apart.
        static let val206 = Geometry(lengthM: 26, avEndM: 6.4, arEndM: 19.6)
    }

    struct Limits: Decodable {
        var maxSpeedMS: Double?
        var paCruiseMS: Double?
    }
}

/// `state` -- the cab's full picture, at the rate this PCC asks for.
struct CabState: Decodable {
    let control: Control
    let line: CabLine
    let motion: Motion
    let cab: Cab
    let drive: Drive
    let voyants: Voyants
    let vigilance: Vigilance
    let emergencyBrake: EmergencyBrake
    var limit: Limit?
    let pa: PA
    let station: Station
    /// The cab's instruments; absent from cabs that predate it.
    var telemetry: Telemetry?

    struct Control: Decodable {
        let authority: String
        var holder: String?
        let you: Bool
    }

    struct Motion: Decodable {
        let positionM: Double
        let speedMS: Double
        let accelerationMS2: Double
        let sense: String
    }

    struct Cab: Decodable {
        let kg: Bool
        let kibs: Bool
        let kph: Bool
        let pa: Bool
        let nav: Bool
        let reverser: String
        let masterController: Double
    }

    struct Drive: Decodable {
        let paActive: Bool
        let demand: Double
    }

    struct Voyants: Decodable {
        let trac: Bool
        let frein: Bool
        let port: Bool
        let urg: Bool
    }

    struct Vigilance: Decodable {
        let timerS: Double
        let warning: Bool
    }

    struct EmergencyBrake: Decodable {
        let applied: Bool
        var cause: String?
    }

    struct Limit: Decodable {
        let positionM: Double
        let distanceM: Double
    }

    struct PA: Decodable {
        var target: Int?
        var berthed: Int?
        let dwellRemainingS: Double
    }

    struct Station: Decodable {
        var current: Int?
        var next: Int?
        var nextDistanceM: Double?
    }

    struct Telemetry: Decodable {
        let traction: Traction
        let auxiliaries: Auxiliaries

        struct Traction: Decodable {
            let lineVoltageV: Double
            let lineCurrentA: Double
            let armatureCurrentA: Double
            let fieldCurrentA: Double
            let chopperDuty: Double
            let tractionCurrentA: Double
            let torquePct: Double
        }

        struct Auxiliaries: Decodable {
            let converterV: Double
            let batteryV: Double
            let lightingA: Double
            let compressor: Bool
            let mainReservoirBar: Double
            let brakeBoxC: Double
        }
    }
}

/// `event` -- which fields are present depends on `event`.
struct CabEvent: Decodable {
    let event: String
    var rame: String?
}

/// `result` -- the answer to a request this PCC sent.
struct CabResult: Decodable {
    var id: String?
    let ok: Bool
    var error: String?
    var message: String?
    var holder: String?
}

/// A command argument, as the cab reads it.
enum CabValue: Encodable {
    case bool(Bool)
    case number(Double)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b):   try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }
}

/// The line this node lends a cab: its loop, stations and cantons.
struct CabLineOut: Encodable {
    let id: String
    let name: String
    let lengthM: Double
    let loop: Bool
    let stations: [Station]
    let blocks: [Block]

    struct Station: Encodable {
        let name: String
        let positionM: Double
    }

    struct Block: Encodable {
        let id: Int
        let startM: Double
        let lengthM: Double
    }
}

/// One of the other rames on the line, as a `traffic` message reports it
/// to a cab: measured the way the cab measures itself.
struct CabTrafficTrain: Encodable {
    let rame: String
    let positionM: Double
    let speedMS: Double
    let sense: String
}

/// Every request this PCC sends, as one flat envelope; absent fields are
/// left out of the JSON.
struct CabRequest: Encodable {
    let type: String
    var id: String? = nil
    var `protocol`: Int? = nil
    var name: String? = nil
    var stateRateHz: Double? = nil
    var force: Bool? = nil
    var command: String? = nil
    var value: CabValue? = nil
    var line: CabLineOut? = nil
    var positionM: Double? = nil
    var trains: [CabTrafficTrain]? = nil
}
