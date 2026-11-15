import EventKit
import SwiftUI

struct TodayView: View {
    @ObservedObject private var svc = TodayService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            weather.frame(width: 300)
            calendar
        }
        .onAppear { svc.refresh() }
    }

    private var weather: some View {
        Card(title: svc.weather?.place ?? "Weather", trailing: AnyView(
            Button { svc.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlyphButtonStyle()))) {
            if let w = svc.weather {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: TodayService.symbol(w.code)).symbolRenderingMode(.multicolor).font(.system(size: 34))
                        VStack(alignment: .leading) {
                            Text("\(Int(w.temp.rounded()))°").font(.system(size: 34, weight: .semibold))
                            Text("Feels \(Int(w.feels.rounded()))° · wind \(Int(w.wind)) km/h")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(w.days, id: \.date) { d in
                            VStack(spacing: 4) {
                                Text(d.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                                Image(systemName: TodayService.symbol(d.code)).symbolRenderingMode(.multicolor)
                                Text("\(Int(d.hi.rounded()))°").font(.system(size: 11, weight: .semibold))
                                Text("\(Int(d.lo.rounded()))°").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Hint(svc.weatherStatus.isEmpty ? "Loading…" : svc.weatherStatus)
            }
        }
    }

    private var calendar: some View {
        Card(title: "Calendar") {
            let notDetermined = svc.calendarAccess == .notDetermined
            if notDetermined {
                VStack(spacing: 8) {
                    Text("See today's and tomorrow's events here.\nNotch reads your calendars on this Mac only.")
                        .font(Theme.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    Button("Show calendar") { svc.requestCalendar() }.buttonStyle(PillButtonStyle(tint: Theme.blue))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if svc.events.isEmpty {
                Hint(svc.calendarAccess == .denied || svc.calendarAccess == .restricted
                     ? "Calendar access is off (System Settings → Privacy → Calendars)." : "Nothing on your calendar today or tomorrow.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(svc.events, id: \.eventIdentifier) { e in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Event").font(Theme.caption).lineLimit(1)
                                    Text(Self.when(e)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func when(_ e: EKEvent) -> String {
        let day = Calendar.current.isDateInToday(e.startDate) ? "Today" : "Tomorrow"
        if e.isAllDay { return "\(day) · all day" }
        return "\(day) · \(e.startDate.formatted(date: .omitted, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
