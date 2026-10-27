import Foundation

struct WifiStatus: Equatable, Sendable {
    var module: String?
    var ssid: String?
    var joined: Bool?
    var ip: String?
    var rssi: Int?
    var bridgeHost: String?
    var bridgePort: Int?
    var bridgeConnected: Bool?
    var updatedAt: Date

    init(_ info: WifiInfoMessage, previous: WifiStatus?, at time: Date) {
        module = info.module ?? previous?.module
        ssid = info.ssid
        joined = info.joined
        ip = info.ip
        rssi = previous?.rssi
        bridgeHost = previous?.bridgeHost
        bridgePort = previous?.bridgePort
        bridgeConnected = info.bridge
        updatedAt = time
    }

    init(_ status: StatusMessage, previous: WifiStatus?, at time: Date) {
        module = previous?.module
        ssid = status.ssid
        joined = status.joined
        ip = status.ip
        rssi = status.rssi.map { Int($0.rounded()) }
        bridgeHost = status.bridgeHost
        bridgePort = status.bridgePort
        bridgeConnected = status.bridge
        updatedAt = time
    }
}
