import Foundation
import Dispatch
import Darwin

// metro-clusterd -- headless cluster-peer daemon for MetroSystem.
//
// Publishes one or more OpenVMS-style PCC "nodes" on the LAN over
// Bonjour/Network.framework; each node owns a fleet of auto-driven rames
// that the MetroSystem app discovers and shows as remote trains on the
// same circular line. Running it alongside the app on one machine
// demonstrates the multi-node CBTC networking without a second box.

// Line-buffer stdout so log lines appear promptly even when piped to a
// file or a pager.
setvbuf(stdout, nil, _IOLBF, 0)

// Hidden `--selftest`: exercise the wire codec round-trip (mirrors the
// app's SELFTEST ethos) and exit non-zero on any failure. Locks wire
// compatibility of the mirrored Train model -- the app decodes these bytes.
if CommandLine.arguments.contains("--selftest") {
    func wireSelfTest() -> Bool {
        var train = Train(id: UUID(), label: "201", ownerPeerId: "PEER-1", position: 123.4)
        train.speed = 7.5
        train.mode = .manual
        train.tires[3].status = .puncture
        guard let sBytes = WireCodec.encode(.state(train)),
              let sMsg = WireCodec.decode(Data(sBytes.dropLast())),   // drop the newline frame byte
              let rt = sMsg.train, rt.id == train.id, rt.label == "201",
              rt.mode == .manual, abs(rt.speed - 7.5) < 0.001,
              rt.tires[3].status == .puncture else { return false }
        let snap = HostSnapshot(cpuBusy: 12.5, memUsedPercent: 40, bufferedIORate: 100,
                                directIORate: 50, lockRate: 200, processCount: 210, sampledAt: Date())
        guard let stBytes = WireCodec.encode(.stats(peerId: "PEER-1", snapshot: snap)),
              let stMsg = WireCodec.decode(Data(stBytes.dropLast())),
              let rs = stMsg.snapshot, abs(rs.cpuBusy - 12.5) < 0.001,
              rs.processCount == 210 else { return false }
        let cmd = TrainCommand(trainId: train.id, kind: .setSpeed, value: 8.0, originPeerId: "PEER-2")
        guard let cBytes = WireCodec.encode(.command(cmd)),
              let cMsg = WireCodec.decode(Data(cBytes.dropLast())),
              cMsg.op == .command, let rc = cMsg.command,
              rc.trainId == train.id, rc.kind == .setSpeed,
              abs((rc.value ?? 0) - 8.0) < 0.001 else { return false }
        return true
    }
    let wireOK = wireSelfTest()
    print("peer wire self-test:  \(wireOK ? "PASS" : "FAIL")")
    exit(wireOK ? 0 : 1)
}

// MARK: -- options

struct Options {
    var nodeCount = 1
    var trainsPerNode = 2
    var label = "SIMPCC"
    var names: [String] = []   // explicit per-node names; overrides the label+index scheme
    var rate = Int(Sim.tickHz)   // state broadcasts / sec; default = sim tick rate (60)
    var quiet = false
}

func printUsage() {
    print("""
    metro-clusterd — headless metro cluster peer for MetroSystem

    Publishes one or more PCC nodes on the LAN via Bonjour
    (\(Sim.bonjourServiceType)); each node owns a fleet of auto-driven rames
    that the MetroSystem app discovers and shows as remote trains on the
    same circular line (each node's zone controller protects its own
    trains against everyone's). Lets you demonstrate the multi-node CBTC
    networking with a single machine.

    USAGE:
      swift run metro-clusterd [options]

    OPTIONS:
      -n, --nodes    N   Independent peer nodes to publish (default 1)
      -t, --trains   N   Rames per node (default 2)
      -l, --label    S   Node label / Bonjour name prefix for auto-named
                         nodes (default "SIMPCC")
      --name  LIST       Explicit per-node names (comma-separated,
                         repeatable), e.g. OPERA,REPUBLIQUE. Overrides the
                         label+index scheme; if --nodes is omitted, sets
                         the node count.
      -r, --rate     N   State broadcasts / sec (1…\(Int(Sim.tickHz)), default \(Int(Sim.tickHz)))
      -q, --quiet        Suppress per-event logging (banner + heartbeat only)
      --selftest         Run the wire codec self-test and exit (used by CI)
      -h, --help         Show this help and exit

    EXAMPLES:
      swift run metro-clusterd
      swift run metro-clusterd --nodes 2 --trains 2
      swift run metro-clusterd -n 1 -t 3 -l DAUPHINE
      swift run metro-clusterd --name OPERA,REPUBLIQUE   # 2 named nodes
      swift run metro-clusterd --rate 10     # lean on the app's dead reckoning
    """)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("metro-clusterd: \(message)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var nodesSpecified = false
    var args = Array(CommandLine.arguments.dropFirst())

    func takeValue(for flag: String) -> String {
        guard !args.isEmpty else { die("missing value for \(flag)") }
        return args.removeFirst()
    }
    func takeInt(for flag: String) -> Int {
        let raw = takeValue(for: flag)
        guard let value = Int(raw) else { die("invalid integer for \(flag): \(raw)") }
        return value
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-n", "--nodes":  options.nodeCount = takeInt(for: arg); nodesSpecified = true
        case "-t", "--trains": options.trainsPerNode = takeInt(for: arg)
        case "-l", "--label":  options.label = takeValue(for: arg)
        case "--name", "--names":
            let list = takeValue(for: arg)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            options.names.append(contentsOf: list)
        case "-r", "--rate":   options.rate = takeInt(for: arg)
        case "-q", "--quiet":  options.quiet = true
        case "-h", "--help":   printUsage(); exit(0)
        default:               die("unknown option: \(arg) (try --help)")
        }
    }

    // Names given without an explicit --nodes imply one node per name.
    if !nodesSpecified && !options.names.isEmpty {
        options.nodeCount = options.names.count
    }
    options.nodeCount = max(1, options.nodeCount)
    options.trainsPerNode = max(1, options.trainsPerNode)
    // Broadcasting faster than the sim tick would just resend identical
    // state, so cap the rate at the tick rate.
    options.rate = max(1, min(Int(Sim.tickHz), options.rate))
    if options.label.isEmpty { options.label = "SIMPCC" }
    return options
}

// MARK: -- wiring

let options = parseOptions()
let logger = Logger(quiet: options.quiet)
let queue = DispatchQueue(label: "net.dcarmichael.metro.clusterd")

let nodes: [ClusterNode] = (0..<options.nodeCount).map { index in
    // An explicit --name wins; otherwise fall back to the label scheme — a
    // single node keeps the bare label, multiple nodes get a 1-based suffix
    // so they show up as distinct peers (SIMPCC1, SIMPCC2, …).
    let nodeLabel: String
    if index < options.names.count {
        nodeLabel = options.names[index]
    } else {
        nodeLabel = options.nodeCount == 1 ? options.label : "\(options.label)\(index + 1)"
    }
    return ClusterNode(label: nodeLabel, trainCount: options.trainsPerNode,
                       nodeIndex: index, broadcastHz: options.rate,
                       queue: queue, logger: logger)
}

logger.raw("""
==============================================================
 metro-clusterd — MetroSystem headless cluster peer
   nodes: \(options.nodeCount)   rames/node: \(options.trainsPerNode)
   sim tick: \(Int(Sim.tickHz)) Hz   state broadcast: \(options.rate) Hz
   service: \(Sim.bonjourServiceType)   transport: Bonjour/Network.framework
   Launch the MetroSystem app on a Mac on the LAN — this host,
   if it is a Mac, or another — to see these rames appear as
   remote trains on the shared line. Ctrl-C to stop.
==============================================================
""")

queue.async {
    nodes.forEach { $0.start() }
}

// Aggregate heartbeat so the operator can see liveness at a glance,
// including the measured outbound `.state` rate (rounds/sec summed across
// nodes) so the configured broadcast rate is observable, not just asserted.
var lastHeartbeatAt = Date()
let heartbeat = DispatchSource.makeTimerSource(queue: queue)
heartbeat.schedule(deadline: .now() + 10, repeating: 10)
heartbeat.setEventHandler {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastHeartbeatAt)
    lastHeartbeatAt = now
    let trains = nodes.reduce(0) { $0 + $1.trainCount }
    let links = nodes.reduce(0) { $0 + $1.connectionCount }
    let rounds = nodes.reduce(0) { $0 + $1.drainBroadcastRounds() }
    let hz = elapsed > 0 ? Double(rounds) / elapsed : 0
    logger.raw(String(format: "%@  heartbeat — %d node(s), %d rame(s), %d peer link(s), ~%.0f state bcast/s",
                      Logger.clock(), nodes.count, trains, links, hz))
}
heartbeat.resume()

// Graceful shutdown: send `.bye` from every node so the app drops our
// rames cleanly rather than waiting for the TCP keepalive to time out,
// then exit after a short grace period to let those frames flush.
func performShutdown() {
    logger.raw("\nsignal received — notifying peers and shutting down…")
    nodes.forEach { $0.stop(sendBye: true) }
    queue.asyncAfter(deadline: .now() + 0.3) {
        exit(0)
    }
}

func makeSignalSource(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)   // disable default handler; DispatchSource takes over
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler { performShutdown() }
    source.resume()
    return source
}
let signalSources = [makeSignalSource(SIGINT), makeSignalSource(SIGTERM)]
_ = signalSources   // retain for process lifetime

dispatchMain()
