import CoreLocation
import EventKit
import Foundation

struct Weather {
    var place = ""
    var temp: Double = 0, feels: Double = 0, wind: Double = 0, code = 0
    var days: [(date: Date, code: Int, hi: Double, lo: Double)] = []
}

/// Weather from Open-Meteo (free, no key) for a city you type, or your location if you opt in.
/// Calendar from EventKit, asked only when you press "Show calendar".
@MainActor
final class TodayService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TodayService()

    @Published private(set) var weather: Weather?
    @Published private(set) var weatherStatus = ""
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()
    private var location: CLLocationManager?
    private var lastFetch: Date?

    func refresh(force: Bool = false) {
        loadEvents()
        if !force, let l = lastFetch, Date().timeIntervalSince(l) < 600, weather != nil { return }
        let cfg = Store.shared.config
        guard cfg.netWeather else { weatherStatus = "Weather is off in Settings → Privacy"; return }
        if cfg.useLocation {
            let m = location ?? CLLocationManager()
            m.delegate = self
            location = m
            m.requestWhenInUseAuthorization()   // no-op once decided; macOS shows the prompt the first time
            m.requestLocation()
            weatherStatus = "Finding your location…"
        } else if !cfg.city.isEmpty {
            Task { await fetch(city: cfg.city) }
        } else {
            weatherStatus = "Set a city in Settings to see the weather"
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in await TodayService.shared.fetch(lat: c.latitude, lon: c.longitude, place: "Current location") }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let s = TodayService.shared
            let city = Store.shared.config.city
            if city.isEmpty { s.weatherStatus = "Location unavailable. Allow it in System Settings or set a city." }
            else { await s.fetch(city: city) }
        }
    }

    private func fetch(city: String) async {
        weatherStatus = "Loading…"
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        let j: Any? = try? await Net.json(c.url!)
        guard let lat = j["results"][0]["latitude"].num, let lon = j["results"][0]["longitude"].num else {
            weatherStatus = "Couldn't find “\(city)”"; return
        }
        await fetch(lat: lat, lon: lon, place: j["results"][0]["name"].str ?? city)
    }

    private func fetch(lat: Double, lon: Double, place: String) async {
        let unit = Store.shared.config.celsius ? "celsius" : "fahrenheit"
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=5&temperature_unit=\(unit)")!
        do {
            let j: Any? = try await Net.json(url)
            var w = Weather(place: place)
            w.temp = j["current"]["temperature_2m"].num ?? 0
            w.feels = j["current"]["apparent_temperature"].num ?? 0
            w.wind = j["current"]["wind_speed_10m"].num ?? 0
            w.code = Int(j["current"]["weather_code"].num ?? 0)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let times = j["daily"]["time"].arr
            for i in times.indices {
                guard let d = (times[i] as? String).flatMap(f.date) else { continue }
                w.days.append((d, Int(j["daily"]["weather_code"][i].num ?? 0),
                               j["daily"]["temperature_2m_max"][i].num ?? 0, j["daily"]["temperature_2m_min"][i].num ?? 0))
            }
            weather = w; weatherStatus = ""; lastFetch = Date()
        } catch {
            weatherStatus = "Weather unavailable (\(error.localizedDescription))"
        }
    }

    // MARK: Calendar

    func requestCalendar() {
        let done: @Sendable (Bool, Error?) -> Void = { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    TodayService.shared.calendarAccess = EKEventStore.authorizationStatus(for: .event)
                    TodayService.shared.loadEvents()
                }
            }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion: done) }
        else { store.requestAccess(to: .event, completion: done) }
    }

    private func loadEvents() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        if #available(macOS 14.0, *) { granted = calendarAccess == .fullAccess } else { granted = calendarAccess == .authorized }
        guard granted else { return }
        let store = store
        Task.detached {
            let start = Calendar.current.startOfDay(for: Date())
            let end = start.addingTimeInterval(2 * 86400)
            let evs = store.events(matching: store.predicateForEvents(withStart: Date().addingTimeInterval(-3600), end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
            await MainActor.run { TodayService.shared.events = Array(evs.prefix(12)) }
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
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
