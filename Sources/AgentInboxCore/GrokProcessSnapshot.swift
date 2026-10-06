import Darwin
import Foundation

/// 进程打开的会话文件比启动 argv 更可靠：/resume、/new、fork 可在同一 TUI 内发生。
/// 仅检查当前用户的 Grok 二进制；PID 被其他程序复用时不能继承旧会话。
struct GrokProcessSnapshot: Sendable, Equatable {
    let startedAt: Date
    let openFiles: Set<String>

    static func read(pid: Int32) -> GrokProcessSnapshot? {
        // proc_info.h 的 PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN，Swift 不导入此宏。
        var executable = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathSize = executable.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard pathSize > 0 else { return nil }
        let name = URL(filePath: String(decoding: executable.prefix(while: { $0 != 0 }), as: UTF8.self)).lastPathComponent
        guard name == "grok" || name.hasPrefix("grok-") else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_uid == getuid() else { return nil }

        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        // 允许枚举期间新增少量 fd；下一次扫描仍会校准。
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        let read = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard read > 0 else { return nil }
        var paths: Set<String> = []
        for fd in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) > 0 else { continue }
            let path = withUnsafeBytes(of: &vnode.pvip.vip_path) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            paths.insert(URL(filePath: path).standardizedFileURL.path)
        }
        return GrokProcessSnapshot(
            startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
            openFiles: paths
        )
    }
}
