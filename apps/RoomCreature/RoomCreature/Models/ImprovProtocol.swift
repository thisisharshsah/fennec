import CoreBluetooth
import Foundation

/// UUIDs of the Improv Wi-Fi BLE service and our additions (docs/protocol.md, "Onboarding over Bluetooth").
/// CBUUID is not Sendable, and all Bluetooth work happens on the main actor, so the table lives there too.
@MainActor
enum ImprovUUID {
    static let service = CBUUID(string: "00467768-6228-2272-4663-277478268000")
    static let state = CBUUID(string: "00467768-6228-2272-4663-277478268001")
    static let error = CBUUID(string: "00467768-6228-2272-4663-277478268002")
    static let rpcCommand = CBUUID(string: "00467768-6228-2272-4663-277478268003")
    static let rpcResult = CBUUID(string: "00467768-6228-2272-4663-277478268004")
    static let capabilities = CBUUID(string: "00467768-6228-2272-4663-277478268005")
    static let networkCount = CBUUID(string: "00467768-6228-2272-4663-277478268010")
    static let networkIndex = CBUUID(string: "00467768-6228-2272-4663-277478268011")
    static let networkEntry = CBUUID(string: "00467768-6228-2272-4663-277478268012")
    static let bridgeAddress = CBUUID(string: "00467768-6228-2272-4663-277478268013")

    /// Units in setup mode advertise as `creature-XXXX`.
    static let namePrefix = "creature-"

    /// Characteristics we subscribe to after connecting.
    static let notified: [CBUUID] = [state, error, rpcResult]
}

enum ImprovError: LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case missingCharacteristic(String)
    case notWritable(String)
    case busy
    case timedOut
    case disconnected
    case payloadTooLong

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is not available."
        case .notConnected: "No creature is connected."
        case .missingCharacteristic(let uuid): "The creature does not offer characteristic \(uuid)."
        case .notWritable(let uuid): "Characteristic \(uuid) cannot be written."
        case .busy: "Another request is still in flight."
        case .timedOut: "The creature did not answer in time."
        case .disconnected: "The creature disconnected."
        case .payloadTooLong: "The network name or password is too long."
        }
    }
}

/// Pure encoding and decoding of Improv RPC packets, kept free of CoreBluetooth so the
/// byte layout can be eyeballed:
///
///     command packet:  cmd, len, data..., checksum
///     result packet:   cmd, len, (str_len, str_bytes...)..., checksum
///     checksum:        sum of all preceding bytes & 0xFF
///
/// Wi-Fi settings (0x01) data = ssid_len, ssid..., pass_len, pass...
/// Identify (0x02) has no data: the packet is 0x02 0x00 0x02.
enum ImprovPacket {
    enum Command: UInt8 {
        case wifiSettings = 0x01
        case identify = 0x02
    }

    struct Result: Equatable, Sendable {
        let command: UInt8
        let strings: [String]
    }

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
    }

    static func packet(_ command: Command, data: [UInt8]) throws -> Data {
        guard data.count <= Int(UInt8.max) else { throw ImprovError.payloadTooLong }
        var bytes: [UInt8] = [command.rawValue, UInt8(data.count)]
        bytes.append(contentsOf: data)
        bytes.append(checksum(bytes))
        return Data(bytes)
    }

    /// `01 len ssid_len ssid... pass_len pass... checksum`
    static func wifiSettings(ssid: String, password: String) throws -> Data {
        let ssidBytes = Array(ssid.utf8)
        let passBytes = Array(password.utf8)
        guard ssidBytes.count <= Int(UInt8.max), passBytes.count <= Int(UInt8.max) else {
            throw ImprovError.payloadTooLong
        }
        var data: [UInt8] = [UInt8(ssidBytes.count)]
        data.append(contentsOf: ssidBytes)
        data.append(UInt8(passBytes.count))
        data.append(contentsOf: passBytes)
        return try packet(.wifiSettings, data: data)
    }

    /// `02 00 02`
    static func identify() throws -> Data {
        try packet(.identify, data: [])
    }

    /// Decodes a result packet; nil when it is too short, the checksum is wrong, or a string overruns.
    static func parseResult(_ data: Data) -> Result? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        let length = Int(bytes[1])
        let end = 2 + length
        guard bytes.count >= end + 1, checksum(bytes[0..<end]) == bytes[end] else { return nil }
        var strings: [String] = []
        var index = 2
        while index < end {
            let count = Int(bytes[index])
            index += 1
            guard index + count <= end else { return nil }
            strings.append(String(decoding: bytes[index..<(index + count)], as: UTF8.self))
            index += count
        }
        return Result(command: bytes[0], strings: strings)
    }
}

/// Improv current-state byte (characteristic ...8001).
enum ImprovState: UInt8, Sendable {
    case authorizationRequired = 0x01
    case authorized = 0x02
    case provisioning = 0x03
    case provisioned = 0x04
}

/// Improv error byte (characteristic ...8002).
enum ImprovDeviceError {
    static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x01: "The creature rejected the request (invalid packet)."
        case 0x02: "The creature does not understand this command."
        case 0x03: "Unable to connect. Check the password and that the network is in range."
        case 0x04: "The creature is not authorized to be set up right now."
        default: "The creature reported an unknown error (0x\(String(code, radix: 16, uppercase: true)))."
        }
    }
}

/// One entry of the unit's network list, from the text `secured|rssi|ssid`.
struct ImprovNetwork: Identifiable, Hashable, Sendable {
    let ssid: String
    let rssi: Int
    let secured: Bool
    /// The network this creature was last connected to (marked by the unit with an `s`).
    let lastUsed: Bool

    var id: String { ssid }

    /// Parses `1|-58|HomeNet` (secured, rssi, name). The name comes last so a short read only
    /// shortens it; it may itself contain `|`. Empty names are dropped.
    init?(entry: String) {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let rssi = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let ssid = parts[2...].joined(separator: "|")
        guard !ssid.isEmpty else { return nil }
        self.ssid = ssid
        self.rssi = rssi
        let flags = parts[0].trimmingCharacters(in: .whitespaces)
        self.secured = flags.first != "0"
        self.lastUsed = flags.contains("s")
    }

    /// Signal strength as 0...1 for a variable-value SF Symbol (-90 dBm and below is 0, -40 and above is 1).
    var signalLevel: Double {
        min(1, max(0, Double(rssi + 90) / 50))
    }
}
