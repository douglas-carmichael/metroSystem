import SwiftUI
import SceneKit
import AppKit
import Combine

/// The 3D line synoptic: a SceneKit view of the circular VAL line with
/// every canton, station and rame, framed by a VT320-style HUD. The
/// scene reconciles its nodes against `MetroWorld` on every world tick
/// (the same coordinator pattern as the DCL windows: SwiftUI owns the
/// chrome, the Coordinator owns the SceneKit graph). Both the HUD and
/// the scene graph follow the active display skin (`ScenePalette`):
/// phosphor-on-black in retro, the muted ISA-101 canvas under iso101.
struct MetroSceneWindow: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @State private var recenterTrigger: Int = 0
    @State private var isolatedTrainId: UUID? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetroSceneRepresentable(
                world: world,
                cantonShort: language.t("block.short"),
                recenterTrigger: recenterTrigger,
                isolatedTrainId: isolatedTrainId
            )
            .ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            HudOverlay(
                isolatedTrainId: $isolatedTrainId,
                onRecenter: {
                    isolatedTrainId = nil
                    recenterTrigger &+= 1
                },
                onIsolate: { advanceIsolation() }
            )
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(RetroTheme.bg)
        .id(language.themeKind)
        .environment(\.colorScheme, language.themeKind == .retro ? .dark : .light)
        .navigationTitle(language.t("window.scene"))
        .onChange(of: world.trains.count) {
            if let id = isolatedTrainId,
               !world.trains.contains(where: { $0.id == id }) {
                isolatedTrainId = nil
            }
        }
    }

    /// Picks the next rame to follow. First press chooses an alarmed rame
    /// if any is active (so the operator drill-down lands on the rame that
    /// needs attention); subsequent presses cycle through the fleet.
    private func advanceIsolation() {
        let pool = world.sortedTrains
        guard !pool.isEmpty else { isolatedTrainId = nil; return }
        if isolatedTrainId == nil {
            for train in pool {
                let source = "RAME \(train.label)"
                if world.activeAlarms.contains(where: { $0.source == source }) {
                    isolatedTrainId = train.id
                    return
                }
            }
            isolatedTrainId = pool[0].id
            return
        }
        if let i = pool.firstIndex(where: { $0.id == isolatedTrainId }) {
            isolatedTrainId = pool[(i + 1) % pool.count].id
        } else {
            isolatedTrainId = pool[0].id
        }
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.intersection([.command, .option, .control]).isEmpty else { return ev }
        let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "l":
            language.cycle()
            return nil
        case "r":
            isolatedTrainId = nil
            recenterTrigger &+= 1
            return nil
        case "i":
            advanceIsolation()
            return nil
        case "q":
            NSApp.terminate(nil)
            return nil
        default:
            return ev
        }
    }
}

private struct HudOverlay: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @Binding var isolatedTrainId: UUID?
    let onRecenter: () -> Void
    let onIsolate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("─ \(language.t("window.scene")) ─")
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            HStack(spacing: 18) {
                StatusLine(label: language.t("hud.rames"),
                           value: "\(world.trains.count)",
                           valueColor: RetroTheme.green)
                StatusLine(label: language.t("hud.mode"),
                           value: modeValue,
                           valueColor: modeColor)
            }
            HStack(spacing: 12) {
                RetroButton(language.t("scene.recenter")) {
                    onRecenter()
                }
                RetroButton(language.t("scene.isolate")) {
                    onIsolate()
                }
            }
            .padding(.top, 4)

            if let id = isolatedTrainId,
               let train = world.trains.first(where: { $0.id == id }) {
                Text("\(language.t("scene.isolated.prefix")) \(language.t("train.rame")) \(train.label)")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.cyan)
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                ForEach(Lang.allCases) { lang in
                    RetroButton(lang.code, highlighted: language.current == lang) {
                        language.current = lang
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(RetroTheme.bgPanel.opacity(0.85))
        .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.6), lineWidth: 1))
    }

    private var modeValue: String {
        switch world.lineMode {
        case .stopped:           return language.t("status.mode.stopped")
        case .normal:            return language.t("status.mode.normal")
        case .serviceProvisoire: return language.t("status.mode.sp")
        case .emergency:         return language.t("status.mode.emergency")
        }
    }

    private var modeColor: Color {
        switch world.lineMode {
        case .normal:            return RetroTheme.green
        case .stopped:           return RetroTheme.amberDim
        case .serviceProvisoire: return RetroTheme.cyan
        case .emergency:         return RetroTheme.red
        }
    }
}

/// NSColor twins of `RetroTheme` for the SceneKit graph, resolved against
/// the active skin. Retro keeps the phosphor-on-black look with emissive
/// glow; iso101 is the ISA-101 high-performance palette — a neutral-grey
/// canvas, quiet greys / grey-green for normal states, glow off, and
/// saturated red reserved for alarm states. The window root carries
/// `.id(themeKind)`, so a skin switch rebuilds the representable (and its
/// Coordinator, and every baked label texture) wholesale — nothing needs
/// to re-theme a live scene graph.
private enum ScenePalette {
    static var isISO: Bool { RetroTheme.kind == .iso101 }

    // Canvas. The iso101 floor sits a shade darker than the sky so the
    // horizon still reads; reflections are decorative, so retro-only.
    static var background: NSColor {
        isISO ? NSColor(deviceRed: 0.85, green: 0.85, blue: 0.83, alpha: 1) : .black
    }
    static var floor: NSColor {
        isISO ? NSColor(deviceRed: 0.80, green: 0.80, blue: 0.78, alpha: 1)
              : NSColor(white: 0.03, alpha: 1)
    }
    static var floorReflectivity: CGFloat { isISO ? 0 : 0.05 }

    // Lighting: warm phosphor key in retro; flat neutral light under
    // ISA-101 (form shading only, no colour cast).
    static var ambientLight: NSColor { NSColor(white: isISO ? 0.70 : 0.35, alpha: 1) }
    static var keyLight: NSColor {
        isISO ? NSColor(white: 1.0, alpha: 1)
              : NSColor(deviceRed: 1.0, green: 0.85, blue: 0.5, alpha: 1)
    }
    static var keyLightIntensity: CGFloat { isISO ? 700 : 1400 }

    // Structure (PCC hub) and secondary text (canton numbers).
    static var structure: NSColor {
        isISO ? NSColor(deviceRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
              : NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
    }
    static var structureGlow: NSColor {
        isISO ? .black : NSColor(deviceRed: 0.5, green: 0.33, blue: 0.06, alpha: 1)
    }
    static var dimText: NSColor {
        isISO ? NSColor(deviceRed: 0.44, green: 0.44, blue: 0.46, alpha: 1)
              : NSColor(deviceRed: 0.62, green: 0.45, blue: 0.12, alpha: 1)
    }

    // Track and cantons. Barred SP sections fade toward the canvas in both
    // skins — down to near-black in retro, up to near-grey under ISA-101 —
    // so a de-energised section always recedes.
    static var track: NSColor {
        isISO ? NSColor(deviceRed: 0.35, green: 0.35, blue: 0.37, alpha: 1)
              : NSColor(deviceRed: 0.55, green: 0.42, blue: 0.15, alpha: 1)
    }
    static var trackGlow: NSColor {
        isISO ? .black : NSColor(deviceRed: 0.28, green: 0.20, blue: 0.05, alpha: 1)
    }
    static var trackBarred: NSColor {
        isISO ? NSColor(deviceRed: 0.68, green: 0.68, blue: 0.66, alpha: 1)
              : NSColor(white: 0.14, alpha: 1)
    }
    static var trackBarredGlow: NSColor {
        isISO ? .black : NSColor(white: 0.02, alpha: 1)
    }
    static var cantonMarker: NSColor { NSColor(white: isISO ? 0.45 : 0.85, alpha: 1) }
    static var cantonMarkerGlow: NSColor { isISO ? .black : NSColor(white: 0.35, alpha: 1) }

    // Stations. The label shares the info accent (`accent`) with manual
    // mode and alighting pax — cyan in retro, the muted ISA-101 blue in iso.
    static var platform: NSColor {
        isISO ? NSColor(deviceRed: 0.62, green: 0.62, blue: 0.60, alpha: 1)
              : NSColor(deviceRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
    }
    static var platformGlow: NSColor {
        isISO ? .black : NSColor(deviceRed: 0.10, green: 0.07, blue: 0.02, alpha: 1)
    }
    static var accent: NSColor {
        isISO ? NSColor(deviceRed: 0.11, green: 0.33, blue: 0.60, alpha: 1)
              : NSColor(deviceRed: 0.45, green: 0.95, blue: 1.0, alpha: 1)
    }

    // Rame body by state. Under ISA-101 the normal states (moving / docked /
    // idle) are quiet greys and grey-green so the saturated alarm red is the
    // only loud thing on the canvas; retro keeps the phosphor state coding.
    static var trainAlarm: NSColor {
        isISO ? NSColor(deviceRed: 0.78, green: 0.11, blue: 0.11, alpha: 1)
              : NSColor(deviceRed: 1.0, green: 0.30, blue: 0.28, alpha: 1)
    }
    static var trainManual: NSColor { accent }
    static var trainMoving: NSColor {
        isISO ? NSColor(deviceRed: 0.28, green: 0.40, blue: 0.30, alpha: 1)
              : NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)
    }
    static var trainDocked: NSColor {
        isISO ? NSColor(deviceRed: 0.35, green: 0.35, blue: 0.37, alpha: 1)
              : NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
    }
    static var trainIdle: NSColor {
        isISO ? NSColor(deviceRed: 0.52, green: 0.52, blue: 0.54, alpha: 1)
              : NSColor(deviceRed: 0.62, green: 0.45, blue: 0.12, alpha: 1)
    }
    static var trainLabel: NSColor {
        isISO ? structure : NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)
    }
    static func bodyGlow(_ color: NSColor) -> NSColor {
        isISO ? .black : color.withAlphaComponent(0.45)
    }

    // Sliding doors.
    static var doorway: NSColor { NSColor(white: isISO ? 0.10 : 0.02, alpha: 1) }
    static var doorLeaf: NSColor { NSColor(white: isISO ? 0.80 : 0.72, alpha: 1) }
    static var doorLeafGlow: NSColor { isISO ? .black : NSColor(white: 0.16, alpha: 1) }

    // Pax dots: boarding shares the healthy family, alighting the info
    // accent; self-lit in retro, flat under ISA-101.
    static var paxBoarding: NSColor { trainMoving }
    static var paxAlighting: NSColor { accent }
    static func paxGlow(_ color: NSColor) -> NSColor { isISO ? .black : color }

    // Billboard label textures: the VT323 phosphor face in retro, the
    // system monospace under ISA-101 (same rule as `RetroTheme.mono`).
    static func labelFont(size: CGFloat) -> NSFont {
        if isISO { return .monospacedSystemFont(ofSize: size, weight: .semibold) }
        return NSFont(name: RetroTheme.retroFontName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    }
}

struct MetroSceneRepresentable: NSViewRepresentable {
    let world: MetroWorld
    let cantonShort: String
    let recenterTrigger: Int
    let isolatedTrainId: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(world: world, cantonShort: cantonShort)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = ScenePalette.background
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.isolatedTrainId = isolatedTrainId
        context.coordinator.sync()
        if recenterTrigger != context.coordinator.lastRecenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            context.coordinator.recenterCamera()
        }
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        let world: MetroWorld
        let cantonShort: String
        var lastRecenterTrigger: Int = 0
        var isolatedTrainId: UUID? = nil
        private weak var sceneView: SCNView?
        private var trainNodes: [UUID: TrainNodes] = [:]
        private var cantonNodes: [Int: [SCNNode]] = [:]
        private var stationNodes: [Int: SCNNode] = [:]
        private var cameraNode: SCNNode?
        private var defaultCameraPosition = SCNVector3(0, 300, 300)
        private var defaultCameraEuler = SCNVector3(-Double.pi / 4, 0, 0)
        private var cancellables = Set<AnyCancellable>()
        private var lastBarredIds: Set<Int>? = nil

        /// Loop radius derived from the track length so scene positions
        /// are the model's real metres.
        private let radius: Double = Sim.trackLength / (2 * .pi)
        /// Chords per canton -- 4 per canton turns the decagon into a
        /// smooth-reading 40-gon.
        private let chordsPerCanton = 4

        final class TrainNodes {
            let root: SCNNode
            let body: SCNNode
            let label: SCNNode
            let doorLeft: SCNNode
            let doorRight: SCNNode
            var lastDoorsOpen = false
            var paxTick = 0
            init(root: SCNNode, body: SCNNode, label: SCNNode,
                 doorLeft: SCNNode, doorRight: SCNNode) {
                self.root = root; self.body = body; self.label = label
                self.doorLeft = doorLeft; self.doorRight = doorRight
            }
        }

        init(world: MetroWorld, cantonShort: String) {
            self.world = world
            self.cantonShort = cantonShort
            buildStaticScene()
            world.$trains
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
                .store(in: &cancellables)
            world.$activeSP
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.lastBarredIds = nil       // force a recolor pass
                    self?.sync()
                }
                .store(in: &cancellables)
        }

        func attach(view: SCNView) {
            self.sceneView = view
            if let cam = cameraNode {
                view.pointOfView = cam
            }
        }

        func recenterCamera() {
            guard let cam = cameraNode else { return }
            cam.position = defaultCameraPosition
            cam.eulerAngles = defaultCameraEuler
            // allowsCameraControl swaps in its own pointOfView once the user
            // orbits; reassigning forces the SCNView back to our camera.
            sceneView?.pointOfView = cam
        }

        // MARK: -- geometry helpers

        private func point(at position: Double, y: Double = 0, radialScale: Double = 1.0) -> SCNVector3 {
            let angle = position / Sim.trackLength * 2 * .pi
            return SCNVector3(radius * radialScale * cos(angle),
                              y,
                              radius * radialScale * sin(angle))
        }

        // MARK: -- static scene

        private func buildStaticScene() {
            scene.background.contents = ScenePalette.background

            let camera = SCNCamera()
            camera.fieldOfView = 50
            camera.zNear = 1
            camera.zFar = 5000
            let camNode = SCNNode()
            camNode.camera = camera
            camNode.position = defaultCameraPosition
            camNode.eulerAngles = defaultCameraEuler
            scene.rootNode.addChildNode(camNode)
            self.cameraNode = camNode

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = ScenePalette.ambientLight
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.color = ScenePalette.keyLight
            key.light?.intensity = ScenePalette.keyLightIntensity
            key.position = SCNVector3(0, 400, 0)
            scene.rootNode.addChildNode(key)

            // The floor is the canvas: a dark faintly-reflective plane reads
            // like a vector display in retro; a flat neutral-grey sheet under
            // ISA-101.
            let floor = SCNFloor()
            floor.reflectivity = ScenePalette.floorReflectivity
            floor.firstMaterial?.diffuse.contents = ScenePalette.floor
            floor.firstMaterial?.lightingModel = .constant
            let floorNode = SCNNode(geometry: floor)
            floorNode.position = SCNVector3(0, -1.5, 0)
            scene.rootNode.addChildNode(floorNode)

            // PCC marker at the centre of the loop.
            let hub = SCNBox(width: 12, height: 6, length: 12, chamferRadius: 0.5)
            hub.firstMaterial?.diffuse.contents = ScenePalette.structure
            hub.firstMaterial?.emission.contents = ScenePalette.structureGlow
            let hubNode = SCNNode(geometry: hub)
            hubNode.position = SCNVector3(0, 3, 0)
            scene.rootNode.addChildNode(hubNode)
            let hubLabel = makeBillboardLabel(text: "PCC", height: 10,
                                              color: ScenePalette.structure)
            hubLabel.position = SCNVector3(0, 14, 0)
            scene.rootNode.addChildNode(hubLabel)

            drawTrack()
            drawStations()
        }

        /// The circular double-rail track, one arc of chords per canton so
        /// each canton can be recolored independently when a service
        /// provisoire bars part of the line.
        private func drawTrack() {
            for canton in world.cantons {
                var nodes: [SCNNode] = []
                let step = canton.length / Double(chordsPerCanton)
                for i in 0..<chordsPerCanton {
                    let p1 = point(at: canton.startPosition + Double(i) * step)
                    let p2 = point(at: canton.startPosition + Double(i + 1) * step)
                    let line = buildLine(from: p1, to: p2, radius: 0.8)
                    scene.rootNode.addChildNode(line)
                    nodes.append(line)
                }
                cantonNodes[canton.id] = nodes

                // Canton boundary marker + number.
                let marker = SCNNode(geometry: SCNSphere(radius: 1.6))
                marker.geometry?.firstMaterial?.diffuse.contents = ScenePalette.cantonMarker
                marker.geometry?.firstMaterial?.emission.contents = ScenePalette.cantonMarkerGlow
                marker.position = point(at: canton.startPosition)
                scene.rootNode.addChildNode(marker)

                let numLabel = makeBillboardLabel(
                    text: String(format: cantonShort, canton.id), height: 6,
                    color: ScenePalette.dimText)
                numLabel.position = point(at: canton.startPosition + canton.length / 2,
                                          y: 3, radialScale: 0.92)
                scene.rootNode.addChildNode(numLabel)
            }
        }

        private func drawStations() {
            for station in world.stations {
                let platform = SCNBox(width: 10, height: 2, length: 24, chamferRadius: 0)
                platform.firstMaterial?.diffuse.contents = ScenePalette.platform
                platform.firstMaterial?.emission.contents = ScenePalette.platformGlow
                let node = SCNNode(geometry: platform)
                node.position = point(at: station.position, y: 1, radialScale: 1.10)
                // Face the platform along the track tangent.
                let trackPoint = point(at: station.position)
                node.look(at: SCNVector3(trackPoint.x, 1, trackPoint.z),
                          up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, 1))
                scene.rootNode.addChildNode(node)
                stationNodes[station.id] = node

                let label = makeBillboardLabel(
                    text: station.name, height: 7,
                    color: ScenePalette.accent)
                label.position = point(at: station.position, y: 12, radialScale: 1.16)
                scene.rootNode.addChildNode(label)
            }
        }

        private func buildLine(from: SCNVector3, to: SCNVector3, radius: CGFloat) -> SCNNode {
            let vector = SCNVector3(to.x - from.x, to.y - from.y, to.z - from.z)
            let distance = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
            let mid = SCNVector3((from.x + to.x) / 2, (from.y + to.y) / 2, (from.z + to.z) / 2)

            let geometry = SCNCylinder(radius: radius, height: CGFloat(distance))
            geometry.firstMaterial?.diffuse.contents = ScenePalette.track
            geometry.firstMaterial?.emission.contents = ScenePalette.trackGlow

            let node = SCNNode(geometry: geometry)
            node.position = mid
            node.look(at: to, up: scene.rootNode.worldUp, localFront: node.worldUp)
            return node
        }

        // MARK: -- reconcile

        func sync() {
            let trains = world.trains
            let liveIds = Set(trains.map(\.id))

            for (id, nodes) in trainNodes where !liveIds.contains(id) {
                nodes.root.removeFromParentNode()
                trainNodes.removeValue(forKey: id)
            }

            for train in trains {
                let nodes = trainNodes[train.id] ?? makeTrainNodes(for: train)
                trainNodes[train.id] = nodes
                updateTrain(nodes: nodes, train: train)
            }

            recolorBarredSections()
            applyIsolationCamera()
        }

        /// Dim the cantons and stations outside the active SP section so
        /// the barred line reads like a de-energised track diagram.
        private func recolorBarredSections() {
            let active = Set(world.activeStations().map(\.id))
            let barredStations = Set(world.stations.map(\.id)).subtracting(active)

            // Canton is "barred" when its midpoint lies outside the active
            // section; with no SP nothing is barred.
            var barredCantons = Set<Int>()
            if let sp = world.activeSP,
               let s1 = world.stations.first(where: { $0.id == sp.startStationId }),
               let s2 = world.stations.first(where: { $0.id == sp.endStationId }) {
                let (lo, hi) = (min(s1.position, s2.position), max(s1.position, s2.position))
                for canton in world.cantons {
                    let mid = canton.startPosition + canton.length / 2
                    let inside: Bool
                    if s1.position <= s2.position {
                        inside = mid >= lo && mid <= hi
                    } else {
                        inside = mid >= s1.position || mid <= s2.position
                    }
                    if !inside { barredCantons.insert(canton.id) }
                }
            }

            // Only touch materials when the barred set changes -- material
            // writes on every 60 Hz tick would be wasted work.
            let key = barredCantons.union(barredStations.map { $0 + 1000 })
            if lastBarredIds == key { return }
            lastBarredIds = key

            for canton in world.cantons {
                let barred = barredCantons.contains(canton.id)
                for node in cantonNodes[canton.id] ?? [] {
                    node.geometry?.firstMaterial?.diffuse.contents = barred ? ScenePalette.trackBarred : ScenePalette.track
                    node.geometry?.firstMaterial?.emission.contents = barred ? ScenePalette.trackBarredGlow : ScenePalette.trackGlow
                }
            }
            for station in world.stations {
                let barred = barredStations.contains(station.id)
                stationNodes[station.id]?.opacity = barred ? 0.25 : 1.0
            }
        }

        /// Follow-camera drill-down on one rame: park the camera on a chase
        /// position above and outside its track point. Re-applied every
        /// sync so the camera tracks the moving rame.
        private func applyIsolationCamera() {
            guard let id = isolatedTrainId,
                  let train = world.trains.first(where: { $0.id == id }),
                  let cam = cameraNode else { return }
            let target = point(at: train.position, y: 2)
            let eye = point(at: train.position, y: 60, radialScale: 1.55)
            cam.position = eye
            cam.look(at: target)
            sceneView?.pointOfView = cam
        }

        // MARK: -- train nodes

        private func makeTrainNodes(for train: Train) -> TrainNodes {
            let root = SCNNode()
            scene.rootNode.addChildNode(root)

            let body = SCNNode(geometry: SCNBox(width: 6, height: 6, length: 20, chamferRadius: 0.8))
            body.geometry?.firstMaterial?.diffuse.contents = ScenePalette.trainMoving
            body.geometry?.firstMaterial?.emission.contents = ScenePalette.bodyGlow(ScenePalette.trainMoving)
            body.position = SCNVector3(0, 3, 0)
            root.addChildNode(body)

            let label = makeBillboardLabel(
                text: train.label, height: 9,
                color: ScenePalette.trainLabel)
            label.position = SCNVector3(0, 14, 0)
            root.addChildNode(label)

            // Passenger doors on the platform-facing (+x / outward) side: a
            // dark recessed doorway with two sliding leaves that part when the
            // doors open. Local +x is radially outward, toward the platform.
            let doorway = SCNNode(geometry: SCNBox(width: 0.2, height: 4.4, length: 7.4, chamferRadius: 0))
            doorway.geometry?.firstMaterial?.diffuse.contents = ScenePalette.doorway
            doorway.geometry?.firstMaterial?.lightingModel = .constant
            doorway.position = SCNVector3(3.05, 3, 0)
            body.addChildNode(doorway)

            let leaf = SCNBox(width: 0.5, height: 4.4, length: 3.5, chamferRadius: 0.1)
            leaf.firstMaterial?.diffuse.contents = ScenePalette.doorLeaf
            leaf.firstMaterial?.emission.contents = ScenePalette.doorLeafGlow
            let doorLeft = SCNNode(geometry: leaf)
            doorLeft.position = SCNVector3(3.25, 3, -1.8)
            body.addChildNode(doorLeft)
            let doorRight = SCNNode(geometry: leaf)
            doorRight.position = SCNVector3(3.25, 3, 1.8)
            body.addChildNode(doorRight)

            return TrainNodes(root: root, body: body, label: label,
                              doorLeft: doorLeft, doorRight: doorRight)
        }

        private func updateTrain(nodes: TrainNodes, train: Train) {
            let angle = train.position / Sim.trackLength * 2 * .pi
            let p = point(at: train.position)
            nodes.root.position = SCNVector3(p.x, 0, p.z)
            nodes.root.eulerAngles = SCNVector3(0, -angle, 0)

            let color: NSColor
            if train.isEmergencyBrakeApplied || train.status == .emergency {
                color = ScenePalette.trainAlarm
            } else if train.mode == .manual {
                color = ScenePalette.trainManual
            } else if train.status == .docked {
                color = ScenePalette.trainDocked
            } else if train.status == .moving {
                color = ScenePalette.trainMoving
            } else {
                color = ScenePalette.trainIdle
            }
            nodes.body.geometry?.firstMaterial?.diffuse.contents = color
            nodes.body.geometry?.firstMaterial?.emission.contents =
                ScenePalette.bodyGlow(color)

            // Slide the doors on an open/close edge.
            if train.doorsOpen != nodes.lastDoorsOpen {
                nodes.lastDoorsOpen = train.doorsOpen
                let z: CGFloat = train.doorsOpen ? 5.3 : 1.8
                nodes.doorLeft.runAction(.move(to: SCNVector3(3.25, 3, -z), duration: 0.6))
                nodes.doorRight.runAction(.move(to: SCNVector3(3.25, 3, z), duration: 0.6))
            }
            // Stream passengers between the platform and the open doors while
            // the rame is docked, biased by the stop's boarding / alighting mix.
            if train.doorsOpen && train.status == .docked {
                nodes.paxTick += 1
                if nodes.paxTick % 15 == 0 { emitPax(train: train) }
            } else {
                nodes.paxTick = 0
            }
        }

        /// Spawn one passenger dot for `train`: green boarding (platform →
        /// door) or cyan alighting (door → platform), chosen in proportion to
        /// the stop's montée / descente totals. The dot animates once and
        /// removes itself, so no bookkeeping is needed.
        private func emitPax(train: Train) {
            let board = max(0, train.paxBoarding)
            let alight = max(0, train.paxAlighting)
            let total = board + alight
            guard total > 0 else { return }
            let boarding = Double.random(in: 0..<1) < Double(board) / Double(total)

            let doorPos = point(at: train.position, y: 3, radialScale: (radius + 5) / radius)
            let platPos = point(at: train.position, y: 2.5, radialScale: 1.13)
            let start = boarding ? platPos : doorPos
            let end = boarding ? doorPos : platPos

            let dot = SCNNode(geometry: SCNSphere(radius: 0.55))
            let c = boarding ? ScenePalette.paxBoarding : ScenePalette.paxAlighting
            dot.geometry?.firstMaterial?.diffuse.contents = c
            dot.geometry?.firstMaterial?.emission.contents = ScenePalette.paxGlow(c)
            dot.geometry?.firstMaterial?.lightingModel = .constant
            dot.position = start
            scene.rootNode.addChildNode(dot)
            dot.runAction(.sequence([
                .move(to: end, duration: 0.8),
                .removeFromParentNode()
            ]))
        }

        // MARK: -- billboard text

        /// A camera-facing label rendered in the skin's monospace face onto a
        /// texture plane (crisper and far cheaper than extruded SCNText).
        /// Measured and drawn from the same CTLine: NSStringDrawing can lay
        /// a line out slightly wider at draw time than `size()` reported
        /// (font-cascade resolution differs per process), which truncated
        /// the last glyph of accented station names. One CTLine cannot
        /// disagree with itself.
        private func makeBillboardLabel(text: String, height: CGFloat, color: NSColor) -> SCNNode {
            let fontSize: CGFloat = 64
            let font = ScenePalette.labelFont(size: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(str)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let pad: CGFloat = 12       // absorbs glyph side-bearing overhang
            let imgW = ceil(advance) + pad * 2
            let imgH = ceil(ascent + descent) + 8

            // Rasterize at 2x into an explicit bitmap and hand SceneKit the
            // raw CGImage: routing the NSImage itself into the material let
            // SceneKit's image conversion truncate the right edge of wide
            // NPOT label textures at close camera range.
            let scale: CGFloat = 2
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(imgW * scale), pixelsHigh: Int(imgH * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            let gctx = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            let ctx = gctx.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: pad, y: 4 + descent)
            CTLineDraw(line, ctx)
            NSGraphicsContext.restoreGraphicsState()

            let aspect = imgW / imgH
            let plane = SCNPlane(width: height * aspect, height: height)
            plane.firstMaterial?.diffuse.contents = rep.cgImage
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            // Labels are overlay text: without this, the quad's transparent
            // margin still writes depth, and wherever two billboards overlap
            // at a grazing camera angle the farther-sorted one punches a
            // straight-edged hole through the nearer one's glyphs.
            plane.firstMaterial?.writesToDepthBuffer = false

            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            return node
        }
    }
}
