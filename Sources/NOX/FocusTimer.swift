import Foundation

final class FocusTimer {
    enum Mode: Int {
        case focus = 0
        case rest = 1

        var seconds: Int { self == .focus ? 25 * 60 : 5 * 60 }
        var title: String { self == .focus ? "25 dk" : "5 dk" }
        var logMinutes: Double { Double(seconds) / 60 }
    }

    private(set) var mode: Mode = .focus
    private(set) var remaining: Int = Mode.focus.seconds
    private(set) var running = false

    private var endDate: Date?
    private var timer: Timer?

    var onChange: (() -> Void)?
    var onFinish: ((Mode) -> Void)?

    var label: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }

    func toggle() { running ? pause() : start() }

    func start() {
        guard !running else { return }
        running = true
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onChange?()
    }

    func pause() {
        guard running else { return }
        sync()
        running = false
        endDate = nil
        timer?.invalidate()
        timer = nil
        onChange?()
    }

    func reset() {
        running = false
        endDate = nil
        timer?.invalidate()
        timer = nil
        remaining = mode.seconds
        onChange?()
    }

    func select(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        reset()
    }

    private func sync() {
        if let end = endDate {
            remaining = max(0, Int(end.timeIntervalSinceNow.rounded()))
        }
    }

    private func tick() {
        sync()
        if remaining <= 0 {
            let finished = mode
            running = false
            endDate = nil
            timer?.invalidate()
            timer = nil
            remaining = mode.seconds
            onChange?()
            onFinish?(finished)
        } else {
            onChange?()
        }
    }
}
