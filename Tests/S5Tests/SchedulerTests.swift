import XCTest
@testable import S5Core

final class SchedulerTests: XCTestCase {
    /// Date locale (fuseau courant, comme le Scheduler) ; mars hors changement d'heure.
    private func date(day: Int = 10, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: day,
                                                   hour: hour, minute: minute, second: second))!
    }

    // MARK: - Intervalle

    func testIntervalFiresOnlyAfterDelay() {
        var scheduler = Scheduler(now: date(10, 0))
        let schedule = ScheduleConfig(intervalMinutes: 60)
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(10, 59, 59)))
        XCTAssertEqual(scheduler.shouldSync(schedule: schedule, now: date(11, 0)), "every 60 min")
    }

    func testIntervalRestartsFromLastSync() {
        var scheduler = Scheduler(now: date(10, 0))
        let schedule = ScheduleConfig(intervalMinutes: 30)
        scheduler.didStartSync(at: date(10, 20))
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(10, 40)))
        XCTAssertNotNil(scheduler.shouldSync(schedule: schedule, now: date(10, 50)))
    }

    func testLongSyncDoesNotRetriggerImmediately() {
        // Synchro de 18:44 à 22:20 avec un intervalle de 60 min et une heure fixe à 21:00 pendant la synchro.
        var scheduler = Scheduler(now: date(18, 0))
        let schedule = ScheduleConfig(intervalMinutes: 60, dailyTimes: ["21:00"])
        scheduler.didStartSync(at: date(18, 44))
        scheduler.didFinishSync(at: date(22, 20, 40))
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(22, 21, 8)))
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(23, 20)))
        XCTAssertEqual(scheduler.shouldSync(schedule: schedule, now: date(23, 20, 40)), "every 60 min")
    }

    func testIntervalDisabledWhenZeroOrAbsent() {
        var scheduler = Scheduler(now: date(10, 0))
        XCTAssertNil(scheduler.shouldSync(schedule: ScheduleConfig(intervalMinutes: 0), now: date(23, 0)))
        XCTAssertNil(scheduler.shouldSync(schedule: ScheduleConfig(), now: date(23, 30)))
        XCTAssertNil(scheduler.shouldSync(schedule: ScheduleConfig(intervalMinutes: -5), now: date(23, 45)))
    }

    // MARK: - Heures fixes

    func testDailyTimeFiresOnceWhenCrossed() {
        var scheduler = Scheduler(now: date(1, 50))
        let schedule = ScheduleConfig(dailyTimes: ["02:00"])
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(1, 59, 30)))
        XCTAssertEqual(scheduler.shouldSync(schedule: schedule, now: date(2, 0, 10)), "scheduled time 02:00")
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(2, 0, 40)))
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(15, 0)))
    }

    func testDailyTimeExactlyNowFires() {
        var scheduler = Scheduler(now: date(1, 59, 45))
        XCTAssertNotNil(scheduler.shouldSync(schedule: ScheduleConfig(dailyTimes: ["02:00"]), now: date(2, 0)))
    }

    func testDailyTimeBeforeLaunchDoesNotFire() {
        var scheduler = Scheduler(now: date(3, 0))
        XCTAssertNil(scheduler.shouldSync(schedule: ScheduleConfig(dailyTimes: ["02:00"]), now: date(3, 0, 30)))
    }

    func testMissedDailyTimeIsCaughtUpAfterSleep() {
        // Dernière vérification à 01:00, Mac en veille, réveil à 08:00.
        var scheduler = Scheduler(now: date(1, 0))
        let schedule = ScheduleConfig(dailyTimes: ["02:00"])
        XCTAssertEqual(scheduler.shouldSync(schedule: schedule, now: date(8, 0)), "scheduled time 02:00")
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(8, 0, 30)))
    }

    func testMissedDailyTimeCaughtUpAfterMidnight() {
        var scheduler = Scheduler(now: date(day: 10, 23, 20))
        let schedule = ScheduleConfig(dailyTimes: ["23:30"])
        XCTAssertEqual(scheduler.shouldSync(schedule: schedule, now: date(day: 11, 0, 10)), "scheduled time 23:30")
    }

    func testSleepAcrossSeveralDaysFiresOnce() {
        var scheduler = Scheduler(now: date(day: 10, 12, 0))
        let schedule = ScheduleConfig(dailyTimes: ["02:00"])
        XCTAssertNotNil(scheduler.shouldSync(schedule: schedule, now: date(day: 13, 9, 0)))
        XCTAssertNil(scheduler.shouldSync(schedule: schedule, now: date(day: 13, 9, 1)))
    }

    func testInvalidDailyTimeIsIgnored() {
        var scheduler = Scheduler(now: date(1, 0))
        XCTAssertNil(scheduler.shouldSync(schedule: ScheduleConfig(dailyTimes: ["25:00", "bad"]), now: date(8, 0)))
    }

    func testParseTime() {
        XCTAssertEqual(Scheduler.parseTime("02:00").map { [$0.0, $0.1] }, [2, 0])
        XCTAssertEqual(Scheduler.parseTime("23:59").map { [$0.0, $0.1] }, [23, 59])
        XCTAssertNil(Scheduler.parseTime("24:00"))
        XCTAssertNil(Scheduler.parseTime("12:60"))
        XCTAssertNil(Scheduler.parseTime("12"))
        XCTAssertNil(Scheduler.parseTime("1:2:3"))
        XCTAssertNil(Scheduler.parseTime(""))
        XCTAssertNil(Scheduler.parseTime("-1:00"))
    }
}
