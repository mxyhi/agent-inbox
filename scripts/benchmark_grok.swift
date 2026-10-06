// 只读本机 Grok 数据，不输出对话、路径或会话标识。
// swiftc -O -parse-as-library Sources/AgentInboxCore/*.swift scripts/benchmark_grok.swift -o /tmp/benchmark-grok
// /usr/bin/time -l /tmp/benchmark-grok
import Foundation

@main struct GrokBenchmark {
    static func main() async {
        let monitor = GrokSessionMonitor()
        let start = DispatchTime.now().uptimeNanoseconds
        let sessions = await monitor.scan()
        print("cold_ms", elapsed(since: start), "sessions", sessions.count)
        print("running", sessions.filter { $0.lifecycleState == .running }.count,
              "verified", sessions.filter { $0.runtimeVerified == true }.count)
        let paths = sessions.filter { $0.runtimeVerified == true }
            .map { $0.filePath + "/resources_state.json" }
        guard !paths.isEmpty else {
            print("无活会话，跳过增量基准")
            return
        }
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await monitor.scanChangedPaths(paths)
            samples.append(elapsed(since: start))
        }
        samples.sort()
        print("incremental_ms", "median", samples[10], "p95", samples[18])
        let warmStart = DispatchTime.now().uptimeNanoseconds
        _ = await monitor.scan()
        print("warm_full_ms", elapsed(since: warmStart))
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
