import AppKit
import Combine
import LidAngleKit
import QuartzCore

/// Watches the lid angle and drives the depth effect overlay.
///
/// A timer polls the sensor, and a display link advances a spring at the
/// screen refresh rate so the ramp stays smooth between readings.

/// Identity of the built-in display. `NSApplication` posts a screen change for
/// a backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

/// Decides, on the queue sensor pushes land on, whether a reading is worth
/// waking the main thread for. Most are not, and are dropped right there.
private final class WakeGate: @unchecked Sendable {
    private let lock = NSLock()
    /// The precise angle when the controller went to sleep; `nil` while awake.
    private var sleepingAt: Double?
    private var lastPush: (degrees: Double, time: CFTimeInterval)?

    func sleep(at angle: Double) {
        lock.lock(); defer { lock.unlock() }
        sleepingAt = angle
    }

    func awake() {
        lock.lock(); defer { lock.unlock() }
        sleepingAt = nil
    }

    /// The lid's speed from this push and the one before, in degrees per
    /// second, once per sleep, for the first reading `margin` away from where
    /// the lid rested; `nil` for readings not worth waking for. The speed lets
    /// the controller act on the very first poll instead of waiting for two.
    func wakeSpeed(for degrees: Double, at time: CFTimeInterval, margin: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let previous = lastPush
        lastPush = (degrees, time)
        guard let sleepingAt, abs(degrees - sleepingAt) >= margin else { return nil }
        self.sleepingAt = nil
        guard let previous, time - previous.time > 0.02, time - previous.time < 0.6 else { return 0 }
        return (degrees - previous.degrees) / (time - previous.time)
    }
}

@MainActor
final class LidController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false

    let snapshotter = ScreenSnapshotter()

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let overlay = DepthOverlay()
    private let streamer = ScreenStreamer()

    /// Keeps polling while the settings panel shows the live angle.
    var isPanelOpen = false {
        didSet { if isPanelOpen { wake() } }
    }

    private var enabledSubscription: AnyCancellable?
    private var modeSubscription: AnyCancellable?
    private var pictureTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// Degrees per second, negative while the lid closes.
    private var angularVelocity: Double = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    /// Quick enough to keep up with a fast close; the prediction it follows
    /// covers the sensor's own lag.
    private var visualAngle = CriticallyDampedSpring(value: 0, frequency: 24)
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var motionIntent = LidMotionIntent()
    private var openDwell = LidOpenDwell()
    /// Where the lid last moved to by more than `timeoutMovementThreshold`,
    /// and when. The timeout counts from there.
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    /// Set when the timeout ends the effect, cleared once the lid rises back
    /// above the threshold. Closing further from the same resting spot must
    /// not retrigger it.
    private var timeoutAwaitingRelease = false
    /// The setting as last seen, so flipping it drops stale tracking.
    private var wasTimeoutEnabled = false
    /// True while `beginClosingOut()` is easing the picture back to flat.
    private var isClosingOut = false
    private var closingOutStartedAt: CFTimeInterval = 0
    private var builtInLayout = Layout()
    private var peakAngle: Double = 0
    /// The lowest reading since the effect started. Opening releases only
    /// once the lid has risen `LidEffectPolicy.minimumReleaseRise` above it.
    private var lowestRunAngle: Double = 0
    /// Readings from the last `recentWindow`, so a pre-warm needs the lid to
    /// have really come down rather than a reading flickering by a step.
    private var recentAngles: [(time: CFTimeInterval, angle: Double)] = []
    private let wakeGate = WakeGate()
    private let pushQueue = DispatchQueue(label: "MacDuo.lidPush", qos: .utility)
    /// True when the sensor pushes readings, so a still lid needs no polling.
    private var isPushing = false
    private var lastMovementAngle: Double = 0
    private var lastMovementTime: CFTimeInterval = 0

    /// Polling rate for sensors that cannot push.
    private static let idlePollInterval: TimeInterval = 1.0 / 8
    /// How often a still lid's sensor pushes a reading near the start angle,
    /// where a close has to be caught at once: the sensor's own refresh. Each
    /// reading costs about 80 µs of CPU on a utility queue, and the main
    /// thread stays asleep.
    private static let nearPushInterval: TimeInterval = 0.1
    /// Further open, a close takes long enough to reach the start angle that
    /// a slower watch still catches it in time.
    private static let farPushInterval: TimeInterval = 0.5
    /// Degrees above the start angle that count as near.
    private static let nearMargin: Double = 30
    /// Typical age of a pushed reading: half a sensor refresh.
    private static let pushAge: TimeInterval = 0.05
    private var pushInterval: TimeInterval = 0
    /// Pushed readings are whole degrees, and a lid resting between two of
    /// them flickers by one. This much away from the resting angle wakes.
    private static let wakeMargin: Double = 1.5
    /// A change this large counts as the lid moving.
    private static let movementThreshold: Double = 0.3
    /// How long polling carries on after the lid last moved.
    private static let settleDuration: TimeInterval = 1.5
    private static let activePollInterval: TimeInterval = 1.0 / 30
    private static let fadeInDuration: TimeInterval = 0.07
    /// Degrees above the start angle at which polling speeds up. Above it
    /// the idle rate still sees the lid start to move.
    private static let fastPollMargin: Double = 20

    /// Movement faster than this, either way, also polls fast.
    private static let fastPollSpeed: Double = 2

    /// How far the lid must have come down within `recentWindow` before
    /// closing starts the capture pre-warm. A resting lid whose reading
    /// flickers by one step otherwise starts a full screen capture stream.
    private static let prewarmMinimumDrop: Double = 3
    private static let recentWindow: TimeInterval = 1

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    private static let triggerClosingSpeed: Double = 2

    /// Opening speed that counts as a deliberate reversal, in degrees per second.
    private static let triggerOpeningSpeed: Double = 2

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    private static let predictionLatency: TimeInterval = 0.04

    /// The ordinary hysteresis release waits this long. A prediction can fire
    /// while the last reading is still above the trigger angle, but deliberate
    /// opening is allowed to release immediately.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// How long a lid held above the start angle waits before it counts as
    /// opened again, for openings slower than `triggerOpeningSpeed`.
    private static let openDwellDuration: TimeInterval = 1

    /// Movement within this many degrees counts as holding still.
    private static let timeoutMovementThreshold: Double = 2

    /// How long the lid has to hold still before the timeout ends the effect.
    private static let timeoutStillDuration: TimeInterval = 2

    /// How close the eased angle must get to flat before the last frame
    /// snaps there. Half a degree short, the dim curve still darkens the top
    /// of the picture by several percent, and the fade would then reveal a
    /// brighter screen underneath.
    private static let closingOutSettleEpsilon: Double = 0.05

    /// Safety cap, in case the spring never quite settles.
    private static let closingOutMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        enabledSubscription = preferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.disableEffect()
            }
        modeSubscription = preferences.$usesWindowServer
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] usesWindowServer in
                guard let self else { return }
                self.stopEffectAndCapture()
                if !usesWindowServer, self.isSensorAvailable { self.warmCapture() }
                // The setting changes after this runs.
                if usesWindowServer {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.preparePortal() } }
                }
            }
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else { return }

        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        // Before the first poll, which reads it.
        builtInLayout = Layout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        let gate = wakeGate
        let margin = Self.wakeMargin
        pushInterval = Self.nearPushInterval
        isPushing = sensor.startReporting(interval: pushInterval, queue: pushQueue) { [weak self] degrees in
            guard let speed = gate.wakeSpeed(for: degrees, at: CACurrentMediaTime(), margin: margin) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.wakeFromPush(speed: speed) }
            }
        }
        Diagnostics.lid.notice("sensor pushes readings: \(self.isPushing)")
        wake()
        observeSystemEvents()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("to.maki.MacDuo.preview"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        // The window server blur captures nothing, so it never touches
        // ScreenCaptureKit and never asks for Screen Recording.
        if !preferences.usesWindowServer { warmCapture() }
        preparePortal()
    }

    private func warmCapture() {
        overlay.warmUp()
        Task {
            await snapshotter.warmFilter()
            // After the overlay has put its presence window up, so the filter
            // can name this app and leave the overlay out of the picture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await streamer.warmFilter()
        }
    }

    /// Has the window server overlay built and waiting, hidden.
    private func preparePortal() {
        guard !capturesScreen, let screen = NSScreen.builtIn else { return }
        overlay.preparePortal(on: screen)
    }

    private var capturesScreen: Bool {
        !preferences.usesWindowServer || !BackdropPortalView.isSupported
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        stopEffectAndCapture()
        // The report interval outlives this process.
        sensor.stopReporting()
    }

    private func stopEffectAndCapture() {
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: false)
        snapshotter.stop()
        streamer.stop()
        overlay.discardLive()
        preview = nil
        isActive = false
    }

    private func disableEffect() {
        stopEffectAndCapture()
        lastChangedAngle = nil
        recentAngles.removeAll()
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        wake()
    }

    /// Plays the effect once on the current screen contents.
    func runPreview() {
        guard preferences.isEnabled, !isSuspended, preview == nil, !isActive else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        preview = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: max(
                preferences.thresholdAngle + preferences.hysteresis + 5,
                min(preferences.thresholdAngle + 35, 130)
            ),
            shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, 5)
        )
        wake()
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Lets the system line wakeups up with others.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// A pushed reading has moved away from where the lid rested. Reads the
    /// precise angle at once rather than a poll interval later, starting from
    /// the speed the pushes measured, so a close past the start angle is acted
    /// on at this very reading.
    private func wakeFromPush(speed: Double) {
        guard !isSuspended else { return }
        let now = CACurrentMediaTime()
        if abs(speed) > abs(angularVelocity) {
            angularVelocity = speed
            motionIntent.update(
                angularVelocity: speed,
                at: now,
                closingSpeed: Self.triggerClosingSpeed,
                openingSpeed: Self.triggerOpeningSpeed
            )
        }
        // A fresh baseline: the reading before sleep is too old to measure
        // speed against, and a push is at most one sensor refresh old.
        lastChangedAngle = nil
        lastChangeTime = now - Self.pushAge
        wake()
        poll()
    }

    /// Starts polling, from sleep or not. A pushed reading away from the
    /// resting angle calls this, and so does anything that needs fresh angles.
    private func wake() {
        guard !isSuspended else { return }
        wakeGate.awake()
        lastMovementTime = CACurrentMediaTime()
        setPollInterval(Self.activePollInterval)
    }

    /// Stops polling until the lid moves. Only with a sensor that pushes.
    private func sleep(at angle: Double) {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        // A settled picture needs no frames; a pushed reading wakes the link
        // back up through `reconcile`.
        stopDisplayLink()
        wakeGate.sleep(at: angle)
        let interval = angle <= preferences.thresholdAngle + Self.nearMargin
            ? Self.nearPushInterval
            : Self.farPushInterval
        if interval != pushInterval {
            pushInterval = interval
            sensor.setReportInterval(interval)
        }
    }

    /// Whether anything still needs a fresh angle every frame.
    private func needsPolling(at now: CFTimeInterval) -> Bool {
        if preview != nil || isClosingOut || isPanelOpen || isCapturePending { return true }
        if now - lastMovementTime < Self.settleDuration { return true }
        guard isActive else { return false }
        // A live capture keeps delivering frames, the timeout counts time,
        // and a spring still easing has frames left to draw.
        let settled = abs(visualAngle.value - rawAngle) < 0.01 && abs(visualAngle.velocity) < 0.05
        return capturesScreen || preferences.isTimeoutEnabled || !settled
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                peakAngle = 0
                // The next reading is the real lid, and the jump to it from
                // the sweep's last angle would read as a fast close.
                lastChangedAngle = nil
                angularVelocity = 0
                recentAngles.removeAll()
                motionIntent.reset()
                if isActive { setActive(false) }
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    Diagnostics.lid.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                Diagnostics.lid.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        peakAngle = max(peakAngle, angle)
        if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
        publish(angle: angle)

        if preferences.isEnabled {
            updateVelocity(with: angle)
            openDwell.update(angle: angle, at: CACurrentMediaTime(), dwellAngle: effectPolicy.dwellAngle)
            reconcile(angle: angle)
        }

        let now = CACurrentMediaTime()
        if abs(angle - lastMovementAngle) >= Self.movementThreshold {
            lastMovementAngle = angle
            lastMovementTime = now
        }
        if needsPolling(at: now) {
            setPollInterval(Self.activePollInterval)
        } else if isPushing {
            sleep(at: angle)
        } else {
            let wantsFastPolling = preferences.isEnabled
                && (angle <= preferences.thresholdAngle + Self.fastPollMargin
                    || abs(angularVelocity) >= Self.fastPollSpeed)
            setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
        }
    }

    private var effectPolicy: LidEffectPolicy {
        LidEffectPolicy(threshold: preferences.thresholdAngle, hysteresis: preferences.hysteresis)
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing, unless
    /// the timeout ends it first.
    private func wantsEffect(angle: Double) -> Bool {
        // `builtInLayout` is kept current by the screen change observer, so
        // this does not enumerate the screens on every sample.
        guard preferences.isEnabled, builtInLayout.displayID != nil else { return false }
        if preferences.isTimeoutEnabled != wasTimeoutEnabled {
            timeoutReferenceAngle = nil
            timeoutAwaitingRelease = false
            wasTimeoutEnabled = preferences.isTimeoutEnabled
        }

        let now = CACurrentMediaTime()
        let threshold = preferences.thresholdAngle
        let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

        if !isActive, preferences.isTimeoutEnabled, timeoutAwaitingRelease {
            guard angle >= threshold else { return false }
            timeoutAwaitingRelease = false
        }

        let wanted = effectPolicy.wantsEffect(
            isEnabled: preferences.isEnabled,
            isActive: isActive,
            angle: angle,
            predictedAngle: predictedAngle(),
            riseSinceLowest: angle - lowestRunAngle,
            hasBeenAboveThreshold: peakAngle >= threshold,
            wasClosingRecently: motionIntent.wasClosingRecently(
                at: now,
                memoryDuration: Self.closingMemory
            ),
            isClearlyOpening: angularVelocity >= Self.triggerOpeningSpeed,
            hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
            minimumDurationElapsed: minimumDurationElapsed
        )

        // The timeout only cuts short a run the policy would keep showing.
        if isActive, wanted, minimumDurationElapsed,
           preferences.isTimeoutEnabled, isPastTimeout(angle: angle) {
            timeoutAwaitingRelease = true
            return false
        }
        return wanted
    }

    /// True once the angle has held within `timeoutMovementThreshold` of its
    /// last significant position for `timeoutStillDuration`.
    private func isPastTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle,
           abs(angle - reference) <= Self.timeoutMovementThreshold {
            return now - timeoutReferenceTime >= Self.timeoutStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    /// Brings the screen in line with `wantsEffect` on every sample. A run
    /// whose screenshot failed is retried here.
    private func reconcile(angle: Double) {
        guard preferences.isEnabled, !isSuspended else { return }
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            Diagnostics.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.snapshotter.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if capturesScreen, preferences.isLivePicture { streamer.start() }
            if !overlay.isVisible, !isCapturePending { presentPicture() }
            // A visible overlay with no link would sit at its first frame.
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else if !isClosingOut {
            // The ease back to flat still draws the live picture, and this
            // would free it.
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + preferences.prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        motionIntent.update(
            angularVelocity: angularVelocity,
            at: now,
            closingSpeed: Self.triggerClosingSpeed,
            openingSpeed: Self.triggerOpeningSpeed
        )
        if angularVelocity >= Self.triggerOpeningSpeed {
            lastClosingTime = -.greatestFiniteMagnitude
        } else if angularVelocity <= -preferences.closingSpeed {
            recentAngles.removeAll { now - $0.time > Self.recentWindow }
            let recentPeak = recentAngles.map(\.angle).max() ?? angle
            if recentPeak - angle >= Self.prewarmMinimumDrop { lastClosingTime = now }
        }
        recentAngles.append((now, angle))
        if recentAngles.count > 64 { recentAngles.removeFirst(recentAngles.count - 64) }
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        guard capturesScreen else {
            snapshotter.endPrewarm()
            streamer.stop()
            overlay.discardLive()
            return
        }
        let closingRecently = CACurrentMediaTime() - lastClosingTime < preferences.prewarmLinger
        guard angle <= ceiling, closingRecently else {
            snapshotter.endPrewarm()
            streamer.stop()
            overlay.discardLive()
            return
        }
        guard preferences.isLivePicture else {
            streamer.stop()
            overlay.discardLive()
            snapshotter.beginPrewarm(interval: preferences.prewarmInterval)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        snapshotter.endPrewarm()
        streamer.start()
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            peakAngle = rawAngle
            lowestRunAngle = rawAngle
            openDwell.reset()
            isClosingOut = false
            startedAt = CACurrentMediaTime()
            if preferences.isTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = startedAt
            }
            // Straight to where the lid is: a start noticed late shows the
            // blur the lid has already reached rather than easing into it.
            visualAngle.reset(to: rawAngle)
            snapshotter.endPrewarm()
            wake()
            presentPicture()
        } else {
            snapshotter.discard()
            timeoutReferenceAngle = nil
            beginClosingOut()
        }
    }

    /// Eases the picture back to flat before the overlay fades away. Ending
    /// the effect with the lid still shut would otherwise fade out a warped
    /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
    private func beginClosingOut() {
        // Nothing to ease before the picture is up, or with no link to draw it.
        guard overlay.isVisible, displayLink != nil else {
            stopDisplayLink()
            overlay.dismiss(animated: true)
            return
        }
        isClosingOut = true
        closingOutStartedAt = CACurrentMediaTime()
    }

    private func finishClosingOut() {
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: true)
    }

    private func endEffect() {
        setActive(false)
    }

    /// Shows the held screenshot, or waits for one. A pre-warm capture that is
    /// already running counts as that wait.
    private func presentPicture() {
        guard preferences.isEnabled, !isSuspended, isActive else { return }
        if !capturesScreen, let screen = NSScreen.builtIn,
           overlay.showBackdrop(
               on: screen,
               startAngle: preferences.thresholdAngle,
               tuning: tuning,
               fadeIn: Self.fadeInDuration
           ) {
            startDisplayLink()
            return
        }
        if preferences.isLivePicture, let screen = NSScreen.builtIn,
           overlay.showLive(
               on: screen,
               startAngle: preferences.thresholdAngle,
               tuning: tuning,
               fadeIn: Self.fadeInDuration
           ) {
            startDisplayLink()
            if let frame = streamer.newFrame() {
                Diagnostics.lid.notice("present: live, a stream frame was ready")
                overlay.absorb(frame)
                return
            }
            // A fast close can reach the trigger angle before the stream has a
            // frame. One screenshot starts the picture off.
            if let image = snapshotter.latestImage {
                Diagnostics.lid.notice("present: live, seeding from the pre-warm screenshot")
                overlay.seed(image: image)
                return
            }
            Diagnostics.lid.notice("present: live, no picture yet, asking for a screenshot")
            requestSeed()
            return
        }

        if let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
            show(image: image, on: screen)
            return
        }
        isCapturePending = true
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                capture landed: image \(self.snapshotter.latestImage != nil) \
                on \(self.isActive) overlay \(self.overlay.isVisible)
                """
            )
            guard self.isActive, !self.overlay.isVisible,
                  let image = self.snapshotter.latestImage,
                  let screen = self.snapshotter.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    /// Takes one screenshot to start a live overlay that has nothing to show
    /// yet. A stream frame that lands first makes it unnecessary.
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.snapshotter.latestImage != nil) on \(self.isActive) \
                ready \(self.overlay.isPictureReady)
                """
            )
            guard self.isActive, !self.overlay.isPictureReady,
                  let image = self.snapshotter.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(
            image: image,
            on: screen,
            startAngle: preferences.thresholdAngle,
            tuning: tuning,
            fadeIn: Self.fadeInDuration
        )
        // The link belongs to the overlay window.
        startDisplayLink()
    }

    private func blurProgress(for angle: Double) -> Double {
        let span = max(preferences.blurSpan, 1)
        return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else {
            Diagnostics.lid.notice("display link skipped, no overlay window")
            return
        }
        Diagnostics.lid.notice("display link started")
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        if streamer.isStarted, let frame = streamer.newFrame() {
            overlay.absorb(frame)
        }
        // Where the lid is heading, not the last reading, while it closes
        // fast: a reading can be a sensor refresh old.
        let target = isClosingOut ? preferences.thresholdAngle : (isActive ? predictedAngle() : rawAngle)
        visualAngle.advance(to: target, dt: dt)

        guard isClosingOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // At or above the threshold the picture is already flat, so a lid
        // that opened past it finishes at once.
        let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
        let timedOut = now - closingOutStartedAt > Self.closingOutMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // The frame that fades out must match the screen behind it exactly,
        // so land on the threshold itself rather than just short of it.
        visualAngle.reset(to: target)
        applyVisual(angle: target)
        finishClosingOut()
    }

    /// The geometry takes the lid angle itself, so only the blur saturates.
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        overlay.update(progress: progress, currentAngle: angle, tuning: tuning)
    }

    private var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: preferences.viewingDistance,
            recession: preferences.recession,
            blurEvenness: preferences.blurEvenness,
            dimReach: preferences.dimReach,
            maxBlurRadius: preferences.maxBlurRadius,
            maxDim: preferences.maxDim,
            blurSpan: preferences.blurSpan
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // macOS posts this for backlight and colour changes too.
                let screen = NSScreen.builtIn
                let layout = Layout(displayID: screen?.displayID, frame: screen?.frame)
                guard layout != self.builtInLayout else {
                    Diagnostics.lid.notice("screen parameters changed, layout unchanged")
                    return
                }
                Diagnostics.lid.notice(
                    "screen parameters changed, layout now \(String(describing: layout), privacy: .public)"
                )
                self.builtInLayout = layout
                if self.isActive { self.setActive(false) }
                self.streamer.stop()
                self.streamer.invalidateFilter()
                Task { await self.streamer.warmFilter() }
                self.overlay.discardLive()
                self.snapshotter.discard()
                Task { await self.snapshotter.warmFilter() }
                self.preparePortal()
            }
        }
    }

    private func suspend() {
        Diagnostics.lid.notice("suspend")
        isSuspended = true
        stopEffectAndCapture()
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        // Nothing listens while the Mac sleeps.
        if isPushing { sensor.setReportInterval(0) }
    }

    private func resume() {
        Diagnostics.lid.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        lastChangedAngle = nil
        recentAngles.removeAll()
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        wasTimeoutEnabled = false
        isClosingOut = false
        if let angle = sensor.angle() {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        if isPushing {
            pushInterval = Self.nearPushInterval
            sensor.setReportInterval(pushInterval)
        }
        wake()
    }
}
