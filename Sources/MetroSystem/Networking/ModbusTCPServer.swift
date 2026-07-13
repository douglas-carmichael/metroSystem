import Foundation
import Network

/// Modbus TCP server on `127.0.0.1:5020` that exposes rame state at
/// standard register addresses so any PLC HMI, SCADA front-end, or
/// industrial-automation toolchain (OpenPLC, Node-RED, pymodbus, mbpoll,
/// QModMaster, ...) can read train telemetry and drive rames over the wire
/// the same way it would talk to a real wayside gateway.
///
/// Port 502 is the Modbus-TCP IANA-registered port, but Unix systems
/// require root to bind below 1024 -- we use 5020, the canonical
/// non-privileged alternative every industrial-automation tool
/// supports via `-p 5020`.
///
/// Register map (16 rames supported, 0-indexed Modbus addresses). Rame
/// indices follow the PCC panel's sort order (by label). Control writes
/// (door coils, FU coils, mode/speed registers) work on BOTH local and
/// remote rames: a write against a peer-owned rame is forwarded to its
/// owning node over the peer link, exactly like the on-screen buttons.
/// DI 0..15 report which rames are locally owned.
///
///   Coils (single-bit, R/W) -- FC 01 read, FC 05 write (pulse-on):
///     0..15    Rame[0..15]  Door OPEN command
///     16..31   Rame[0..15]  Door CLOSE command
///     32..47   Rame[0..15]  FU SET   (command the emergency brake)
///     48..63   Rame[0..15]  FU RELEASE (honoured at a stand)
///     64..79   Rame[0..15]  KACOP acknowledge (dead-man, VAL manual)
///     80..95   Rame[0..15]  Pupitre KG ON  (console A22 master power)
///     96..111  Rame[0..15]  Pupitre KG OFF
///
///   Discrete inputs (single-bit, RO) -- FC 02:
///     0..15    Rame[0..15]  is locally owned
///     16..31   Rame[0..15]  is moving (speed > 0.05 m/s)
///     32..47   Rame[0..15]  doors open
///     48..63   Rame[0..15]  FU applied
///     64..79   Rame[0..15]  door fault latched
///     80..95   Rame[0..15]  traction fault latched
///     96..111  Rame[0..15]  brake fault latched
///     112..127 Rame[0..15]  CTC radio fault latched
///     128..143 Rame[0..15]  patinage (wheel slip) latched
///     144..159 Rame[0..15]  enrayage (wheel slide) latched
///   -- Chaîne de sécurité (safety chain), 1 = contact closed / healthy.
///      Derived from rame telemetry, so faithful for remote rames too:
///     160..175 Rame[0..15]  door interlock proven
///     176..191 Rame[0..15]  overspeed governor OK
///     192..207 Rame[0..15]  MA margin OK (not encroached)
///     208..223 Rame[0..15]  service brake OK
///     224..239 Rame[0..15]  adhesion OK (no burst tire)
///     240..255 Rame[0..15]  safety chain intact (series loop, incl. line mode)
///     256..271 Rame[0..15]  KACOP vigilance warning (VAL manual driving)
///     272..287 Rame[0..15]  perturbed stopping program (PP) selected
///
///   Holding registers (16-bit, R/W) -- FC 03 read, FC 06 write:
///     0..15    Rame[0..15]  Mode  (read/write: 0 = Manual, 1 = Auto)
///     16..31   Rame[0..15]  Manual CML speed ceiling x10  (m/s x10, 0..200)
///     32..47   Rame[0..15]  Pupitre T/F lever, signed Int16 percent
///                           (-100 full brake .. +100 full traction)
///     48..63   Rame[0..15]  Pupitre reverser (0=neutral, 1=AV, 2=AR)
///
///   Input registers (16-bit, RO) -- FC 04:
///     0..15    Rame[0..15]  Position x10 (metres; 123.4 m = 1234)
///     16..31   Rame[0..15]  Speed x100, signed Int16 (+fwd / -rev)
///     32..47   Rame[0..15]  Consigne (speed setpoint) x100
///     48..63   Rame[0..15]  Movement-authority distance x10 (m)
///     64..79   Rame[0..15]  Passenger count
///     80..95   Rame[0..15]  Status (0=stopped, 1=moving, 2=FU, 3=docked)
///     96..111  Rame[0..15]  Canton number (1..10)
///     112..127 Rame[0..15]  Worst tire (0=OK, 1=low, 2=puncture, 3=burst)
///     128..143 Rame[0..15]  VAL speed program (0=SF-N, 1=PP, 2=SFA,
///                           3=SFB, 4=HOLD, 5=ASMD, 6=ABSENT;
///                           0xFFFF = not VAL-driven)
///     144..159 Rame[0..15]  KACOP seconds since acknowledge x10
///   -- Traction-chain bench block (VAL backend; zero otherwise):
///     160..175 Rame[0..15]  Armature current II (A, per-car loop)
///     176..191 Rame[0..15]  Line current IL, signed Int16 (A;
///                           negative = regenerating into the line)
///     192..207 Rame[0..15]  Field current IEX x10 (A per motor)
///     208..223 Rame[0..15]  Chopper duty MHI x1000 (0..1000)
///     1000    Number of rames known (local + remote)
///     1001    Number of remote peers connected
///     1002    Canton count
///     1003    Number of telnet sessions
///     1004    Number of Modbus clients connected
///     1005    Line mode (0=stopped, 1=normal, 2=service provisoire, 3=emergency)
///     1006    SP start station id (0 = none)
///     1007    SP end station id (0 = none)
///     1008    SP headway (seconds)
///     1009    Active SCADA alarm count (excludes shelved)
///     1010    Highest active severity (0=none, 1=Advisory ... 4=Critical)
///     1011    Unacknowledged alarm count (ISA-18.2 UNACK)
///     1012    Shelved alarm count       (ISA-18.2 SHLVD)
///     1013    Returned-to-normal, unacknowledged count (ISA-18.2 RTN)
///     1014    Track length (metres)
///
/// Function codes accepted: FC 01/02/03/04/05/06/0F/10. Anything else
/// returns exception 0x01 (illegal function). The unit-id (slave address)
/// field is accepted regardless of value and echoed back, matching how a
/// directly-connected Modbus-TCP slave behaves -- the device is addressed
/// by IP, so masters that default to unit-id 1, 128, or 255 all work.
@MainActor
final class ModbusTCPServer: ObservableObject {
    @Published private(set) var port: UInt16?
    /// Number of live Modbus socket connections right now. Reported on the
    /// wire (input register 1004).
    @Published private(set) var clientCount: Int = 0
    /// Client count for the MODBUS status indicator in the PCC strip.
    /// Tracks `clientCount`, but holds its last non-zero value for
    /// `indicatorLinger` seconds after the live count drops to zero, so a
    /// client that opens a fresh connection every poll (connect/read/close
    /// each cycle, e.g. Modbus Poll) reads as steadily connected instead of
    /// strobing 1/0/1/0.
    @Published private(set) var displayedClientCount: Int = 0

    private weak var world: MetroWorld?
    private weak var network: PeerNetwork?
    private weak var telnet: DCLTelnetServer?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.dcarmichael.metro.modbus")
    private var lingerTask: Task<Void, Never>?
    private var clients: [ObjectIdentifier: ModbusClient] = [:] {
        didSet {
            clientCount = clients.count
            if clients.isEmpty {
                armIndicatorLinger()
            } else {
                lingerTask?.cancel()
                lingerTask = nil
                displayedClientCount = clients.count
            }
        }
    }

    static let defaultPort: UInt16 = 5020
    static let maxTrains: Int = 16
    /// Number of per-rame input-register fields (position, speed, consigne,
    /// MA, pax, status, canton, worst tire, VAL speed program, KACOP
    /// timer, and the traction-chain bench block II/IL/IEX/MHI). The
    /// rame-indexed IR block therefore spans
    /// `0 ..< irTrainFieldCount * maxTrains`; the line-wide scalar
    /// registers live above it at `scalarBase`.
    static let irTrainFieldCount: Int = 14
    /// First address of the line-wide scalar input registers. Placed at a
    /// round 1000, well clear of the rame-indexed block
    /// (`irTrainFieldCount * maxTrains = 224`).
    static let scalarBase: Int = 1000
    /// How long the MODBUS status indicator holds "connected" after the last
    /// live socket closes.
    static let indicatorLinger: TimeInterval = 3.0

    init() {}

    func attach(world: MetroWorld, network: PeerNetwork, telnet: DCLTelnetServer) {
        self.world = world
        self.network = network
        self.telnet = telnet
    }

    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("ModbusTCPServer: failed to bind to port \(Self.defaultPort): \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                if case .ready = state {
                    self.port = Self.defaultPort
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in self.handleNewConnection(conn) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lingerTask?.cancel()
        lingerTask = nil
        for (_, client) in clients { client.cancel() }
        clients.removeAll()
        displayedClientCount = 0
        port = nil
    }

    /// Clear the status indicator `indicatorLinger` seconds from now, unless
    /// a new connection arrives first (which cancels this task via the
    /// `clients` didSet). Keeps a per-poll client from strobing the display.
    private func armIndicatorLinger() {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor [weak self] in
            let ns = UInt64(ModbusTCPServer.indicatorLinger * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            if self.clients.isEmpty { self.displayedClientCount = 0 }
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        guard let world, let network else {
            conn.cancel()
            return
        }
        let client = ModbusClient(connection: conn,
                                  world: world,
                                  network: network,
                                  telnet: telnet,
                                  modbusServer: self,
                                  queue: queue)
        client.onClose = { [weak self, weak client] in
            guard let self, let client else { return }
            Task { @MainActor in
                self.clients.removeValue(forKey: ObjectIdentifier(client))
            }
        }
        clients[ObjectIdentifier(client)] = client
        client.start()
    }
}

/// One Modbus-TCP client connection. Parses MBAP-framed PDUs, dispatches
/// supported function codes (FC 01/02/03/04/05/06/0F/10), and answers with
/// either the response PDU or a Modbus exception (function code OR'd
/// with 0x80 + 1-byte exception code).
@MainActor
final class ModbusClient {
    private let connection: NWConnection
    private weak var world: MetroWorld?
    private weak var network: PeerNetwork?
    private weak var telnet: DCLTelnetServer?
    private weak var modbusServer: ModbusTCPServer?
    private let queue: DispatchQueue
    private var inboundBuffer: Data = Data()
    private var closed = false

    var onClose: (() -> Void)?

    init(connection: NWConnection,
         world: MetroWorld,
         network: PeerNetwork,
         telnet: DCLTelnetServer?,
         modbusServer: ModbusTCPServer,
         queue: DispatchQueue) {
        self.connection = connection
        self.world = world
        self.network = network
        self.telnet = telnet
        self.modbusServer = modbusServer
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.receiveLoop() }
            case .failed, .cancelled:
                Task { @MainActor in self.fireClose() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: -- Receive loop / framing

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.inboundBuffer.append(data)
                    self.drainFrames()
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self.fireClose() }
                return
            }
            Task { @MainActor in self.receiveLoop() }
        }
    }

    /// MBAP header is 7 bytes; the `Length` field at offset 4-5 covers
    /// everything after the length field (Unit ID + PDU).
    ///
    /// `Data.removeFirst(_:)` advances the buffer's `startIndex` rather
    /// than physically dropping bytes, so all reads here are anchored to
    /// the current `startIndex`. `subdata(in:)` returns a fresh `Data`
    /// (startIndex 0) so `handleFrame` can use absolute offsets safely.
    private func drainFrames() {
        while inboundBuffer.count >= 7 {
            let base = inboundBuffer.startIndex
            let length = (UInt16(inboundBuffer[base + 4]) << 8)
                       | UInt16(inboundBuffer[base + 5])
            let totalSize = 6 + Int(length)
            guard inboundBuffer.count >= totalSize else { return }
            let frame = inboundBuffer.subdata(in: base..<(base + totalSize))
            inboundBuffer.removeFirst(totalSize)
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: Data) {
        guard frame.count >= 8 else { return }
        let txnId = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        let unitId = frame[6]
        let fc = frame[7]
        let pdu = frame.subdata(in: 8..<frame.count)

        // Unit-id (slave-address) is vestigial on Modbus TCP: the device
        // is addressed by IP, so a directly-connected TCP slave answers
        // regardless of the unit-id field. We accept any value and echo it
        // back in the response.

        let response: Data
        switch fc {
        case 0x01: response = handleReadCoils(pdu)
        case 0x02: response = handleReadDiscreteInputs(pdu)
        case 0x03: response = handleReadHoldingRegisters(pdu)
        case 0x04: response = handleReadInputRegisters(pdu)
        case 0x05: response = handleWriteSingleCoil(pdu)
        case 0x06: response = handleWriteSingleRegister(pdu)
        case 0x0F: response = handleWriteMultipleCoils(pdu)
        case 0x10: response = handleWriteMultipleRegisters(pdu)
        default:
            response = Data([fc | 0x80, 0x01])      // illegal function
        }
        sendResponse(txnId: txnId, unitId: unitId, pdu: response)
    }

    private func sendResponse(txnId: UInt16, unitId: UInt8, pdu: Data) {
        var out = Data()
        out.append(UInt8(txnId >> 8))
        out.append(UInt8(txnId & 0xFF))
        out.append(0x00); out.append(0x00)          // protocol id = 0
        let length = UInt16(1 + pdu.count)
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out.append(unitId)
        out.append(pdu)
        connection.send(content: out, completion: .contentProcessed { _ in })
    }

    private func fireClose() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    // MARK: -- Function-code handlers

    private func handleReadCoils(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x81, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 2000 else { return Data([0x81, 0x03]) }
        let byteCount = (Int(count) + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<Int(count) {
            if readCoil(at: start &+ UInt16(i)) {
                bits[i / 8] |= UInt8(1 << (i % 8))
            }
        }
        var out = Data([0x01, UInt8(byteCount)])
        out.append(contentsOf: bits)
        return out
    }

    private func handleReadDiscreteInputs(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x82, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 2000 else { return Data([0x82, 0x03]) }
        let byteCount = (Int(count) + 7) / 8
        var bits = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<Int(count) {
            if readDiscreteInput(at: start &+ UInt16(i)) {
                bits[i / 8] |= UInt8(1 << (i % 8))
            }
        }
        var out = Data([0x02, UInt8(byteCount)])
        out.append(contentsOf: bits)
        return out
    }

    private func handleReadHoldingRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x83, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 125 else { return Data([0x83, 0x03]) }
        var out = Data([0x03, UInt8(count * 2)])
        for i in 0..<Int(count) {
            let v = readHoldingRegister(at: start &+ UInt16(i))
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private func handleReadInputRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x84, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        guard count >= 1, count <= 125 else { return Data([0x84, 0x03]) }
        var out = Data([0x04, UInt8(count * 2)])
        for i in 0..<Int(count) {
            let v = readInputRegister(at: start &+ UInt16(i))
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private func handleWriteSingleCoil(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x85, 0x03]) }
        let addr = u16(pdu, 0)
        let value = u16(pdu, 2)
        guard value == 0x0000 || value == 0xFF00 else {
            return Data([0x85, 0x03])
        }
        writeCoil(at: addr, on: value == 0xFF00)
        return Data([0x05]) + pdu                   // echo: FC + addr + value
    }

    private func handleWriteSingleRegister(_ pdu: Data) -> Data {
        guard pdu.count >= 4 else { return Data([0x86, 0x03]) }
        let addr = u16(pdu, 0)
        let value = u16(pdu, 2)
        writeHoldingRegister(at: addr, value: value)
        return Data([0x06]) + pdu                   // echo: FC + addr + value
    }

    /// FC 0x0F -- Write Multiple Coils. Lets a PLC stage several commands
    /// (e.g. FU on every rame) in one transaction. Response echoes the
    /// starting address and the coil count, per spec §6.11.
    private func handleWriteMultipleCoils(_ pdu: Data) -> Data {
        guard pdu.count >= 5 else { return Data([0x8F, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        let byteCount = Int(pdu[pdu.startIndex + 4])
        guard count >= 1, count <= 1968,
              byteCount == (Int(count) + 7) / 8,
              pdu.count >= 5 + byteCount
        else { return Data([0x8F, 0x03]) }
        for i in 0..<Int(count) {
            let byte = pdu[pdu.startIndex + 5 + i / 8]
            let bit = (byte >> UInt8(i % 8)) & 0x01
            writeCoil(at: start &+ UInt16(i), on: bit == 1)
        }
        var out = Data([0x0F])
        out.append(UInt8(start >> 8))
        out.append(UInt8(start & 0xFF))
        out.append(UInt8(count >> 8))
        out.append(UInt8(count & 0xFF))
        return out
    }

    /// FC 0x10 -- Write Multiple Registers: load N consecutive holding
    /// registers in a single request (e.g. push every rame's manual speed
    /// setpoint at once). Response echoes the starting address and register
    /// count, per spec §6.12.
    private func handleWriteMultipleRegisters(_ pdu: Data) -> Data {
        guard pdu.count >= 5 else { return Data([0x90, 0x03]) }
        let start = u16(pdu, 0)
        let count = u16(pdu, 2)
        let byteCount = Int(pdu[pdu.startIndex + 4])
        guard count >= 1, count <= 123,
              byteCount == Int(count) * 2,
              pdu.count >= 5 + byteCount
        else { return Data([0x90, 0x03]) }
        for i in 0..<Int(count) {
            let value = u16(pdu, 5 + i * 2)
            writeHoldingRegister(at: start &+ UInt16(i), value: value)
        }
        var out = Data([0x10])
        out.append(UInt8(start >> 8))
        out.append(UInt8(start & 0xFF))
        out.append(UInt8(count >> 8))
        out.append(UInt8(count & 0xFF))
        return out
    }

    // MARK: -- Register accessors

    private func train(at index: Int) -> Train? {
        guard let trains = world?.sortedTrains, index < trains.count else { return nil }
        return trains[index]
    }

    private func readCoil(at address: UInt16) -> Bool {
        let group = Int(address) / ModbusTCPServer.maxTrains
        let idx = Int(address) % ModbusTCPServer.maxTrains
        guard let t = train(at: idx) else { return false }
        switch group {
        case 0: return t.doorsOpen                          // door OPEN state
        case 1: return !t.doorsOpen                         // door CLOSE state
        case 2: return t.isEmergencyBrakeApplied            // FU SET latched
        case 3: return !t.isEmergencyBrakeApplied           // FU released
        case 4: return t.kacopWarning                       // KACOP ack pending
        case 5: return t.pupitreKG                          // KG state
        default:
            return false
        }
    }

    private func writeCoil(at address: UInt16, on: Bool) {
        guard on else { return }                    // pulse-on commands only
        let group = Int(address) / ModbusTCPServer.maxTrains
        let idx = Int(address) % ModbusTCPServer.maxTrains
        guard let t = train(at: idx) else { return }
        // Route through PeerNetwork.control so a coil written against a
        // remote-owned rame is forwarded to its owning node (identical to
        // the PCC buttons); local rames are mutated in place.
        switch group {
        case 0: _ = network?.control(t, .openDoors)
        case 1: _ = network?.control(t, .closeDoors)
        case 2: _ = network?.control(t, .fuSet)
        case 3: _ = network?.control(t, .fuRelease)
        case 4: _ = network?.control(t, .kacopAck)          // KACOP ack pulse
        case 5: _ = network?.control(t, .pupitreKG, value: 1)   // KG on
        case 6: _ = network?.control(t, .pupitreKG, value: 0)   // KG off
        default:
            break
        }
    }

    private func readDiscreteInput(at address: UInt16) -> Bool {
        let group = Int(address) / ModbusTCPServer.maxTrains
        let idx = Int(address) % ModbusTCPServer.maxTrains
        guard let t = train(at: idx) else { return false }
        switch group {
        case 0: return world?.canControl(t) ?? false
        case 1: return t.speed > 0.05
        case 2: return t.doorsOpen
        case 3: return t.isEmergencyBrakeApplied
        case 4: return t.isDoorFault
        case 5: return t.isEngineFault
        case 6: return t.isBrakeFault
        case 7: return t.isSignalFault
        case 8: return t.isPatinage
        case 9: return t.isEnrayage
        case 10...15:
            // Chaîne de sécurité contacts (1 = closed / healthy), derived
            // from rame telemetry so they are faithful for remote rames too.
            guard let chain = world?.safetyChain(for: t) else { return false }
            switch group {
            case 10: return chain.doorInterlock
            case 11: return chain.overspeedOK
            case 12: return chain.maMarginOK
            case 13: return chain.brakeOK
            case 14: return chain.adhesionOK
            default: return chain.intact          // group 15
            }
        case 16: return t.kacopWarning                      // vigilance overdue
        case 17: return t.speedProgram == VALSpeedProgram.perturbed.rawValue
        default: return false
        }
    }

    private func readHoldingRegister(at address: UInt16) -> UInt16 {
        let group = Int(address) / ModbusTCPServer.maxTrains
        let idx = Int(address) % ModbusTCPServer.maxTrains
        guard let t = train(at: idx) else { return 0 }
        switch group {
        case 0: return t.mode == .auto ? 1 : 0
        case 1: return UInt16(max(0, min(200, Int(t.manualSpeedRequest * 10.0))))
        case 2:                                     // pupitre lever % signed
            let pct = Int(t.pupitreLever * 100.0)
            return UInt16(bitPattern: Int16(max(-100, min(100, pct))))
        case 3:                                     // reverser 0=neutral 1=AV 2=AR
            return t.pupitreReverser > 0 ? 1 : (t.pupitreReverser < 0 ? 2 : 0)
        default: return 0
        }
    }

    private func writeHoldingRegister(at address: UInt16, value: UInt16) {
        let group = Int(address) / ModbusTCPServer.maxTrains
        let idx = Int(address) % ModbusTCPServer.maxTrains
        guard let t = train(at: idx) else { return }
        switch group {
        case 0:                                     // mode
            _ = network?.control(t, value == 0 ? .modeManual : .modeAuto)
        case 1:                                     // manual speed x10
            let speed = Double(min(value, 200)) / 10.0
            _ = network?.control(t, .setSpeed, value: speed)
        case 2:                                     // pupitre lever % signed
            let pct = Double(Int16(bitPattern: value))
            _ = network?.control(t, .pupitreLever, value: max(-100, min(100, pct)) / 100.0)
        case 3:                                     // reverser 0=neutral 1=AV 2=AR
            let rev: Double = value == 1 ? 1 : (value == 2 ? -1 : 0)
            _ = network?.control(t, .pupitreReverser, value: rev)
        default:
            break
        }
    }

    private func readInputRegister(at address: UInt16) -> UInt16 {
        if Int(address) < ModbusTCPServer.irTrainFieldCount * ModbusTCPServer.maxTrains {
            let group = Int(address) / ModbusTCPServer.maxTrains
            let idx = Int(address) % ModbusTCPServer.maxTrains
            guard let t = train(at: idx) else { return 0 }
            switch group {
            case 0:                                 // position x10 (m)
                return UInt16(max(0, min(0xFFFF, Int(t.position * 10.0))))
            case 1:                                 // speed x100 signed (+fwd/-rev)
                let v = Int(t.signedSpeed * 100.0)
                let clamped = max(-32768, min(32767, v))
                return UInt16(bitPattern: Int16(clamped))
            case 2:                                 // consigne x100
                return UInt16(max(0, min(0xFFFF, Int(t.consigneVitesse * 100.0))))
            case 3:                                 // MA distance x10
                return UInt16(max(0, min(0xFFFF, Int(t.distanceToMA * 10.0))))
            case 4:                                 // passengers
                return UInt16(max(0, min(0xFFFF, t.passengerCount)))
            case 5:                                 // status
                switch t.status {
                case .stopped:   return 0
                case .moving:    return 1
                case .emergency: return 2
                case .docked:    return 3
                }
            case 6:                                 // canton number
                return UInt16(world?.canton(at: t.position)?.id ?? 0)
            case 7:                                 // worst tire
                switch t.worstTire {
                case .ok:          return 0
                case .lowPressure: return 1
                case .puncture:    return 2
                case .burst:       return 3
                }
            case 8:                                 // VAL speed program
                switch VALSpeedProgram(rawValue: t.speedProgram) {
                case .normal:           return 0
                case .perturbed:        return 1
                case .stationArrival:   return 2
                case .stationDeparture: return 3
                case .departureHeld:    return 4
                case .pushRecovery:     return 5
                case .absent:           return 6
                case nil:               return 0xFFFF   // not VAL-driven
                }
            case 9:                                 // KACOP timer x10 (s)
                return UInt16(max(0, min(0xFFFF, Int(t.kacopSecondsSinceAck * 10.0))))
            case 10:                                // armature current II (A)
                return UInt16(max(0, min(0xFFFF, Int(t.armatureCurrent))))
            case 11:                                // line current IL, signed (A)
                let il = max(-32768, min(32767, Int(t.lineCurrent)))
                return UInt16(bitPattern: Int16(il))
            case 12:                                // field current IEX x10 (A)
                return UInt16(max(0, min(0xFFFF, Int(t.excitationCurrent * 10.0))))
            case 13:                                // chopper duty MHI x1000
                return UInt16(max(0, min(1000, Int(t.modulationRatio * 1000.0))))
            default:
                return 0
            }
        }
        // Line-wide scalar registers, offset from `scalarBase` (1000).
        switch Int(address) - ModbusTCPServer.scalarBase {
        case 0: return UInt16(world?.trains.count ?? 0)
        case 1: return UInt16(network?.peers.count ?? 0)
        case 2: return UInt16(Sim.cantonCount)
        case 3: return UInt16(telnet?.sessionCount ?? 0)
        case 4: return UInt16(modbusServer?.clientCount ?? 0)
        case 5:                                     // line mode
            switch world?.lineMode {
            case .stopped:           return 0
            case .normal:            return 1
            case .serviceProvisoire: return 2
            case .emergency:         return 3
            case nil:                return 0
            }
        case 6: return UInt16(world?.activeSP?.startStationId ?? 0)
        case 7: return UInt16(world?.activeSP?.endStationId ?? 0)
        case 8: return UInt16(world?.activeSP.map { Int($0.intervalle) } ?? 0)
        case 9:                                     // active alarm count
            return UInt16(min(0xFFFF, world?.activeAlarms.count ?? 0))
        case 10:                                    // highest active severity
            guard let s = world?.highestActiveSeverity else { return 0 }
            return UInt16(s.rawValue + 1)
        case 11:                                    // unacknowledged alarms
            return UInt16(min(0xFFFF, world?.unacknowledgedAlarmCount ?? 0))
        case 12:                                    // shelved alarms (ISA-18.2)
            return UInt16(min(0xFFFF, world?.shelvedAlarms.count ?? 0))
        case 13:                                    // returned-to-normal, unacked
            return UInt16(min(0xFFFF, world?.returnedToNormalUnackedCount ?? 0))
        case 14: return UInt16(Int(Sim.trackLength))
        default:  return 0
        }
    }

    // MARK: -- Helpers

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        return (UInt16(data[data.startIndex + offset]) << 8)
             | UInt16(data[data.startIndex + offset + 1])
    }
}
