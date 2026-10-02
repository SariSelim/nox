import AppKit

struct TaskItem: Codable {
    var id = UUID()
    var text: String
    var done = false
}

struct Session: Codable {
    var date: String
    var minutes: Double
}

final class Store {
    static let shared = Store()

    struct State: Codable {
        var tasks: [TaskItem] = []
        var note: String = ""
        var sessions: [Session] = []
    }

    private let key = "nox.state.v1"
    private let defaults = UserDefaults.standard
    private var pendingSave: DispatchWorkItem?

    private(set) var state: State

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var openCount: Int { state.tasks.filter { !$0.done }.count }
    var todayMinutes: Double {
        state.sessions.filter { $0.date == Self.today }.reduce(0) { $0 + $1.minutes }
    }

    func addTask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.tasks.append(TaskItem(text: text))
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[i].done.toggle()
        save()
    }

    func remove(_ id: UUID) {
        state.tasks.removeAll { $0.id == id }
        save()
    }

    func logSession(minutes: Double) {
        state.sessions.append(Session(date: Self.today, minutes: minutes))
        save()
    }

    func setNote(_ text: String) {
        state.note = text
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
