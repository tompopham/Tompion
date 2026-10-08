// Tompion: read and write macOS Calendar events from the command line through
// EventKit, the system's own calendar framework. It does in seconds what
// Calendar's AppleScript scripting takes minutes over (see the README).
//
//   tompion [--out <path>] calendars                      names of every event calendar, as JSON
//   tompion [--out <path>] read <calendar> [<from> <to>]  events in one calendar, as JSON
//   tompion [--out <path>] create <spec.json>             makes the events a spec lists
//   tompion [--out <path>] delete <spec.json>             deletes the events a spec lists
//   tompion -h | --help                                   this usage and where the README is
//   tompion --version                                     "tompion" and the version
//
// -h, --help and --version must come alone. They print plain text to stdout and
// exit 0 before --out, the command or the calendar is looked at, so they work
// run directly from a shell.
//
// Exit codes: 0 done. 1 failed, with the reason on stderr (or in <path>.err).
// 2 a bad --out path, or the answer could not be written (to <path> or stdout);
// the reason goes to stderr only, as there is nowhere safe to write it. 3 the
// caller had given up before create or delete committed, so nothing was
// committed and nothing written.
//
// --out <path> must be absolute, in a folder that already exists and can be
// written in, and not itself a folder; nor may <path>.err or <path>.part be one.
// At startup Tompion removes any <path>, <path>.err or <path>.part left by an
// earlier run. The answer is written to <path>.part (mode 0600) and renamed onto
// <path> in one step, an error onto <path>.err the same way, so a caller waits
// for either file; `open -W` does not always wait for a helper that finishes
// this quickly. If the folder of <path> has gone by the time create or delete is
// about to commit, the caller has given up, and Tompion stops with exit code 3.
//
// Every check that needs no calendar (the command, its arguments, --out, read's
// dates, a whole create or delete spec) is made before Tompion asks for calendar
// access, so a typo never brings up the permission dialog. It waits at most 100
// seconds for the answer to that dialog.
//
// read: <from> and <to> are YYYY-MM-DD in local time, <to> inclusive, the window at
// most four years counted as 1461 x 24 hours (so a 1461-day window that gains an
// hour when the clocks go back is refused). Without them: one year back to two
// years ahead. "alarms" lists relative alarms only, in minutes; fixed-time and
// location alarms are left out.
//
// create: {"calendar": name, "events": [{"title": string, "start": [6 ints],
//   "end": [6 ints], "note": string, "allday": bool, "alarms": [ints]}]}
//   start and end are [year, month, day, hour, minute, second], a time that really
//   happens locally, with end not before start. note, allday (default false) and
//   alarms (minutes from the start, negative is before, within ten years) are
//   optional. Any other field is refused. The whole spec is checked first; on the
//   first problem nothing is created. The answer is one {"title", "id", "status"}
//   per event, in order: "ok" with the new id, or "error: ..." with a null id.
// delete: {"calendar": name, "ids": [eventIdentifier, ...]}; any other field is
//   refused. The answer is one [id, status] per id; repeating events and events
//   in other calendars are left alone.
//
// Writes are saved with commit: false and committed once at the end.
//
// Run it as an app, through `open`, not directly from a shell: see README.md.
// Build: see build.sh beside this file.
import EventKit
import Foundation

// The one place the version is kept. CFBundleShortVersionString in Info.plist must
// match it; build.sh refuses to build if it does not.
let version = "1.0.0"

let usage = "usage: tompion [--out <path>] calendars | read <calendar> [<from> <to>] | create <spec.json> | delete <spec.json>"

// One fixed calendar for building dates and doing sums with them, whatever the
// Mac's own calendar setting is (Calendar.current could be Buddhist or Japanese).
let greg: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()

// MARK: - Output

var outPath: String? = nil   // set by --out

func errnoText() -> String { String(cString: strerror(errno)) }

// Writes all of data to a file descriptor; false if it could not.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        guard var p = buf.baseAddress else { return true }   // nothing to write
        var left = buf.count
        while left > 0 {
            let n = write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            p += n
            left -= n
        }
        return true
    }
}

func toStderr(_ s: String) { _ = writeAll(2, Data((s + "\n").utf8)) }

// Puts data at target in one step: writes it to part, a new file with mode 0600,
// then rename(2)s that onto target, so a caller never sees half a file. If either
// step fails there is nowhere safe left to write, so the message and the reason go
// to stderr and Tompion exits with 2.
func deliver(_ data: Data, to target: String, via part: String) {
    func giveUp(_ reason: String) -> Never {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        toStderr(text)
        toStderr("tompion: could not write \(target): \(reason)")
        exit(2)
    }
    let fd = open(part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { giveUp("cannot create \(part): \(errnoText())") }
    guard writeAll(fd, data) else {
        let why = errnoText()
        close(fd); unlink(part)
        giveUp("cannot write \(part): \(why)")
    }
    guard close(fd) == 0 else {
        let why = errnoText()
        unlink(part)
        giveUp("cannot write \(part): \(why)")
    }
    guard rename(part, target) == 0 else {
        let why = errnoText()
        unlink(part)
        giveUp("cannot rename \(part) to \(target): \(why)")
    }
}

func fail(_ msg: String) -> Never {
    if let p = outPath { deliver(Data((msg + "\n").utf8), to: p + ".err", via: p + ".part") }
    else { toStderr(msg) }
    exit(1)
}

func out(_ obj: Any) {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
        fail("could not turn the answer into JSON")
    }
    if let p = outPath { deliver(data, to: p, via: p + ".part") }
    else {
        guard writeAll(1, data + Data("\n".utf8)) else {
            toStderr("tompion: could not write the answer to stdout: \(errnoText())")
            exit(2)
        }
    }
}

// Checks the --out path and clears away the files an earlier run may have left.
// Until this has passed there is nowhere safe to write, so a problem goes to
// stderr only, with exit code 2.
func setUpOut(_ path: String) {
    func bad(_ why: String) -> Never {
        toStderr("tompion: bad --out path \"\(path)\": \(why)")
        exit(2)
    }
    guard path.hasPrefix("/") else { bad("it must be absolute") }
    let name = (path as NSString).lastPathComponent
    guard !path.hasSuffix("/"), name != ".", name != ".." else { bad("it must name a file, not a folder") }
    let parent = (path as NSString).deletingLastPathComponent
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
        bad("its folder \(parent) does not exist, or is not a folder")
    }
    guard access(parent, W_OK | X_OK) == 0 else { bad("cannot write in \(parent): \(errnoText())") }
    // Remove old answers, but only plain files or symlinks: never a folder, never
    // recursively. All three names are checked before any is removed, so a path
    // refused here leaves everything as it was.
    var old: [String] = []
    for p in [path, path + ".err", path + ".part"] {
        var st = stat()
        guard lstat(p, &st) == 0 else {
            if errno == ENOENT { continue }   // nothing there
            bad("cannot check \(p): \(errnoText())")
        }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFDIR { bad("\(p) is a folder") }
        guard kind == S_IFREG || kind == S_IFLNK else { bad("\(p) is not a plain file") }
        old.append(p)
    }
    for p in old {
        guard unlink(p) == 0 || errno == ENOENT else { bad("cannot remove the old \(p): \(errnoText())") }
    }
    outPath = path
}

// MARK: - Checking the request (all before calendar access)

struct NewEvent {
    let title: String
    let start: Date
    let end: Date
    let note: String?
    let allDay: Bool
    let alarms: [Int]   // minutes from the start
}

enum Job {
    case calendars
    case read(calendar: String, from: Date, to: Date)
    case create(calendar: String, events: [NewEvent])
    case delete(calendar: String, ids: [String])
}

// "2026-10-08" as noon that day in local time, or nil if it is not a real date.
// Noon, because a clock change can skip local midnight but never noon.
func noon(_ s: String) -> Date? {
    let b = Array(s.utf8)   // must match ^[0-9]{4}-[0-9]{2}-[0-9]{2}$
    let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    guard b.count == 10,
          b.indices.allSatisfy({ $0 == 4 || $0 == 7 ? b[$0] == UInt8(ascii: "-") : digits.contains(b[$0]) }),
          let y = Int(s.prefix(4)), let m = Int(s.dropFirst(5).prefix(2)), let d = Int(s.suffix(2)),
          let date = greg.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) else { return nil }
    let back = greg.dateComponents([.year, .month, .day], from: date)
    return back.year == y && back.month == m && back.day == d ? date : nil
}

// The search window for read: from the start of <from> to the start of the day
// after <to>, as <to> is inclusive.
func window(_ a: String, _ b: String) -> (Date, Date) {
    guard let f = noon(a) else { fail("<from> \"\(a)\" is not a real date written YYYY-MM-DD") }
    guard let t = noon(b) else { fail("<to> \"\(b)\" is not a real date written YYYY-MM-DD") }
    guard t >= f else { fail("<to> \(b) is before <from> \(a)") }
    guard let dayAfter = greg.date(byAdding: .day, value: 1, to: t) else { fail("cannot work out the day after \(b)") }
    let from = greg.startOfDay(for: f), to = greg.startOfDay(for: dayAfter)
    // EventKit searches at most four years at once
    guard to.timeIntervalSince(from) <= 1461 * 86400 else {
        fail("the window from \(a) to \(b) is longer than four years (1461 x 24 hours); split it")
    }
    return (from, to)
}

func defaultWindow() -> (Date, Date) {
    let now = Date()
    guard let from = greg.date(byAdding: .year, value: -1, to: now),
          let to = greg.date(byAdding: .year, value: 2, to: now) else { fail("cannot work out the default window") }
    return (from, to)
}

// The first key of obj that is not in allowed, if any, so a misspelt field
// ("all_day") is refused rather than quietly ignored. Sorted, so the same spec
// always gives the same message.
func unknownField(_ obj: [String: Any], _ allowed: Set<String>) -> String? {
    obj.keys.sorted().first { !allowed.contains($0) }
}

func loadSpec(_ path: String, fields: Set<String>) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read spec \(path)") }
    let obj: Any
    do { obj = try JSONSerialization.jsonObject(with: data) }
    catch { fail("spec \(path) is not valid JSON: \(error.localizedDescription)") }
    guard let spec = obj as? [String: Any] else { fail("spec \(path) must be a JSON object") }
    if let k = unknownField(spec, fields) { fail("spec: unknown field \"\(k)\"") }
    return spec
}

// JSONSerialization gives NSNumber for JSON numbers and booleans alike, and NSNumber
// converts freely to Int and Bool, so true would pass as 1 and 1.5 as 1. These two
// look at what the number really is.
func jsonBool(_ x: Any) -> Bool? {
    guard let n = x as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}

func jsonInt(_ x: Any) -> Int? {
    guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    switch String(cString: n.objCType) {
    case "c", "s", "i", "l", "q": return Int(n.int64Value)
    case "C", "S", "I", "L", "Q": return Int(exactly: n.uint64Value)
    default: return nil   // stored as a fraction, even 1.0 or 1e2
    }
}

// [year, month, day, hour, minute, second] as a moment in local time. It must be a
// time that really happens: not 30 February, and not 01:30 on the night the clocks
// skip it. Built with greg and read back; all six numbers must come back the same.
func localTime(_ x: Any?, _ field: String, _ bad: (String) -> Never) -> Date {
    let shape = "\"\(field)\" must be [year, month, day, hour, minute, second], six whole numbers"
    guard let list = x as? [Any], list.count == 6 else { bad(shape) }
    var n: [Int] = []
    for v in list {
        guard let i = jsonInt(v) else { bad(shape) }
        n.append(i)
    }
    guard (1...12).contains(n[1]) else { bad("\"\(field)\" month must be 1-12, not \(n[1])") }
    let notReal = "\"\(field)\" \(n) is not a real local time"
    // Small enough numbers that the date sums cannot overflow; the read-back does the rest.
    guard (1...9999).contains(n[0]), n[2...].allSatisfy({ (0...99).contains($0) }) else { bad(notReal) }
    let c = DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4], second: n[5])
    guard let d = greg.date(from: c) else { bad(notReal) }
    let back = greg.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    guard [back.year, back.month, back.day, back.hour, back.minute, back.second] == n.map({ Optional($0) }) else {
        bad(notReal)
    }
    return d
}

func calendarName(_ spec: [String: Any]) -> String {
    guard let name = spec["calendar"] as? String, !name.isEmpty else { fail("spec: \"calendar\" must be a non-empty string") }
    return name
}

func newEvents(_ spec: [String: Any]) -> [NewEvent] {
    guard let items = spec["events"] as? [Any], !items.isEmpty else { fail("spec: \"events\" must be a non-empty list") }
    var events: [NewEvent] = []
    for (i, x) in items.enumerated() {
        let maybeItem = x as? [String: Any]
        let shownTitle = maybeItem?["title"] as? String ?? ""
        func bad(_ what: String) -> Never { fail("event \(i + 1) (\"\(shownTitle)\"): \(what)") }

        guard let item = maybeItem else { bad("must be a JSON object") }
        if let k = unknownField(item, ["title", "start", "end", "note", "allday", "alarms"]) {
            bad("unknown field \"\(k)\"")
        }
        guard let title = item["title"] as? String else { bad("\"title\" must be a string") }
        let start = localTime(item["start"], "start", bad)
        let end = localTime(item["end"], "end", bad)
        guard end >= start else { bad("\"end\" is before \"start\"") }
        var note: String? = nil
        if let v = item["note"] {
            guard let s = v as? String else { bad("\"note\" must be a string") }
            note = s
        }
        var allDay = false
        if let v = item["allday"] {
            guard let b = jsonBool(v) else { bad("\"allday\" must be true or false") }
            allDay = b
        }
        var alarms: [Int] = []
        if let v = item["alarms"] {
            // EventKit keeps any offset it is given, so a silly one is stopped here.
            let limit = 10 * 525_600   // ten years, in minutes
            let shape = "\"alarms\" must be a list of whole numbers of minutes, each at most \(limit) (ten years) from the start"
            guard let list = v as? [Any] else { bad(shape) }
            for a in list {
                guard let m = jsonInt(a), (-limit...limit).contains(m) else { bad(shape) }
                alarms.append(m)
            }
        }
        events.append(NewEvent(title: title, start: start, end: end, note: note, allDay: allDay, alarms: alarms))
    }
    return events
}

func eventIds(_ spec: [String: Any]) -> [String] {
    guard let list = spec["ids"] as? [Any], !list.isEmpty else { fail("spec: \"ids\" must be a non-empty list") }
    var ids: [String] = []
    for (i, x) in list.enumerated() {
        guard let id = x as? String, !id.isEmpty else { fail("spec: id \(i + 1) must be a non-empty string") }
        ids.append(id)
    }
    return ids
}

func parseJob(_ args: [String]) -> Job {
    guard let command = args.first else { fail(usage) }
    switch command {
    case "calendars":
        guard args.count == 1 else { fail("usage: tompion [--out <path>] calendars") }
        return .calendars
    case "read":
        guard args.count == 2 || args.count == 4 else { fail("usage: tompion [--out <path>] read <calendar> [<from> <to>]") }
        guard !args[1].isEmpty else { fail("read: the calendar name is empty") }
        let (from, to) = args.count == 4 ? window(args[2], args[3]) : defaultWindow()
        return .read(calendar: args[1], from: from, to: to)
    case "create":
        guard args.count == 2 else { fail("usage: tompion [--out <path>] create <spec.json>") }
        let spec = loadSpec(args[1], fields: ["calendar", "events"])
        let name = calendarName(spec)
        return .create(calendar: name, events: newEvents(spec))
    case "delete":
        guard args.count == 2 else { fail("usage: tompion [--out <path>] delete <spec.json>") }
        let spec = loadSpec(args[1], fields: ["calendar", "ids"])
        let name = calendarName(spec)
        return .delete(calendar: name, ids: eventIds(spec))
    default:
        fail("unknown command \"\(command)\"; " + usage)
    }
}

// MARK: - Calendar work (after access)

func requestAccess(_ store: EKEventStore) {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var problem: Error?
    store.requestFullAccessToEvents { ok, err in granted = ok; problem = err; sem.signal() }
    if sem.wait(timeout: .now() + 100) == .timedOut {
        fail("timed out waiting for calendar access; answer the macOS dialog, or allow Tompion in System Settings > Privacy & Security > Calendars, then run it again")
    }
    if !granted { fail("no calendar access: " + (problem?.localizedDescription ?? "denied. Allow it in System Settings > Privacy & Security > Calendars")) }
}

func findCalendar(_ store: EKEventStore, _ name: String) -> EKCalendar {
    let cals = store.calendars(for: .event).filter { $0.title == name }
    guard cals.count == 1 else { fail("need exactly one calendar called '\(name)', found \(cals.count)") }
    return cals[0]
}

// Called just before a commit. If the folder --out writes into has gone, the caller
// has given up waiting (its temporary folder was cleaned away), so drop the unsaved
// changes and stop without committing or writing anything.
func stopIfCallerGone(_ store: EKEventStore) {
    guard let p = outPath else { return }
    var isDir: ObjCBool = false
    let parent = (p as NSString).deletingLastPathComponent
    if FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue { return }
    store.reset()
    exit(3)
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())

// -h, --help and --version are answered at once, before --out, the command or the
// calendar, so they never bring up the permission dialog.
if let flag = args.first, ["-h", "--help", "--version"].contains(flag) {
    guard args.count == 1 else { fail("\(flag) takes nothing after it; " + usage) }
    let text = flag == "--version"
        ? "tompion \(version)"
        : usage + "\n       tompion --help | -h | --version\nThe commands, their JSON and why to run it through open: README.md, or https://github.com/tompopham/Tompion"
    guard writeAll(1, Data((text + "\n").utf8)) else {
        toStderr("tompion: could not write to stdout: \(errnoText())")
        exit(2)
    }
    exit(0)
}

if args.first == "--out" {
    guard args.count >= 2 else {
        toStderr("tompion: --out needs a path\n" + usage)
        exit(2)
    }
    setUpOut(args[1])
    args.removeFirst(2)
}
let job = parseJob(args)

// Everything that can be checked without the calendar has passed; only now ask.
let store = EKEventStore()
requestAccess(store)
let iso = ISO8601DateFormatter()

switch job {
case .calendars:
    out(store.calendars(for: .event).map { $0.title })

case let .read(name, from, to):
    let cal = findCalendar(store, name)
    let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [cal]))
    out(events.map { e -> [String: Any] in
        [
            "id": e.eventIdentifier ?? "",
            "uid": e.calendarItemExternalIdentifier ?? "",
            "title": e.title ?? "",
            "start": iso.string(from: e.startDate),
            "end": iso.string(from: e.endDate),
            "allday": e.isAllDay,
            "location": e.location ?? "",
            "note": e.notes ?? "",
            "url": e.url?.absoluteString ?? "",
            "recurring": e.hasRecurrenceRules,
            // relative alarms only: a fixed-time or location alarm has no offset to give.
            // An offset too big for a whole number is left out rather than crash read.
            "alarms": (e.alarms ?? [])
                .filter { $0.absoluteDate == nil && $0.structuredLocation == nil }
                .compactMap { Int(exactly: ($0.relativeOffset / 60).rounded(.towardZero)) },
        ]
    })

case let .create(name, items):
    let cal = findCalendar(store, name)
    var saved: [(title: String, event: EKEvent?, error: String)] = []
    for item in items {
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = item.title
        if let n = item.note, !n.isEmpty { e.notes = n }
        e.isAllDay = item.allDay
        e.startDate = item.start
        e.endDate = item.end
        for m in item.alarms { e.addAlarm(EKAlarm(relativeOffset: TimeInterval(m) * 60)) }
        do {
            try store.save(e, span: .thisEvent, commit: false)
            saved.append((item.title, e, ""))
        } catch {
            saved.append((item.title, nil, error.localizedDescription))
        }
    }
    stopIfCallerGone(store)
    do { try store.commit() } catch { fail("commit failed: \(error.localizedDescription). Check with read what was saved.") }
    // The ids are read only now, after the commit, when they are final.
    out(saved.map { s -> [String: Any] in
        guard let e = s.event else { return ["title": s.title, "id": NSNull(), "status": "error: " + s.error] }
        return ["title": s.title, "id": e.eventIdentifier.map { $0 as Any } ?? NSNull(), "status": "ok"]
    })

case let .delete(name, ids):
    let cal = findCalendar(store, name)
    var result: [[String]] = []
    for id in ids {
        guard let e = store.event(withIdentifier: id) else { result.append([id, "not found, left alone"]); continue }
        if e.calendar?.calendarIdentifier != cal.calendarIdentifier { result.append([id, "in another calendar, left alone"]); continue }
        if e.hasRecurrenceRules { result.append([id, "repeating event, left alone"]); continue }
        do {
            try store.remove(e, span: .thisEvent, commit: false)
            result.append([id, "deleted"])
        } catch {
            result.append([id, "error: \(error.localizedDescription)"])
        }
    }
    stopIfCallerGone(store)
    do { try store.commit() } catch { fail("commit failed: \(error.localizedDescription). Check with read what was deleted.") }
    out(result)
}
