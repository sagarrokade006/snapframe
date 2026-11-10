import AppKit
import AVFoundation
import SnapframeCore
import SwiftUI

struct StudioPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct StudioView: View {
    @ObservedObject var session: StudioSession
    @State private var showingExport = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    StudioPlayerView(player: session.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.snapGround)
                    transport
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StudioInspector(session: session).frame(width: 310)
            }
            StudioTimeline(session: session).frame(height: 232)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color.snapGround)
        .snapWindowStyle()
        .sheet(isPresented: $showingExport) {
            ExportSheet(session: session) { showingExport = false }
        }
        .alert("Snapframe", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.message ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 76)
            Text(session.project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(QuietButtonStyle()).disabled(!session.canUndo).opacity(session.canUndo ? 1 : 0.45)
                .keyboardShortcut("z", modifiers: .command)
            Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .buttonStyle(QuietButtonStyle()).disabled(!session.canRedo).opacity(session.canRedo ? 1 : 0.45)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Auto-zoom") { session.autoZoom() }.buttonStyle(QuietButtonStyle())
            Button("Export") { showingExport = true }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(Color.snapSidebar)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { session.togglePlay() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 18, height: 18)
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            Text(verbatim: "\(RecordingFormat.clock(session.playhead)) / \(RecordingFormat.clock(session.project.editedDuration))")
                .font(.system(size: 13)).monospacedDigit()
            Spacer()
            Text(verbatim: selectionNote).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
        }
    }

    private var selectionNote: String {
        if session.isLoading { return "Preparing the preview…" }
        let zooms = session.project.zooms.count, clips = session.project.clips.count
        return "\(zooms) \(zooms == 1 ? "zoom" : "zooms") · \(clips) \(clips == 1 ? "clip" : "clips")"
    }
}

// MARK: Timeline

private struct StudioTimeline: View {
    @ObservedObject var session: StudioSession
    private let labelWidth: CGFloat = 84

    private var project: StudioProject { session.project }
    private var total: Double { max(project.editedDuration, 0.01) }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            GeometryReader { proxy in
                let width = max(proxy.size.width - labelWidth - 14, 10)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 8) {
                        ruler(width: width)
                        track("Clips") { clipsLayer(width: width) }
                        track("Zoom") { zoomLayer(width: width) }
                        track("Audio") { waveformLayer }
                    }
                    Rectangle()
                        .fill(Color.snapText)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .offset(x: labelWidth + CGFloat(session.playhead / total) * width - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(Color.snapSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.snapRaised).frame(height: 1) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 14)
            Button("Split") { session.splitAtPlayhead() }.buttonStyle(QuietButtonStyle()).keyboardShortcut("s", modifiers: .command)
            Button("Delete Clip") { session.deleteSelectedClip() }
                .buttonStyle(QuietButtonStyle())
                .disabled(session.selectedClip == nil || project.clips.count < 2)
                .opacity(session.selectedClip == nil || project.clips.count < 2 ? 0.45 : 1)
            Button("Add Zoom") { session.addZoomAtPlayhead() }.buttonStyle(QuietButtonStyle())
            Spacer()
        }
    }

    private func track<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 13)).frame(width: labelWidth - 16, alignment: .leading).padding(.leading, 16)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whole-second marks at a spacing that fits, so a label never repeats.
    private var rulerTicks: [Double] {
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800].first { total / $0 <= 7 } ?? 3600
        return Array(stride(from: 0, through: total, by: step))
    }

    private func ruler(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth)
            ZStack(alignment: .leading) {
                Color.snapCard.opacity(0.5)
                ForEach(rulerTicks, id: \.self) { tick in
                    Text(verbatim: RecordingFormat.clock(tick))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.snapMuted)
                        .fixedSize()
                        .offset(x: min(CGFloat(tick / total) * width, width - 34))
                }
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if session.isPlaying { session.togglePlay() }
                session.seek(to: Double(value.location.x / width) * total)
            })
        }
    }

    private func clipsLayer(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
                let before = project.clips[..<index].reduce(0) { $0 + $1.duration }
                ClipBlock(session: session, clip: clip, width: CGFloat(clip.duration / total) * width, secondsPerPoint: total / Double(width))
                    .offset(x: CGFloat(before / total) * width)
            }
        }
    }

    private func zoomLayer(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.snapCard)
            ForEach(project.zooms) { zoom in
                if let start = project.timelineTime(forSource: zoom.start) ?? visibleStart(of: zoom) {
                    let end = project.timelineTime(forSource: zoom.end) ?? (start + (zoom.end - zoom.start))
                    ZoomBlock(session: session, zoom: zoom, width: max(CGFloat((end - start) / total) * width, 8), secondsPerPoint: total / Double(width))
                        .offset(x: CGFloat(start / total) * width)
                }
            }
        }
    }

    /// A zoom whose start was cut can still be partly visible in a later clip.
    private func visibleStart(of zoom: ZoomSegment) -> Double? {
        project.clips.first { $0.start >= zoom.start && $0.start < zoom.end }.flatMap { project.timelineTime(forSource: $0.start) }
    }

    private var waveformLayer: some View {
        Canvas { context, size in
            let bars = session.waveform
            guard !bars.isEmpty else { return }
            let step = max(Int(Double(bars.count) / Double(size.width / 3)), 1)
            var x: CGFloat = 0
            for index in stride(from: 0, to: bars.count, by: step) {
                let height = max(CGFloat(bars[index]) * size.height, 1)
                context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)), with: .color(Color(hex: 0x8FB7D9)))
                x += 3
            }
        }
        .background(Color.snapCard, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Audio waveform")
    }
}

private struct ClipBlock: View {
    @ObservedObject var session: StudioSession
    let clip: StudioClip
    let width: CGFloat
    let secondsPerPoint: Double

    @State private var original: StudioClip?

    private var isSelected: Bool { session.selectedClip == clip.id }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x5C8B94).opacity(0.55))
            RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.snapAccent : Color.clear, lineWidth: 2)
            HStack {
                handle { delta, base in session.project.trimClip(id: clip.id, start: base.start + delta) }
                Spacer()
                handle { delta, base in session.project.trimClip(id: clip.id, end: base.end + delta) }
            }
        }
        .frame(width: max(width - 2, 4))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedClip = isSelected ? nil : clip.id }
    }

    private func handle(_ apply: @escaping (Double, StudioClip) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.snapText.opacity(0.7))
            .frame(width: 5)
            .padding(.vertical, 8)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let base = original ?? clip
                original = base
                apply(Double(value.translation.width) * secondsPerPoint, base)
            }.onEnded { _ in
                original = nil
                session.trimEnded()
            })
    }
}

private struct ZoomBlock: View {
    @ObservedObject var session: StudioSession
    let zoom: ZoomSegment
    let width: CGFloat
    let secondsPerPoint: Double

    @State private var original: ZoomSegment?

    private var isSelected: Bool { session.selectedZoom == zoom.id }

    private func update(_ change: (inout ZoomSegment) -> Void) {
        guard let index = session.project.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        change(&session.project.zooms[index])
        session.liveChange()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.snapAccent)
            RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Color.snapText : Color.clear, lineWidth: 2)
            Text(verbatim: String(format: "%.1f×", zoom.level)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.snapInk).lineLimit(1)
            HStack(spacing: 0) {
                edge { delta, base, zoom in zoom.start = min(max(base.start + delta, 0), base.end - 0.3) }
                Spacer()
                edge { delta, base, zoom in zoom.end = max(min(base.end + delta, session.project.duration), base.start + 0.3) }
            }
        }
        .frame(width: width)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            session.selectedZoom = zoom.id
            session.tab = .zoom
        }
        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
            let base = original ?? zoom
            original = base
            let length = base.end - base.start
            let start = min(max(base.start + Double(value.translation.width) * secondsPerPoint, 0), session.project.duration - length)
            update {
                $0.start = start
                $0.end = start + length
            }
        }.onEnded { _ in
            original = nil
            session.commit()
        })
    }

    private func edge(_ apply: @escaping (Double, ZoomSegment, inout ZoomSegment) -> Void) -> some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let base = original ?? zoom
                original = base
                update { apply(Double(value.translation.width) * secondsPerPoint, base, &$0) }
            }.onEnded { _ in
                original = nil
                session.commit()
            })
    }
}

// MARK: Inspector

private struct StudioInspector: View {
    @ObservedObject var session: StudioSession

    private func binding<T>(_ path: WritableKeyPath<StudioAppearance, T>) -> Binding<T> {
        Binding(
            get: { session.project.appearance[keyPath: path] },
            set: {
                session.project.appearance[keyPath: path] = $0
                session.changed()
            }
        )
    }

    /// For sliders: redraws while dragging, and adds one undo step at the end.
    private func slider(_ title: String, _ path: WritableKeyPath<StudioAppearance, Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(session.project.appearance[keyPath: path])).foregroundStyle(Color.snapMuted)
            }
            Slider(value: Binding(
                get: { session.project.appearance[keyPath: path] },
                set: {
                    session.project.appearance[keyPath: path] = $0
                    session.liveChange()
                }
            ), in: range) { editing in
                if !editing { session.commit() }
            }
            .accessibilityLabel(title)
        }
    }

    private func canvasSlider(_ title: String, _ path: WritableKeyPath<CanvasStyle, CGFloat>, range: ClosedRange<CGFloat>, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                let value = session.project.appearance.canvas[keyPath: path]
                Text(verbatim: percent ? "\(Int(value * 100))%" : "\(Int(value))").foregroundStyle(Color.snapMuted)
            }
            Slider(value: Binding(
                get: { session.project.appearance.canvas[keyPath: path] },
                set: {
                    session.project.appearance.canvas[keyPath: path] = $0
                    session.liveChange()
                }
            ), in: range) { editing in
                if !editing { session.commit() }
            }
            .disabled(session.project.appearance.canvas.fill == .none)
            .accessibilityLabel(title)
        }
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<StudioAppearance, Bool>) -> some View {
        Toggle(title, isOn: binding(path)).toggleStyle(.switch).tint(.snapAccent)
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(StudioTab.allCases, id: \.self) { item in
                    Button {
                        session.tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(session.tab == item ? Color.snapOnText : Color.snapText)
                            .background(session.tab == item ? Color.snapText : Color.snapRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .padding(.top, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch session.tab {
                    case .zoom: zoomPane
                    case .cursor: cursorPane
                    case .keys: toggle("Show shortcuts pressed", \.showKeys)
                    case .camera: cameraPane
                    case .canvas: canvasPane
                    case .audio: audioPane
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.snapSidebar)
    }

    @ViewBuilder
    private var zoomPane: some View {
        if let zoom = session.selectedZoomBinding {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                    Spacer()
                    Text(verbatim: String(format: "%.1f×", zoom.wrappedValue.level)).foregroundStyle(Color.snapMuted)
                }
                Slider(value: zoom.level, in: 1.1...4) { editing in
                    if !editing { session.commit() }
                }
                .accessibilityLabel("Zoom level")
            }
            Toggle("Follow cursor", isOn: Binding(
                get: { zoom.wrappedValue.followsCursor },
                set: { follow in
                    var value = zoom.wrappedValue
                    if follow {
                        value.centerX = nil
                        value.centerY = nil
                    } else {
                        let point = StudioMotion.interpolated(session.project.mouse, at: value.start + (value.end - value.start) / 2)
                        value.centerX = point?.x ?? 0.5
                        value.centerY = point?.y ?? 0.5
                    }
                    zoom.wrappedValue = value
                    session.commit()
                }
            ))
            .toggleStyle(.switch)
            .tint(.snapAccent)
            Button("Delete Zoom") { session.deleteSelectedZoom() }.buttonStyle(QuietButtonStyle())
        } else {
            Text("Select a zoom in the timeline to adjust it, or add one at the playhead.").foregroundStyle(Color.snapMuted).fixedSize(horizontal: false, vertical: true)
        }
        Rectangle().fill(Color.snapRaised).frame(height: 1)
        Button("Create Zooms Automatically") { session.autoZoom() }.buttonStyle(QuietButtonStyle())
        Button("Remove All Zooms") { session.removeAllZooms() }.buttonStyle(QuietButtonStyle()).disabled(session.project.zooms.isEmpty)
    }

    @ViewBuilder
    private var cursorPane: some View {
        toggle("Show cursor", \.showCursor)
        VStack(alignment: .leading, spacing: 6) {
            Text("Style")
            PillSegment(options: CursorStyle.allCases.map { ($0, $0.title) }, selection: binding(\.cursorStyle), activeFill: .snapText)
        }
        slider("Size", \.cursorScale, range: 0.5...3) { String(format: "%.1f×", $0) }
        toggle("Smooth movement", \.smoothCursor)
        toggle("Hide when idle", \.hideCursorWhenIdle)
        toggle("Show clicks", \.showClicks)
    }

    @ViewBuilder
    private var cameraPane: some View {
        if session.project.hasCamera {
            toggle("Show camera", \.showCamera)
            slider("Size", \.cameraSize, range: 0.1...0.4) { "\(Int($0 * 100))%" }
            VStack(alignment: .leading, spacing: 6) {
                Text("Position")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())], spacing: 4) {
                    ForEach(CameraCorner.allCases, id: \.self) { corner in
                        Button(corner.title) {
                            session.project.appearance.cameraCorner = corner
                            session.changed()
                        }
                        .buttonStyle(QuietButtonStyle())
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(session.project.appearance.cameraCorner == corner ? Color.snapAccent : Color.clear, lineWidth: 2))
                    }
                }
            }
            toggle("Mirror", \.flipCamera)
            toggle("Shrink during zoom", \.shrinkCameraDuringZoom)
        } else {
            Text("This recording has no camera. Turn on Camera before recording to use it here.").foregroundStyle(Color.snapMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var canvasPane: some View {
        Text("Background").font(.system(size: 14, weight: .semibold))
        BackgroundPicker(
            fill: session.project.appearance.canvas.fill,
            change: {
                session.project.appearance.canvas.fill = $0
                session.liveChange()
            },
            commit: { session.commit() }
        )
        canvasSlider("Padding", \.padding, range: 8...140)
        canvasSlider("Corner radius", \.cornerRadius, range: 0...40)
        canvasSlider("Shadow", \.shadow, range: 0...1, percent: true)
    }

    @ViewBuilder
    private var audioPane: some View {
        if session.project.hasMicrophone {
            slider("Microphone", \.microphoneVolume, range: 0...2) { "\(Int($0 * 100))%" }
        }
        if session.project.hasSystemAudio {
            slider("System audio", \.systemVolume, range: 0...2) { "\(Int($0 * 100))%" }
        }
        if !session.project.hasMicrophone && !session.project.hasSystemAudio {
            Text("This recording has no audio.").foregroundStyle(Color.snapMuted)
        }
    }
}

private struct ExportSheet: View {
    @ObservedObject var session: StudioSession
    let close: () -> Void

    @State private var maximumHeight = 0
    @State private var started = false

    private var outputSize: CGSize { StudioComposition.renderSize(for: session.project, maximumHeight: maximumHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export video").font(.snapDisplay(20))
            if session.exporting || started {
                ProgressView(value: session.exportProgress).tint(.snapAccent)
                Text(verbatim: "\(Int(session.exportProgress * 100))%").foregroundStyle(Color.snapMuted).monospacedDigit()
                HStack {
                    Spacer()
                    Button("Cancel") {
                        session.cancelExport()
                        close()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            } else {
                PillSegment(options: [(0, "Original"), (1440, "1440p"), (1080, "1080p"), (720, "720p")], selection: $maximumHeight, activeFill: .snapText)
                Text(verbatim: "\(Int(outputSize.width)) × \(Int(outputSize.height)) · \(RecordingFormat.clock(session.project.editedDuration)) · MP4")
                    .foregroundStyle(Color.snapMuted)
                HStack {
                    Spacer()
                    Button("Cancel", action: close).buttonStyle(QuietButtonStyle())
                    Button("Export") {
                        started = true
                        session.export(maximumHeight: maximumHeight)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 420)
        .background(Color.snapSidebar)
        .snapWindowStyle()
        .onChange(of: session.exporting) { _, exporting in
            if !exporting, started { close() }
        }
    }
}
