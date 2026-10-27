import Foundation

enum Metric: String, CaseIterable, Identifiable {
    /// The state-line key the hub logs this metric under.
    var field: String {
        switch self {
        case .temperature: "temp_c"
        case .humidity: "hum_pct"
        case .pressure: "press_hpa"
        case .distance: "tof_mm"
        case .soundLevel: "sound_db"
        }
    }

    case temperature, humidity, pressure, distance, soundLevel

    var id: Self { self }

    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .pressure: "Pressure"
        case .distance: "Distance"
        case .soundLevel: "Sound level"
        }
    }

    var unit: String {
        switch self {
        case .temperature: "°C"
        case .humidity: "%"
        case .pressure: "hPa"
        case .distance: "mm"
        case .soundLevel: "dB"
        }
    }

    var symbolName: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .humidity: "humidity.fill"
        case .pressure: "barometer"
        case .distance: "ruler"
        case .soundLevel: "waveform"
        }
    }

    var fractionDigits: Int {
        switch self {
        case .temperature, .soundLevel, .pressure: 1
        case .humidity, .distance: 0
        }
    }

    func value(in sample: StateSample) -> Double? {
        switch self {
        case .temperature: sample.temperature
        case .humidity: sample.humidity
        case .pressure: sample.pressure
        case .distance: sample.distanceMm
        case .soundLevel: sample.soundLevel
        }
    }
}
