import EventKit
import SwiftUI

struct TodayView: View {
    @ObservedObject private var svc = TodayService.shared
    @ObservedObject private var tracker = TrackerService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            weather.frame(width: 300)
            calendar
        }
        .onAppear { svc.refresh(); tracker.refresh() }
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
                                .font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.55))
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(w.days, id: \.date) { d in
                            VStack(spacing: 4) {
                                Text(d.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.6))
                                Image(systemName: TodayService.symbol(d.code)).symbolRenderingMode(.multicolor)
                                Text("\(Int(d.hi.rounded()))°").font(.system(size: 12, weight: .semibold))
                                Text("\(Int(d.lo.rounded()))°").font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5))
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
        Card(title: tracker.followUps.isEmpty ? "Calendar" : "Calendar & follow-ups") {
            let notDetermined = svc.calendarAccess == .notDetermined && tracker.followUps.isEmpty
            if notDetermined {
                VStack(spacing: 8) {
                    Text("See today's and tomorrow's events here.\nNotch reads your calendars on this Mac only.")
                        .font(Theme.caption).foregroundStyle(Theme.ink.opacity(0.55)).multilineTextAlignment(.center)
                    Button("Show calendar") { svc.requestCalendar() }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if svc.events.isEmpty && tracker.followUps.isEmpty {
                Hint(svc.calendarAccess == .denied || svc.calendarAccess == .restricted
                     ? "Calendar access is off (System Settings → Privacy → Calendars)." : "Nothing on your calendar today or tomorrow.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // Job tracker follow-ups (from the sheet in Settings), above the events.
                        ForEach(Array(tracker.followUps.enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Follow up: \(f.company)").font(Theme.caption).lineLimit(1)
                                    Text(Self.due(f.date) + (f.status.isEmpty ? "" : " · \(f.status)"))
                                        .font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(1)
                                }
                            }
                        }
                        ForEach(svc.events, id: \.eventIdentifier) { e in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Event").font(Theme.caption).lineLimit(1)
                                    Text(Self.when(e)).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func due(_ d: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day ?? 0
        return n < 0 ? "\(-n) day\(n == -1 ? "" : "s") overdue" : n == 0 ? "Today" : n == 1 ? "Tomorrow" : "In \(n) days"
    }

    static func when(_ e: EKEvent) -> String {
        let day = Calendar.current.isDateInToday(e.startDate) ? "Today" : "Tomorrow"
        if e.isAllDay { return "\(day) · all day" }
        return "\(day) · \(e.startDate.formatted(date: .omitted, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
