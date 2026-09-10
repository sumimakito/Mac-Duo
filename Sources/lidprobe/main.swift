import Foundation
import LidAngleKit

/// Diagnostic tool for the lid angle sensor.
///
///     lidprobe            stream the angle until interrupted
///     lidprobe rate       measure how often the hardware value changes
///     lidprobe record 60  every read for 60 s, with a wall clock stamp
///     lidprobe watch 15   look for the angle rising while the lid closes

let sensor = LidAngleSensor()

guard sensor.isAvailable, let resolution = sensor.resolution else {
    FileHandle.standardError.write(Data("no lid angle sensor found on this Mac\n".utf8))
    exit(1)
}

print("sensor found: \(resolution.describedName)")

let mode = CommandLine.arguments.dropFirst().first ?? "stream"

switch mode {
case "watch":
    let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "15") ?? 15
    print("recording for \(Int(seconds)) s at 200 Hz. Close the lid fast, hold it down, then open.")
    let start = Date()
    var samples: [(t: Double, angle: Double)] = []
    var failures = 0
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        if let angle = sensor.angle() { samples.append((t, angle)) } else { failures += 1 }
        usleep(5000)
    }
    print("reads \(samples.count), failed reads \(failures)")
    guard let lowest = samples.min(by: { $0.angle < $1.angle }) else { break }
    print(String(format: "lowest angle %.2f at %.2f s", lowest.angle, lowest.t))

    // Every value change: time, angle, step.
    var changes: [(t: Double, angle: Double, step: Double)] = []
    var previous = samples[0].angle
    for sample in samples where sample.angle != previous {
        changes.append((sample.t, sample.angle, sample.angle - previous))
        previous = sample.angle
    }
    print("value changes \(changes.count)")
    let rises = changes.filter { $0.step > 0.5 }
    print("upward steps larger than 0.5 deg: \(rises.count)")
    for rise in rises.prefix(40) {
        print(String(format: "  t %6.3f s  angle %7.2f  step %+6.2f", rise.t, rise.angle, rise.step))
    }
    // Largest gap between successive changes, to show the hardware rate.
    var widest = 0.0
    for index in 1..<max(1, changes.count) {
        widest = max(widest, changes[index].t - changes[index - 1].t)
    }
    print(String(format: "widest gap between value changes %.3f s", widest))

case "record":
    // Every read with a wall clock stamp, so the trace lines up with the
    // app's own log.
    let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "30") ?? 30
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss.SSS"
    print("recording for \(Int(seconds)) s. Reproduce the gesture now.")
    fflush(stdout)

    // Written as it goes, so an interrupted run still leaves its trace.
    var reads = 0
    var failures = 0
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        let stamp = clock.string(from: Date())
        if let angle = sensor.angle() {
            reads += 1
            print(stamp + " " + String(format: "%.2f", angle))
        } else {
            failures += 1
            let trace = sensor.lastRead
            let hex = trace.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let rejected = trace.rejectedDegrees.map { String(format: "%.2f", $0) } ?? "-"
            print(
                stamp + " FAIL status 0x" + String(UInt32(bitPattern: trace.status), radix: 16)
                    + " length \(trace.length) bytes [\(hex)] rejected \(rejected)"
            )
        }
        if (reads + failures) % 30 == 0 { fflush(stdout) }
        // 60 Hz, six times the hardware rate.
        usleep(14000)
    }
    print("# reads \(reads), failed reads \(failures)")

case "rate":
    print("measuring for 8 s — hold still, sensor noise reveals the refresh rate")
    let start = Date()
    var changeTimes: [TimeInterval] = []
    var lastValue = -999.0
    var reads = 0
    while Date().timeIntervalSince(start) < 8 {
        if let angle = sensor.angle() {
            reads += 1
            if angle != lastValue {
                changeTimes.append(Date().timeIntervalSince(start))
                lastValue = angle
            }
        }
        usleep(4000)
    }
    var gaps: [TimeInterval] = []
    for index in 1..<max(1, changeTimes.count) {
        gaps.append(changeTimes[index] - changeTimes[index - 1])
    }
    print("reads: \(reads)   value changes: \(changeTimes.count)")
    if gaps.isEmpty {
        print("the value never changed, so the refresh rate cannot be derived")
    } else {
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "gap between changes: min %.1f ms, median %.1f ms", sorted[0] * 1000, median * 1000))
        print(String(format: "effective refresh rate: %.1f Hz", 1 / median))
    }

default:
    print("streaming at 30 Hz, press ctrl-c to stop")
    while true {
        if let angle = sensor.angle() {
            print(String(format: "%7.2f°", angle))
        } else {
            print("read failed")
        }
        fflush(stdout)
        usleep(33_333)
    }
}
