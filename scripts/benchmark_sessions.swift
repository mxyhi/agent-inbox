// 只读四个会话源；仅输出数量、耗时和解析字节，不输出对话或会话标识。
// swiftc -O -parse-as-library Sources/AgentInboxCore/*.swift scripts/benchmark_sessions.swift -o /tmp/benchmark-sessions
// /usr/bin/time -l /tmp/benchmark-sessions
import Foundation

@main struct SessionsBenchmark {
    static func main() async {
        let monitor = CompositeSessionMonitor()
        await measure("Codex", scan: { await monitor.codex.scan() }, change: { await monitor.codex.scanChangedPaths($0) })
        await measure("Grok", scan: { await monitor.grok.scan() }, change: { await monitor.grok.scanChangedPaths($0) })
        await measure("Claude", scan: { await monitor.claude.scan() }, change: { await monitor.claude.scanChangedPaths($0) })
        await measure("DSH", scan: { await monitor.dsh.scan() }, change: { await monitor.dsh.scanChangedPaths($0) })
        print("DSH warm decoded bytes", await monitor.dsh.lastDecodedBytes)
        _ = await monitor.scan()
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await monitor.scanChangedPaths(["/tmp/agent-inbox-unrelated-event"])
            samples.append(elapsed(since: start))
        }
        print("Composite unrelated median_ms", samples.sorted()[10], "p95_ms", samples.sorted()[18])
    }

    private static func measure(
        _ name: String,
        scan: () async -> [SessionSummary],
        change: ([String]) async -> [SessionSummary]
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        let summaries = await scan()
        let cold = elapsed(since: start)
        let paths = summaries.prefix(1).map(\.filePath)
        var samples: [Double] = []
        for _ in 0..<20 {
            let tick = DispatchTime.now().uptimeNanoseconds
            _ = await change(paths)
            samples.append(elapsed(since: tick))
        }
        let warmStart = DispatchTime.now().uptimeNanoseconds
        _ = await scan()
        print(name, "sessions", summaries.count, "cold_ms", cold,
              "unchanged_event_median_ms", samples.sorted()[10], "p95_ms", samples.sorted()[18],
              "warm_full_ms", elapsed(since: warmStart))
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
