import Foundation

/// Décide quand lancer une synchro : toutes les N minutes et/ou à heures fixes.
/// Vérifié toutes les 30 s ; une heure fixe manquée pendant la veille est rattrapée au réveil.
public struct Scheduler {
    public private(set) var lastSyncStart: Date
    private var lastCheck: Date

    public init(now: Date = Date()) {
        lastSyncStart = now
        lastCheck = now
    }

    public mutating func didStartSync(at date: Date = Date()) {
        lastSyncStart = date
    }

    /// Fin de synchro : l'intervalle repart de maintenant, et les heures fixes passées pendant la synchro
    /// ne la relancent pas aussitôt (elle vient de tourner).
    public mutating func didFinishSync(at date: Date = Date()) {
        lastSyncStart = date
        lastCheck = date
    }

    /// Renvoie la raison de lancer une synchro maintenant (en anglais, pour le journal), ou nil.
    public mutating func shouldSync(schedule: ScheduleConfig, now: Date = Date()) -> String? {
        defer { lastCheck = now }
        if let minutes = schedule.intervalMinutes, minutes > 0,
           now.timeIntervalSince(lastSyncStart) >= Double(minutes) * 60 {
            return "every \(minutes) min"
        }
        for time in schedule.dailyTimes ?? [] {
            guard let (h, m) = Self.parseTime(time) else { continue }
            // On vérifie aujourd'hui et hier (cas d'un réveil après minuit).
            for dayOffset in [0, -1] {
                guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now),
                      let fire = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)
                else { continue }
                if fire <= now && fire > lastCheck { return "scheduled time \(time)" }
            }
        }
        return nil
    }

    public static func parseTime(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
