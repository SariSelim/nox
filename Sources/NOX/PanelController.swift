import AppKit
import QuartzCore

enum Palette {
    static let bg = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.039, alpha: 1)
    static let soft = NSColor(calibratedRed: 0.086, green: 0.094, blue: 0.075, alpha: 1)
    static let lime = NSColor(calibratedRed: 0.839, green: 0.988, blue: 0.522, alpha: 1)
    static let text = NSColor(calibratedRed: 0.945, green: 0.949, blue: 0.914, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.60, green: 0.62, blue: 0.56, alpha: 1)
    static let line = NSColor(calibratedWhite: 1, alpha: 0.07)
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Field: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class TapButton: NSButton {
    var onTap: (() -> Void)?
    @objc func fire() { onTap?() }
}

final class RootView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }

    var showsExpandedContent = false {
        didSet {
            collapsedLabel.isHidden = showsExpandedContent
            expandedContent?.isHidden = !showsExpandedContent
            needsDisplay = true
        }
    }

    let collapsedLabel = NSTextField(labelWithString: "")
    weak var expandedContent: NSView?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        collapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        collapsedLabel.textColor = Palette.muted
        collapsedLabel.alignment = .center
        collapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapsedLabel)
        NSLayoutConstraint.activate([
            collapsedLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            collapsedLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("desteklenmiyor") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
    let path = NSBezierPath()

    // Üst köşeler düz, alt köşeler yuvarlak.
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))

    path.appendArc(
        withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
        radius: radius,
        startAngle: 0,
        endAngle: -90,
        clockwise: true
    )

    path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))

    path.appendArc(
        withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
        radius: radius,
        startAngle: -90,
        endAngle: -180,
        clockwise: true
    )

    path.close()

    Palette.bg.setFill()
    path.fill()
    Palette.line.setStroke()
    path.lineWidth = 1
    path.stroke()
}
}

final class PanelController: NSObject, NSTextViewDelegate {
    private let panel: NotchPanel
    private let root = RootView()
    private let store = Store.shared
    private let timer = FocusTimer()
    private let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

    private var collapsedFrame = NSRect.zero
    private var expandedFrame = NSRect.zero
    private var isExpanded = false
    private var pinned = false
    private var mouseInside = false
    private var pendingCollapse: DispatchWorkItem?
    private var keyMonitor: Any?

    private let content = NSStackView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "25:00")
    private let taskField = Field()
    private let taskList = FlippedStackView()
    private let noteView = NoteTextView()

    private var startButton: TapButton!
    private var pinButton: TapButton!
    private var modeButtons: [TapButton] = []

    override init() {
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 372),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = root

        root.onEnter = { [weak self] in self?.handleEnter() }
        root.onExit = { [weak self] in self?.handleExit() }

        buildUI()

        timer.onChange = { [weak self] in self?.refreshTimerUI() }
        timer.onFinish = { [weak self] mode in self?.handleFinish(mode) }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.collapse(force: true); return nil }
            return event
        }

        reposition()
    }

    // MARK: - Konumlandırma

    @objc private func screensChanged() { reposition() }

    private func reposition() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let notchHeight = max(screen.safeAreaInsets.top, 24)
        var notchWidth: CGFloat = 180
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            notchWidth = right.minX - left.maxX
        }

        let collapsedWidth = notchWidth + 120
        let expandedWidth: CGFloat = 430
        let expandedHeight: CGFloat = 372
        let top = screen.frame.maxY
        let midX = screen.frame.midX

        collapsedFrame = NSRect(
            x: midX - collapsedWidth / 2,
            y: top - notchHeight,
            width: collapsedWidth,
            height: notchHeight
        )
        expandedFrame = NSRect(
            x: midX - expandedWidth / 2,
            y: top - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        root.cornerRadius = isExpanded ? 18 : min(notchHeight / 2, 12)
        panel.setFrame(isExpanded ? expandedFrame : collapsedFrame, display: true)
    }

    func show() {
        reposition()
        refresh()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    // MARK: - Aç / kapa

    private func handleEnter() {
        mouseInside = true
        pendingCollapse?.cancel()
        pendingCollapse = nil
        expand()
    }

    private func handleExit() {
        mouseInside = false
        scheduleCollapse()
    }

    private var isEditing: Bool { panel.firstResponder is NSTextView }

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        root.showsExpandedContent = true
        root.cornerRadius = 18
        animate(to: expandedFrame)
        refresh()
    }

    private func collapse(force: Bool = false) {
        guard isExpanded else { return }
        if !force && pinned { return }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        if panel.isKeyWindow { panel.makeFirstResponder(nil) }
        store.save()
        isExpanded = false
        root.showsExpandedContent = false
        root.cornerRadius = min(collapsedFrame.height / 2, 12)
        animate(to: collapsedFrame)
    }

    private func scheduleCollapse() {
        guard !pinned else { return }
        pendingCollapse?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.mouseInside { return }
            if self.isEditing { self.scheduleCollapse(); return }
            self.collapse()
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func animate(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Arayüz

    private func buildUI() {
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 14, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        root.expandedContent = content
        content.isHidden = true
        root.collapsedLabel.isHidden = false

        // Üst satır
        let brand = NSTextField(labelWithString: "nox.")
        brand.font = .systemFont(ofSize: 15, weight: .semibold)
        brand.textColor = Palette.text

        statsLabel.font = .systemFont(ofSize: 10)
        statsLabel.textColor = Palette.muted

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton = makeButton(symbol: "pin", fallback: "⌖", width: 26, height: 22,
                               background: Palette.soft, tint: Palette.muted) { [weak self] in
            self?.togglePin()
        }
        let quitButton = makeButton(symbol: "power", fallback: "⏻", width: 26, height: 22,
                                    background: Palette.soft, tint: Palette.muted) {
            Store.shared.save()
            NSApp.terminate(nil)
        }

        let header = NSStackView(views: [brand, statsLabel, spacer, pinButton, quitButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        content.addArrangedSubview(header)

        // Zamanlayıcı
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        timeLabel.textColor = Palette.lime

        let timerSpacer = NSView()
        timerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let modeStack = NSStackView()
        modeStack.orientation = .horizontal
        modeStack.spacing = 4
        for mode in [FocusTimer.Mode.focus, .rest] {
            let button = makeButton(symbol: nil, fallback: mode.title, width: 52, height: 22,
                                    background: Palette.soft, tint: Palette.muted, radius: 7) { [weak self] in
                self?.timer.select(mode)
            }
            modeButtons.append(button)
            modeStack.addArrangedSubview(button)
        }

        startButton = makeButton(symbol: "play.fill", fallback: "▶", width: 34, height: 30,
                                 background: Palette.lime, tint: Palette.bg) { [weak self] in
            self?.timer.toggle()
        }
        let resetButton = makeButton(symbol: "arrow.counterclockwise", fallback: "↺", width: 34, height: 30,
                                     background: Palette.soft, tint: Palette.text) { [weak self] in
            self?.timer.reset()
        }

        let timerRow = NSStackView(views: [timeLabel, timerSpacer, modeStack, startButton, resetButton])
        timerRow.orientation = .horizontal
        timerRow.spacing = 8
        timerRow.alignment = .centerY
        content.addArrangedSubview(timerRow)

        // Görev girişi
        taskField.placeholderString = "Aklındakini bir adıma dönüştür…"
        taskField.isBordered = false
        taskField.drawsBackground = false
        taskField.textColor = Palette.text
        taskField.font = .systemFont(ofSize: 12)
        taskField.focusRingType = .none
        taskField.target = self
        taskField.action = #selector(submitTask)
        taskField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addButton = makeButton(symbol: "plus", fallback: "+", width: 30, height: 28,
                                   background: Palette.lime, tint: Palette.bg) { [weak self] in
            self?.submitTask()
        }
        let inputRow = NSStackView(views: [taskField, addButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .centerY
        content.addArrangedSubview(box(inputRow, height: 44))

        // Görev listesi
        taskList.orientation = .vertical
        taskList.alignment = .width
        taskList.spacing = 1
        taskList.translatesAutoresizingMaskIntoConstraints = false

        let listScroll = NSScrollView()
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.hasHorizontalScroller = false
        listScroll.borderType = .noBorder
        listScroll.documentView = taskList
        NSLayoutConstraint.activate([
            taskList.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            taskList.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            taskList.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            taskList.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor)
        ])
        content.addArrangedSubview(box(listScroll, height: 96, padding: 6))

        // Not alanı
        noteView.isRichText = false
        noteView.drawsBackground = false
        noteView.textColor = Palette.text
        noteView.font = .systemFont(ofSize: 12)
        noteView.insertionPointColor = Palette.lime
        noteView.textContainerInset = NSSize(width: 0, height: 2)
        noteView.delegate = self
        noteView.string = store.state.note
        noteView.frame = NSRect(x: 0, y: 0, width: 380, height: 76)
        noteView.minSize = NSSize(width: 0, height: 0)
        noteView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteView.isVerticallyResizable = true
        noteView.isHorizontallyResizable = false
        noteView.autoresizingMask = [.width]
        noteView.textContainer?.widthTracksTextView = true
        noteView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let noteScroll = NSScrollView()
        noteScroll.drawsBackground = false
        noteScroll.hasVerticalScroller = true
        noteScroll.autohidesScrollers = true
        noteScroll.borderType = .noBorder
        noteScroll.documentView = noteView
        content.addArrangedSubview(box(noteScroll, height: 88, padding: 6))
    }

    private func makeButton(
        symbol: String?,
        fallback: String,
        width: CGFloat,
        height: CGFloat,
        background: NSColor,
        tint: NSColor,
        radius: CGFloat = 9,
        action: @escaping () -> Void
    ) -> TapButton {
        let button = TapButton()
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = radius
        button.contentTintColor = tint
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image.withSymbolConfiguration(symbolConfig)
            button.imagePosition = .imageOnly
        } else {
            button.attributedTitle = NSAttributedString(string: fallback, attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
            ])
        }
        button.onTap = action
        button.target = button
        button.action = #selector(TapButton.fire)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: height)
        ])
        return button
    }

    private func box(_ inner: NSView, height: CGFloat, padding: CGFloat = 8) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.soft.cgColor
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: height),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding)
        ])
        return container
    }

    // MARK: - Güncelleme

    private func refresh() {
        refreshTimerUI()
        refreshStats()
        reloadTasks()
    }

    private func refreshTimerUI() {
        timeLabel.stringValue = timer.label
        root.collapsedLabel.stringValue = timer.running ? timer.label : ""
        if let startButton {
            let name = timer.running ? "pause.fill" : "play.fill"
            startButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
        }
        refreshModes()
    }

    private func refreshModes() {
        for (index, button) in modeButtons.enumerated() {
            let active = index == timer.mode.rawValue
            button.layer?.backgroundColor = (active ? Palette.lime : Palette.soft).cgColor
            let tint = active ? Palette.bg : Palette.muted
            let title = FocusTimer.Mode(rawValue: index)?.title ?? ""
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
            ])
        }
    }

    private func refreshStats() {
        statsLabel.stringValue = "\(store.openCount) açık · \(Int(store.todayMinutes)) dk bugün"
    }

    private func reloadTasks() {
        for view in taskList.arrangedSubviews { view.removeFromSuperview() }
        if store.state.tasks.isEmpty {
            let empty = NSTextField(labelWithString: "Liste boş. Yukarıdan ilk adımı ekle.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = Palette.muted
            taskList.addArrangedSubview(empty)
            return
        }
        for item in store.state.tasks {
            taskList.addArrangedSubview(makeTaskRow(item))
        }
    }

    private func makeTaskRow(_ item: TaskItem) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)

        let check = makeButton(
            symbol: item.done ? "checkmark" : nil,
            fallback: "○",
            width: 20, height: 20,
            background: item.done ? Palette.lime : Palette.line,
            tint: item.done ? Palette.bg : Palette.muted,
            radius: 6
        ) { [weak self] in
            self?.store.toggle(item.id)
            self?.refresh()
        }

        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.attributedStringValue = NSAttributedString(string: item.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: item.done ? Palette.muted : Palette.text,
            .strikethroughStyle: item.done ? NSUnderlineStyle.single.rawValue : 0
        ])

        let remove = makeButton(symbol: "xmark", fallback: "×", width: 20, height: 20,
                                background: .clear, tint: Palette.muted, radius: 6) { [weak self] in
            self?.store.remove(item.id)
            self?.refresh()
        }

        row.addArrangedSubview(check)
        row.addArrangedSubview(title)
        row.addArrangedSubview(remove)
        return row
    }

    // MARK: - Eylemler

    @objc private func submitTask() {
        store.addTask(taskField.stringValue)
        taskField.stringValue = ""
        refresh()
    }

    private func togglePin() {
        pinned.toggle()
        pinButton.contentTintColor = pinned ? Palette.lime : Palette.muted
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        if pinned {
            pendingCollapse?.cancel()
            pendingCollapse = nil
        } else if !mouseInside {
            scheduleCollapse()
        }
    }

    private func handleFinish(_ mode: FocusTimer.Mode) {
        if mode == .focus { store.logSession(minutes: mode.logMinutes) }
        if let sound = NSSound(named: NSSound.Name("Glass")) { sound.play() } else { NSSound.beep() }
        refresh()
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === noteView else { return }
        store.setNote(noteView.string)
    }
}
