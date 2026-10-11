import AppKit
import SwiftUI
import QuartzCore
@testable import PaulNotchCore

@MainActor private final class OrbFixtureVault: QuotaCredentialStoring {
    var reads = 0
    func read() throws -> String? {
        reads += 1
        return try CursorQuotaTokenPair(accessToken: "orb-fixture-access", refreshToken: "orb-fixture-refresh").serialized
    }
    func save(_ value: String) throws { throw QuotaConnectionError.preview }
    func delete() throws { throw QuotaConnectionError.preview }
}

private actor OrbFixtureTransport {
    let now: Date
    var used = 26
    var model = "Grok 4.7"
    var calls = 0
    init(now: Date) { self.now = now }
    func setUsed(_ value: Int) { used = value }
    func setModel(_ value: String) { model = value }
    func modelSelection() -> CursorModelSelection { CursorModelSelection.parse(model) ?? .unavailable }
    func fetch(_ request: URLRequest) throws -> QuotaHTTPResponse {
        calls += 1
        let payload: String
        switch request.url?.path {
        case CursorQuotaRequest.monthlyPath:
            let end = Int(now.addingTimeInterval(28 * 86400).timeIntervalSince1970 * 1000)
            payload = "{\"enabled\":true,\"billingCycleEnd\":\"\(end)\",\"planUsage\":{\"autoPercentUsed\":\(used),\"apiPercentUsed\":50}}"
        case CursorQuotaRequest.weeklyPath:
            let end = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86400))
            payload = "{\"usagePercent\":50,\"nextResetTimestampUtc\":\"\(end)\",\"hasNonZeroIncludedLimit\":true}"
        default: throw QuotaConnectionError.preview
        }
        return .init(status: 200, data: Data(payload.utf8), etag: nil)
    }
}

/// Real source adaptation and native pixels; no personal reads, vendor app or clipboard.
@main struct QuotaLiquidOrbValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
        }
        // Occlusion notifications/presentation layers require AppKit's real
        // event loop, not just an async command-line executor and offscreen cache.
        NSApp.run()
    }
    @MainActor static func run() async throws {
        guard AppEnvironment.isPreview, !AppEnvironment.codexStatusReadsEnabled else {
            throw Failure(description: "An isolated no-account preview is required")
        }
        let defaults = AppEnvironment.defaults, vault = OrbFixtureVault(), now = Date()
        defaults.set(true, forKey: "quota.cursor-account.enabled.v1")
        let transport = OrbFixtureTransport(now: now)
        let modelMonitor = CursorModelMonitor(defaults: defaults, allowsInspection: true,
            foregroundPID: { 999999 }, trusted: { true }, clock: { now }, read: { _ in await transport.modelSelection() })
        let cursor = CursorQuotaAccountStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { try await transport.fetch($0) }, modelMonitor: modelMonitor, clock: { now })
        let connections = QuotaConnectionsStore(defaults: defaults, vault: vault, allowsConnections: true,
            transport: { _ in throw QuotaConnectionError.preview }, cursorAccount: cursor)
        defer { connections.stop() }
        cursor.refreshDue()
        try await settle(cursor)
        modelMonitor.setEnabled(true)
        modelMonitor.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92", pid: 999999)
        try await Task.sleep(for: .milliseconds(900))
        let presentation = AmbientNotchPresentation()
        presentation.observeForeground(bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        presentation.isFloating = true
        let ambient = AmbientNotchView(codexStatus: CodexStatusStore(), connections: connections,
            presentation: presentation, onOpen: {})
        try require(ambient.quotaPresentation(at: now).lines.first?.value == .percent(74),
                    "the actual orb must receive the canonical source's remaining 74%, not used 26%")
        let host = NSHostingView(rootView: ambient)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 92, height: 92),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        let high = try raster(host)
        var failures = geometryAndGlassFailures()
        let haloPixels = outsidePixels(high)
        if haloPixels > 2 { failures.append("collapsed circle must not paint a drop shadow outside its silhouette; got \(haloPixels) pixels") }
        let highWater = liquidPixels(high)
        if highWater < 150 { failures.append("remaining 74% must render an actual colored liquid body, not only a flat gray percentage disc") }
        try save(high, "orb-74.png")
        await transport.setUsed(80)
        cursor.refreshDue(force: true)
        try await settle(cursor)
        try require(ambient.quotaPresentation(at: now).lines.first?.value == .percent(20),
                    "a changed canonical response updates the amount without a new login")
        let low = try raster(host)
        try save(low, "orb-20.png")
        if liquidPixels(low) >= highWater - 100 {
            failures.append("liquid must fall when remaining quota changes from 74% to 20%")
        }
        await transport.setUsed(100)
        cursor.refreshDue(force: true)
        try await settle(cursor)
        let empty = try raster(host)
        try save(empty, "orb-0.png")
        if liquidPixels(empty) > 20 { failures.append("zero quota must have no fake pool of liquid") }
        let calls = await transport.calls, reads = vault.reads
        await transport.setModel("Auto")
        modelMonitor.setEnabled(false); modelMonitor.setEnabled(true)
        try await Task.sleep(for: .milliseconds(900))
        let dual = try raster(host)
        try save(dual, "orb-auto-dual.png")
        if missingCirclePixels(dual) > 8 {
            failures.append("Auto's visible orb must fill the same centered circular silhouette, not two offset clipped circles")
        }
        try require(ambient.quotaPresentation(at: now).liquidValue == nil && liquidPixels(dual) < 20,
                    "Auto shows both pools but never paints one pool as its actual routed-model waterline")
        await transport.setModel("Claude Opus 5.5")
        modelMonitor.setEnabled(false); modelMonitor.setEnabled(true)
        try await Task.sleep(for: .milliseconds(900))
        let other = try raster(host)
        try save(other, "orb-opus-other.png")
        if missingCirclePixels(other) > 8 {
            failures.append("the selected-model orb must keep the same complete circle as Auto")
        }
        failures += try await nativeDragFailures(host: host, window: window)
        try require(ambient.quotaPresentation(at: now).lines.first?.value == .percent(50),
                    "Opus uses Other Models, not Cursor's now empty pool")
        presentation.isFloating = false
        window.setContentSize(NSSize(width: 202, height: 32))
        try save(raster(host), "model-notch-normal.png")
        presentation.isFrontmostAppFullScreen = true
        window.setContentSize(NSSize(width: 188, height: 24))
        try save(raster(host), "model-notch-fullscreen.png")
        await transport.setModel("Auto")
        modelMonitor.setEnabled(false); modelMonitor.setEnabled(true)
        try await Task.sleep(for: .milliseconds(900))
        try save(raster(host), "model-notch-auto.png")
        try require(await transport.calls == calls && vault.reads == reads,
                    "orb presentation/docking must not add network or credential reads")
        try levelAndMotionPolicy()
        try sloshPolicy()
        try await nativeMotionLifecycle()
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; throw Failure(description: failures.joined(separator: "; ")) }
        print("PASS: concentric glass circle, canonical waterline, drag-driven slosh/settle, bounded compositor motion and stop/resume lifecycle, no extra reads")
        if ProcessInfo.processInfo.environment["PAUL_ORB_INSPECT"] == "1", let screen = NSScreen.main {
            // Optional disposable native inspection only. Never a second product,
            // never personal sources, and never enabled by the regular validator.
            await transport.setUsed(26); await transport.setModel("Grok 4.7")
            cursor.refreshDue(force:true); try await settle(cursor)
            modelMonitor.setEnabled(false); modelMonitor.setEnabled(true)
            try await Task.sleep(for:.milliseconds(900))
            presentation.isFrontmostAppFullScreen = false; presentation.isFloating = true
            let board = NSWindow(contentRect:NSRect(x:screen.visibleFrame.midX-280,y:screen.visibleFrame.midY-100,width:560,height:200),
                                 styleMask:[.titled,.closable],backing:.buffered,defer:false)
            board.isReleasedWhenClosed = false
            board.title = "玻璃球验收 · 隔离样例，不读取账号"
            board.contentView = NSHostingView(rootView:HStack(spacing:0) {
                Color(white:0.94).overlay(Text("浅色背景").foregroundStyle(.black.opacity(0.7)).padding(),alignment:.bottom)
                Color(red:0.12,green:0.18,blue:0.24).overlay(Text("深色背景").foregroundStyle(.white.opacity(0.7)).padding(),alignment:.bottom)
            })
            board.level = .floating; board.orderFrontRegardless()
            window.setFrame(NSRect(x:board.frame.minX+90,y:board.frame.minY+75,width:92,height:92),display:true)
            window.level = .statusBar; window.orderFrontRegardless()
            let deadline = Date().addingTimeInterval(180)
            while board.isVisible, Date() < deadline { try await Task.sleep(for:.milliseconds(250)) }
            board.orderOut(nil)
        }
    }
    @MainActor static func geometryAndGlassFailures() -> [String] {
        var failures: [String] = []
        for (first, last): (CGFloat, CGFloat) in [(89,78),(78,89)] {
            let view = QuotaLiquidOrbView(frame: NSRect(x:0,y:0,width:78,height:first))
            view.configure(level: QuotaLiquidLevel(value:.percent(40)), reducedMotion:true)
            view.setFrameSize(NSSize(width:78,height:last)); view.layout()
            func findCircle(_ layer: CALayer?) -> CALayer? {
                guard let layer else { return nil }
                return layer.name == "quota-liquid-orb" ? layer : (layer.sublayers ?? []).compactMap(findCircle).first
            }
            let circle = findCircle(view.layer) ?? view.subviews.compactMap { findCircle($0.layer) }.first
            let expectedY: CGFloat = last == 78 ? 39 : 44.5
            if abs((circle?.frame.midY ?? -999) - expectedY) > 0.01 {
                failures.append("same-diameter layout \(first)->\(last) must recenter the circle at \(expectedY), got \(circle?.frame.midY ?? -999)")
            }
            if !view.subviews.contains(where: { $0 is NSVisualEffectView }) {
                failures.append("glass needs one bounded native backdrop, not an opaque painted ball")
            }
            view.stop()
        }
        return failures
    }
    @MainActor static func nativeDragFailures(host: NSView, window: NSWindow) async throws -> [String] {
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func layers(_ root: CALayer?) -> [CALayer] {
            guard let root else { return [] }
            return [root] + (root.sublayers ?? []).flatMap { layers($0) } + layers(root.mask)
        }
        guard let input = views(host).compactMap({ $0 as? FloatingQuotaInputView }).first,
              let orb = views(host).compactMap({ $0 as? QuotaLiquidOrbView }).first,
              let screen = NSScreen.main else { throw Failure(description:"real orb/input host missing") }
        let priorFrame = window.frame
        window.setFrameOrigin(NSPoint(x:screen.visibleFrame.minX+32,y:screen.visibleFrame.minY+32))
        window.level = .statusBar; window.orderFrontRegardless()
        try await Task.sleep(for:.milliseconds(150))
        defer { window.setFrame(priorFrame,display:false); window.orderBack(nil) }
        let base = ProcessInfo.processInfo.systemUptime
        func event(_ type:NSEvent.EventType, _ x:CGFloat, _ t:Double) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:46),modifierFlags:[],timestamp:base+t,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        input.mouseDown(with:event(.leftMouseDown,46,0))
        input.mouseDragged(with:event(.leftMouseDragged,70,0.05))
        input.mouseDragged(with:event(.leftMouseDragged,70,0.10))
        let masks = layers(orb.layer).filter { $0.name?.hasPrefix("quota-liquid-") == true && $0.name?.hasSuffix("-surface") == true }
        let slosh = masks.compactMap { $0.animation(forKey:"quota-liquid-slosh") as? CAKeyframeAnimation }
        var failures:[String] = []
        if !ProcessInfo.processInfo.isLowPowerModeEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if slosh.count != 2 { failures.append("dragging the existing native handle must drive both real liquid surfaces") }
            for animation in slosh {
                let values = (animation.values as? [NSValue])?.map(\.caTransform3DValue) ?? []
                if !values.contains(where: { abs($0.m12) > 0.015 }) {
                    failures.append("drag slosh must visibly tilt the liquid, not only translate the whole ball")
                }
                if animation.duration > 2.5 || values.count > 65 || values.isEmpty {
                    failures.append("each input must own only a bounded, finite compositor settle")
                }
            }
        }
        input.mouseUp(with:event(.leftMouseUp,46,0.15))
        CATransaction.flush()
        // Yield the main executor too: nested RunLoop spinning alone prevents
        // the native compositor's finite-animation removal from being drained.
        try await Task.sleep(for:.milliseconds(2300))
        // AppKit can retain completed mask-animation metadata. Its key's
        // presence is not activity: assert the finite interval and pixels' pose.
        if masks.contains(where: { mask in
            let animation = mask.animation(forKey:"quota-liquid-slosh")
            let stillRunning = animation.map {
                $0.repeatCount != 0 || $0.repeatDuration != 0 || $0.duration > 2.5 ||
                mask.convertTime(CACurrentMediaTime(),from:nil) < $0.beginTime + $0.duration
            } ?? false
            return stillRunning || abs(mask.transform.m12) > 0.001 || abs(mask.presentation()?.transform.m12 ?? 0) > 0.001
        }) {
            failures.append("release must reach a level presentation pose after a finite, nonrepeating response")
        }
        try save(raster(host),"orb-glass-settled.png")
        return failures
    }
    @MainActor static func levelAndMotionPolicy() throws {
        for (value, fraction): (QuotaOverviewValue?, Double?) in [
            (.percent(74), 0.74), (.percent(0), 0), (.percent(100), 1),
            (.percent(-1), nil), (.percent(101), nil), (.unknown, nil), (nil, nil),
            (.percentBound(lowerExclusive: 95, upperInclusive: 100), nil), (.unlimited, nil),
            (.money(74, currency: "CNY"), nil), (.credits(74, unit: "积分"), nil)
        ] {
            try require(QuotaLiquidLevel(value: value).fraction == fraction,
                        "only exact valid percentages get a water level; preserve other units/unknown/bounds")
        }
        let level = QuotaLiquidLevel(value: .percent(74))
        try require(level.animates(visible: true, reducedMotion: false, lowPower: false, awake: true),
                    "a visible partial quota has a gentle surface motion")
        for (visible, reduced, lowPower, awake) in [(false, false, false, true), (true, true, false, true),
                                                   (true, false, true, true), (true, false, false, false)] {
            try require(!level.animates(visible: visible, reducedMotion: reduced, lowPower: lowPower, awake: awake),
                        "invisible/reduced-motion/low-power/sleep states have no decorative animation")
        }
        for value: QuotaOverviewValue in [.percent(0), .percent(100), .unknown] {
            try require(!QuotaLiquidLevel(value: value).animates(visible: true, reducedMotion: false, lowPower: false, awake: true),
                        "empty/full/unknown amounts do not animate a fictitious water surface")
        }
        // Hand-derived: 78pt × 0.74 = 57.72pt from the bottom. Even at the
        // extreme wave phase, y=55 is wet and y=61 is dry at the disc center.
        for phase: CGFloat in [0, .pi / 2, .pi, .pi * 1.5, .pi * 2] {
            let path = level.wavePath(diameter: 78, phase: phase, amplitude: 1.3)
            try require(path.contains(CGPoint(x: 117, y: 55)) && !path.contains(CGPoint(x: 117, y: 61)),
                        "the surface oscillates about actual 74% height, not arbitrary decoration")
        }
        try require(!QuotaLiquidLevel(value: .percent(0)).wavePath(diameter: 78, phase: 0, amplitude: 1.3)
            .contains(CGPoint(x: 117, y: 1)), "0% is genuinely empty")
        try require(QuotaLiquidLevel(value: .percent(100)).wavePath(diameter: 78, phase: 0, amplitude: 1.3)
            .contains(CGPoint(x: 117, y: 77)), "100% fills to the top without an artificial wave gap")
    }
    @MainActor static func nativeMotionLifecycle() async throws {
        guard let screen = NSScreen.main else { throw Failure(description: "native display required") }
        let host = NSHostingView(rootView:QuotaLiquidOrb(value:.percent(74),reduceMotion:false).frame(width:78,height:78))
        host.sizingOptions = []
        let window = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX + 180, y: screen.visibleFrame.midY,
                                                  width: 78, height: 78),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false; window.ignoresMouseEvents = true; window.level = .statusBar
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func views(_ root:NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        guard let orb = views(host).compactMap({ $0 as? QuotaLiquidOrbView }).first else {
            throw Failure(description:"production native representable is missing from its actual hosting tree")
        }
        defer { orb.stop(); window.orderOut(nil) }
        func layers(_ layer: CALayer?) -> [CALayer] {
            guard let layer else { return [] }
            return [layer] + (layer.sublayers ?? []).flatMap { layers($0) } + layers(layer.mask)
        }
        func waveCount() -> Int { layers(orb.layer).filter { $0.animation(forKey: "quota-liquid-wave") != nil }.count }
        func animatedGradients() -> [CAGradientLayer] {
            layers(orb.layer).compactMap { $0 as? CAGradientLayer }.filter { !($0.animationKeys() ?? []).isEmpty }
        }
        var controlledRoot: CALayer?
        func isStill() -> Bool {
            // AppKit can detach the backing tree when ordering out. Retain
            // the owned root so teardown cannot pass just by hiding that tree.
            if let mounted = layers(orb.layer).first(where:{ $0.name == "quota-liquid-orb" }) { controlledRoot = mounted }
            return controlledRoot != nil && layers(controlledRoot).allSatisfy { ($0.animationKeys() ?? []).isEmpty }
        }
        func settle() async { try? await Task.sleep(for:.milliseconds(150)) }
        try require(waveCount() == 0, "an unmounted orb schedules no wave animation")
        window.orderFrontRegardless(); orb.layoutSubtreeIfNeeded(); CATransaction.flush(); await settle()
        let visibleDeadline = Date().addingTimeInterval(1)
        while !window.occlusionState.contains(.visible), Date() < visibleDeadline { await settle() }
        orb.configure(level: QuotaLiquidLevel(value: .percent(74)), reducedMotion: false)
        let permitted = !ProcessInfo.processInfo.isLowPowerModeEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if permitted {
            try require(window.occlusionState.contains(.visible), "the positive fixture is genuinely unoccluded, not merely ordered; activeSpace=\(window.isOnActiveSpace), visible=\(window.isVisible), frame=\(window.frame), screen=\(screen.visibleFrame), state=\(window.occlusionState.rawValue)")
            try require(waveCount() == 2, "one visible orb owns only two compositor wave animations")
            controlledRoot = layers(orb.layer).first { $0.name == "quota-liquid-orb" }
            let currents = animatedGradients()
            try require(!currents.isEmpty && currents.count <= 2,
                        "liquid below the waterline must also have bounded native flow, not only moving masks")
            try require(currents.allSatisfy { current in
                layers(current.superlayer?.mask).contains { layer in
                    guard let shape = layer as? CAShapeLayer else { return false }
                    return shape.name == "quota-liquid-front-mask" && shape.path != nil
                }
            },
                        "interior flow belongs inside the actual quota waterline, not over the empty glass")
            let firstCurrent = currents.map { $0.presentation()?.position ?? .zero }
            let masks = layers(orb.layer).compactMap { $0 as? CAShapeLayer }.filter { $0.animation(forKey: "quota-liquid-wave") != nil }
            let first = masks.map { $0.presentation()?.transform.m41 ?? 0 }
            try await Task.sleep(for:.milliseconds(250))
            let second = masks.map { $0.presentation()?.transform.m41 ?? 0 }
            let secondCurrent = currents.map { $0.presentation()?.position ?? .zero }
            try require(zip(first, second).allSatisfy { abs($0 - $1) > 0.2 },
                        "native presentation samples actually flow instead of freezing on the model pose")
            try require(zip(firstCurrent, secondCurrent).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.1 },
                        "the interior glow actually moves in the compositor")
            let t = CACurrentMediaTime()
            orb.beginDrag(x: 100, at: t)
            orb.moveDrag(x: 120, at: t + 0.05)
            orb.configure(level: QuotaLiquidLevel(value: .percent(73)), reducedMotion: false)
            orb.moveDrag(x: 160, at: t + 0.10)
            let activeSlosh = layers(orb.layer).compactMap { $0.animation(forKey: "quota-liquid-slosh") as? CAKeyframeAnimation }
            try require(activeSlosh.count == 2 && activeSlosh.allSatisfy { animation in
                (animation.values as? [NSValue])?.contains { abs($0.caTransform3DValue.m12) > 0.015 } == true
            }, "a genuine quota update during drag must preserve the input anchor and continue liquid response")
            orb.isHidden = true; await settle()
            try require(isStill(), "hiding the orb removes all surface and interior animations")
            try require(layers(orb.layer).compactMap { $0.mask }.allSatisfy { abs($0.transform.m12) < 0.001 },
                        "hiding during drag also restores level transforms")
            orb.isHidden = false; await settle()
            try require(waveCount() == 2, "showing the same orb resumes without new layer owners")
            window.orderOut(nil); await settle()
            if !isStill() { print("DIAGNOSTIC hidden window visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue); owned animations=\(layers(controlledRoot).compactMap { layer in (layer.animationKeys() ?? []).isEmpty ? nil : "\(layer.name ?? "layer"):\(layer.animationKeys() ?? [])" })") }
            try require(isStill(), "opening the workspace/hiding its circle stops all compositor work")
            window.orderFrontRegardless(); await settle()
            try require(waveCount() == 2, "returning to the circle resumes its visible animation")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            try require(isStill(), "sleep stops waves and interior flow")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try require(waveCount() == 2, "wake resumes only a visible valid circle")
        } else { print("NOTE: system Reduce Motion/Low Power keeps the native circle static; pure policy cases are executed") }
        orb.configure(level: QuotaLiquidLevel(value: .percent(74)), reducedMotion: true)
        try require(isStill(), "Reduced Motion stops all motion immediately while keeping the waterline")
        orb.configure(level: QuotaLiquidLevel(value: .unknown), reducedMotion: false)
        try require(isStill(), "unknown quota never retains a known animated fill")
        let vector = layers(orb.layer).first { $0.name == "quota-liquid-orb" }
        try require(vector != nil && layers(vector).count <= 15 && layers(vector).allSatisfy { $0.shadowOpacity == 0 },
                    "a single bounded vector tree has no exterior shadow")
        try require(orb.subviews.filter { $0 is NSVisualEffectView }.count == 1 &&
                    orb.subviews.allSatisfy { $0.frame == NSRect(x:0,y:0,width:78,height:78) },
                    "glass owns only one sphere-sized native backdrop, not a full-window effect")
        orb.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        orb.configure(level: QuotaLiquidLevel(value: .percent(74)), reducedMotion: false)
        try require(isStill(), "a dismantled orb cannot restart from late wake/configuration events")
    }
    static func sloshPolicy() throws {
        var still = QuotaOrbSlosh()
        still.begin(x:100, at:10)
        still.move(x:100, at:10.05)
        try require(still.sample(at:10.2).slope == 0, "a stationary pointer does not invent drag motion")
        var right = QuotaOrbSlosh()
        right.begin(x:100,at:10); right.move(x:120,at:10.05)
        try require(right.sample(at:10.10).slope < -0.015,
                    "rightward acceleration produces a leftward lag, not pointer-locked liquid")
        let beforeBrake = right.sample(at:10.10).velocity
        right.move(x:100,at:10.10)
        try require(right.sample(at:10.10).velocity > beforeBrake,
                    "direction reversal pushes the liquid back without changing the quota")
        let deterministic = right.sample(at:10.18).slope
        _ = right.sample(at:10.40)
        try require(right.sample(at:10.18).slope == deterministic,
                    "sampling is analytic and independent of frame order")
        right.end(at:10.15)
        for step in 0...200 {
            let sample = right.sample(at:10.15 + Double(step)/100)
            try require(sample.slope.isFinite && sample.velocity.isFinite && abs(sample.slope) <= 0.31,
                        "bounded impulses cannot explode or create nonfinite transforms")
        }
        try require(right.sample(at:12.15).slope == 0 && right.sample(at:12.15).velocity == 0,
                    "release reaches exact rest within two seconds")
        right.cancel()
        try require(!right.move(x:30,at:20) && right.sample(at:20).slope == 0,
                    "cancellation drops old input and response")
        var invalid = QuotaOrbSlosh()
        invalid.begin(x:0,at:1)
        try require(!invalid.move(x:.nan,at:1.1) && !invalid.move(x:10,at:.infinity) &&
                    !invalid.move(x:10,at:0.9) && !invalid.move(x:10,at:1.001),
                    "invalid, backwards and coalesced timestamps cannot produce a force")
        try require(!invalid.move(x:1000,at:2), "long input gaps reanchor instead of causing a huge impulse")
        try require(invalid.sample(at:2.1).slope == 0, "reanchor is visually still")
        var paused = QuotaOrbSlosh()
        paused.begin(x:0,at:1); paused.move(x:40,at:1.05)
        paused.end(at:4)
        try require(paused.sample(at:4.1).slope == 0,
                    "releasing after a long pause must not resurrect a stale velocity")
    }
    @MainActor static func settle(_ cursor: CursorQuotaAccountStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while cursor.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(!cursor.isRefreshing, "controlled source read completes")
        try await Task.sleep(for: .milliseconds(120))
    }
    @MainActor static func raster(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(description: "native raster unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    static func outsidePixels(_ image: NSBitmapImageRep) -> Int {
        let sx = CGFloat(image.pixelsWide) / 92, sy = CGFloat(image.pixelsHigh) / 92
        var count = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if hypot(CGFloat(x) / sx - 46, CGFloat(y) / sy - 46) > 41,
               let color = image.colorAt(x: x, y: y), color.alphaComponent > 0.015 { count += 1 }
        } }
        return count
    }
    static func missingCirclePixels(_ image: NSBitmapImageRep) -> Int {
        let sx = CGFloat(image.pixelsWide)/92, sy = CGFloat(image.pixelsHigh)/92
        var count = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if hypot(CGFloat(x)/sx-46,CGFloat(y)/sy-46) < 37.5,
               (image.colorAt(x:x,y:y)?.alphaComponent ?? 0) < 0.05 { count += 1 }
        } }
        return count
    }
    static func liquidPixels(_ image: NSBitmapImageRep) -> Int {
        let sx = CGFloat(image.pixelsWide) / 92, sy = CGFloat(image.pixelsHigh) / 92
        var count = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if hypot(CGFloat(x) / sx - 46, CGFloat(y) / sy - 46) < 37,
               let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.blueComponent > color.redComponent + 0.15,
               color.blueComponent > color.greenComponent + 0.03 { count += 1 }
        } }
        return count
    }
    static func save(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let root = ProcessInfo.processInfo.environment["PAUL_ORB_EVIDENCE"],
              let data = image.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}
