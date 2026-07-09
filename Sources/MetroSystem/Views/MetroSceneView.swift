import SwiftUI
import SceneKit
import AppKit
import Combine

/// The 3D line synoptic: a SceneKit view of the circular VAL line with
/// every canton, station and rame, framed by a VT320-style HUD. The
/// scene reconciles its nodes against `MetroWorld` on every world tick
/// (the same coordinator pattern as the DCL windows: SwiftUI owns the
/// chrome, the Coordinator owns the SceneKit graph).
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
        .background(Color.black)
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
        view.backgroundColor = .black
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

        struct TrainNodes {
            let root: SCNNode
            let body: SCNNode
            let label: SCNNode
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
            scene.background.contents = NSColor.black

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
            ambient.light?.color = NSColor(white: 0.35, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.color = NSColor(deviceRed: 1.0, green: 0.85, blue: 0.5, alpha: 1)
            key.light?.intensity = 1400
            key.position = SCNVector3(0, 400, 0)
            scene.rootNode.addChildNode(key)

            // Phosphor-grid floor: a dark plane with a faint emissive grid
            // reads like a vector display rather than a daylight scene.
            let floor = SCNFloor()
            floor.reflectivity = 0.05
            floor.firstMaterial?.diffuse.contents = NSColor(white: 0.03, alpha: 1)
            floor.firstMaterial?.lightingModel = .constant
            let floorNode = SCNNode(geometry: floor)
            floorNode.position = SCNVector3(0, -1.5, 0)
            scene.rootNode.addChildNode(floorNode)

            // PCC marker at the centre of the loop.
            let hub = SCNBox(width: 12, height: 6, length: 12, chamferRadius: 0.5)
            hub.firstMaterial?.diffuse.contents = NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
            hub.firstMaterial?.emission.contents = NSColor(deviceRed: 0.5, green: 0.33, blue: 0.06, alpha: 1)
            let hubNode = SCNNode(geometry: hub)
            hubNode.position = SCNVector3(0, 3, 0)
            scene.rootNode.addChildNode(hubNode)
            let hubLabel = makeBillboardLabel(text: "PCC", height: 10,
                                              color: NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1))
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
                marker.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.85, alpha: 1)
                marker.geometry?.firstMaterial?.emission.contents = NSColor(white: 0.35, alpha: 1)
                marker.position = point(at: canton.startPosition)
                scene.rootNode.addChildNode(marker)

                let numLabel = makeBillboardLabel(
                    text: String(format: cantonShort, canton.id), height: 6,
                    color: NSColor(deviceRed: 0.62, green: 0.45, blue: 0.12, alpha: 1))
                numLabel.position = point(at: canton.startPosition + canton.length / 2,
                                          y: 3, radialScale: 0.92)
                scene.rootNode.addChildNode(numLabel)
            }
        }

        private func drawStations() {
            for station in world.stations {
                let platform = SCNBox(width: 10, height: 2, length: 24, chamferRadius: 0)
                platform.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
                platform.firstMaterial?.emission.contents = NSColor(deviceRed: 0.10, green: 0.07, blue: 0.02, alpha: 1)
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
                    color: NSColor(deviceRed: 0.45, green: 0.95, blue: 1.0, alpha: 1))
                label.position = point(at: station.position, y: 12, radialScale: 1.16)
                scene.rootNode.addChildNode(label)
            }
        }

        private func buildLine(from: SCNVector3, to: SCNVector3, radius: CGFloat) -> SCNNode {
            let vector = SCNVector3(to.x - from.x, to.y - from.y, to.z - from.z)
            let distance = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
            let mid = SCNVector3((from.x + to.x) / 2, (from.y + to.y) / 2, (from.z + to.z) / 2)

            let geometry = SCNCylinder(radius: radius, height: CGFloat(distance))
            geometry.firstMaterial?.diffuse.contents = Self.trackColor
            geometry.firstMaterial?.emission.contents = Self.trackGlow

            let node = SCNNode(geometry: geometry)
            node.position = mid
            node.look(at: to, up: scene.rootNode.worldUp, localFront: node.worldUp)
            return node
        }

        private static let trackColor = NSColor(deviceRed: 0.55, green: 0.42, blue: 0.15, alpha: 1)
        private static let trackGlow  = NSColor(deviceRed: 0.28, green: 0.20, blue: 0.05, alpha: 1)
        private static let trackBarred = NSColor(white: 0.14, alpha: 1)
        private static let trackBarredGlow = NSColor(white: 0.02, alpha: 1)

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
                    node.geometry?.firstMaterial?.diffuse.contents = barred ? Self.trackBarred : Self.trackColor
                    node.geometry?.firstMaterial?.emission.contents = barred ? Self.trackBarredGlow : Self.trackGlow
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
            body.geometry?.firstMaterial?.diffuse.contents = NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)
            body.geometry?.firstMaterial?.emission.contents = NSColor(deviceRed: 0.10, green: 0.4, blue: 0.12, alpha: 1)
            body.position = SCNVector3(0, 3, 0)
            root.addChildNode(body)

            let label = makeBillboardLabel(
                text: train.label, height: 9,
                color: NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1))
            label.position = SCNVector3(0, 14, 0)
            root.addChildNode(label)

            return TrainNodes(root: root, body: body, label: label)
        }

        private func updateTrain(nodes: TrainNodes, train: Train) {
            let angle = train.position / Sim.trackLength * 2 * .pi
            let p = point(at: train.position)
            nodes.root.position = SCNVector3(p.x, 0, p.z)
            nodes.root.eulerAngles = SCNVector3(0, -angle, 0)

            let color: NSColor
            if train.isEmergencyBrakeApplied || train.status == .emergency {
                color = NSColor(deviceRed: 1.0, green: 0.30, blue: 0.28, alpha: 1)
            } else if train.mode == .manual {
                color = NSColor(deviceRed: 0.45, green: 0.95, blue: 1.0, alpha: 1)
            } else if train.status == .docked {
                color = NSColor(deviceRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
            } else if train.status == .moving {
                color = NSColor(deviceRed: 0.36, green: 1.0, blue: 0.42, alpha: 1)
            } else {
                color = NSColor(deviceRed: 0.62, green: 0.45, blue: 0.12, alpha: 1)
            }
            nodes.body.geometry?.firstMaterial?.diffuse.contents = color
            nodes.body.geometry?.firstMaterial?.emission.contents =
                color.withAlphaComponent(0.45)
        }

        // MARK: -- billboard text

        /// A camera-facing label rendered in the bundled VT323 face onto a
        /// texture plane (crisper and far cheaper than extruded SCNText).
        private func makeBillboardLabel(text: String, height: CGFloat, color: NSColor) -> SCNNode {
            let fontSize: CGFloat = 64
            let font = NSFont(name: RetroTheme.retroFontName, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let imgW = ceil(size.width) + 16
            let imgH = ceil(size.height) + 8

            let img = NSImage(size: NSSize(width: imgW, height: imgH))
            img.lockFocus()
            NSColor.clear.set()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: imgW, height: imgH))
            str.draw(at: NSPoint(x: 8, y: 4))
            img.unlockFocus()

            let aspect = imgW / imgH
            let plane = SCNPlane(width: height * aspect, height: height)
            plane.firstMaterial?.diffuse.contents = img
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true

            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            return node
        }
    }
}
