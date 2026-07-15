import AppKit
import CoreServices
import Darwin
import Foundation

enum AppleEventPermission {
    static func canSendWithoutPrompt(to bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            typeWildCard,
            typeWildCard,
            false
        ) == noErr
    }
}

struct ShelfDropItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }
    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

struct ShelfReminderItem: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ShelfSystemHealth {
    var cpuUsage = 0.0
    var memoryUsage = 0.0
    var storageUsage = 0.0
}

struct ShelfWeather {
    let locationName: String
    let temperature: Double
    let apparentTemperature: Double
    let high: Double
    let low: Double
    let weatherCode: Int
    let unit: String

    var symbol: String {
        switch weatherCode {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

@MainActor
enum ReminderAppleScript {
    static func pendingReminders(limit: Int = 4, requestPermission: Bool = true) -> [ShelfReminderItem]? {
        if !requestPermission,
           !AppleEventPermission.canSendWithoutPrompt(to: "com.apple.reminders") {
            return nil
        }
        let source = """
        tell application "Reminders"
            set output to {}
            repeat with reminderList in lists
                repeat with itemReminder in (reminders of reminderList whose completed is false)
                    set end of output to {id of itemReminder as text, name of itemReminder as text}
                    if (count of output) is greater than or equal to \(limit) then return output
                end repeat
            end repeat
            return output
        end tell
        """
        guard let result = execute(source) else { return nil }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let item = result.atIndex(index),
                  let id = item.atIndex(1)?.stringValue,
                  let name = item.atIndex(2)?.stringValue else { return nil }
            return ShelfReminderItem(id: id, name: name)
        }
    }

    static func add(_ name: String) -> Bool {
        let safeName = escaped(name)
        let source = """
        tell application "Reminders"
            make new reminder in default list with properties {name:"\(safeName)"}
        end tell
        """
        return execute(source) != nil
    }

    static func complete(id: String) -> Bool {
        let safeID = escaped(id)
        let source = """
        tell application "Reminders"
            repeat with reminderList in lists
                set matches to (reminders of reminderList whose id is "\(safeID)")
                if (count of matches) > 0 then
                    set completed of item 1 of matches to true
                    return true
                end if
            end repeat
            return false
        end tell
        """
        return execute(source)?.booleanValue ?? false
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

enum ShortcutCommand {
    static func list() -> [String] {
        guard let output = run(arguments: ["list"]) else { return [] }
        return output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @discardableResult
    static func launch(name: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private static func run(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

final class SystemHealthReader {
    private var previousCPUTicks: (total: UInt64, idle: UInt64)?

    func snapshot() -> ShelfSystemHealth {
        ShelfSystemHealth(
            cpuUsage: readCPUUsage(),
            memoryUsage: readMemoryUsage(),
            storageUsage: readStorageUsage()
        )
    }

    private func readCPUUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let current = (total: user + system + idle + nice, idle: idle)
        defer { previousCPUTicks = current }
        guard let previousCPUTicks,
              current.total > previousCPUTicks.total else { return 0 }
        let totalDelta = current.total - previousCPUTicks.total
        let idleDelta = current.idle - previousCPUTicks.idle
        return min(max(Double(totalDelta - idleDelta) / Double(totalDelta), 0), 1)
    }

    private func readMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let usedPages = UInt64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        return totalBytes > 0 ? min(Double(usedBytes) / Double(totalBytes), 1) : 0
    }

    private func readStorageUsage() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0 else { return 0 }
        return min(max(1 - Double(available) / Double(total), 0), 1)
    }
}

enum ShelfWeatherService {
    private struct GeocodeResponse: Decodable {
        let results: [Place]?
    }

    private struct Place: Decodable {
        let name: String
        let admin1: String?
        let latitude: Double
        let longitude: Double
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    static func fetch(location: String) async throws -> ShelfWeather {
        var geocode = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geocode.queryItems = [
            URLQueryItem(name: "name", value: location),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (placeData, _) = try await URLSession.shared.data(from: geocode.url!)
        guard let place = try JSONDecoder().decode(GeocodeResponse.self, from: placeData).results?.first else {
            throw WeatherError.locationNotFound
        }

        let usesFahrenheit = Locale.current.measurementSystem == .us
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: usesFahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        let (forecastData, _) = try await URLSession.shared.data(from: forecast.url!)
        let response = try JSONDecoder().decode(ForecastResponse.self, from: forecastData)
        guard let high = response.daily.temperature_2m_max.first,
              let low = response.daily.temperature_2m_min.first else { throw WeatherError.invalidResponse }
        let displayName = [place.name, place.admin1].compactMap { $0 }.joined(separator: ", ")
        return ShelfWeather(
            locationName: displayName,
            temperature: response.current.temperature_2m,
            apparentTemperature: response.current.apparent_temperature,
            high: high,
            low: low,
            weatherCode: response.current.weather_code,
            unit: usesFahrenheit ? "°F" : "°C"
        )
    }

    enum WeatherError: LocalizedError {
        case locationNotFound
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .locationNotFound: "Location not found"
            case .invalidResponse: "Weather is unavailable"
            }
        }
    }
}
