import Darwin

enum ProcessTree {
    struct Member: Hashable {
        let pid: pid_t, group: pid_t, started: timeval

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pid == rhs.pid && lhs.group == rhs.group && lhs.started.tv_sec == rhs.started.tv_sec && lhs.started.tv_usec == rhs.started.tv_usec
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(pid)
            hasher.combine(group)
            hasher.combine(started.tv_sec)
            hasher.combine(started.tv_usec)
        }
    }

    private static func processes(_ selector: [Int32]) -> [kinfo_proc] {
        var mib = selector
        let count = UInt32(mib.count)
        var size = 0
        while sysctl(&mib, count, nil, &size, nil, 0) == 0, size > 0 {
            let stride = MemoryLayout<kinfo_proc>.stride
            var rows = Array(repeating: kinfo_proc(), count: size / stride + 1)
            size = rows.count * stride
            let status = rows.withUnsafeMutableBytes { sysctl(&mib, count, $0.baseAddress, &size, nil, 0) }
            if status == 0 { return Array(rows.prefix(size / stride)) }
            if errno != ENOMEM { break }
        }
        return []
    }

    static func runMembers(marker: String, group: pid_t, folder: String) -> Set<Member> {
        let uid = geteuid()
        var rows = processes([CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)])
        if rows.isEmpty {
            rows = processes([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]).filter { $0.kp_eproc.e_ucred.cr_uid == uid }
        }
        let entry = Array(("OOPS_AGENT_RUN=" + marker).utf8)
        var buffer = [UInt8](repeating: 0, count: Int(ARG_MAX))
        var directory = stat()
        let hasDirectory = stat(folder, &directory) == 0
        var members = Set<Member>()
        for row in rows {
            let pid = row.kp_proc.p_pid
            guard pid > 1, pid != getpid() else { continue }
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            let matches = buffer.withUnsafeMutableBytes { bytes in
                sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0) == 0 &&
                    hasEnvironmentEntry(entry, in: UnsafeRawBufferPointer(rebasing: bytes[..<size]))
            }
            if matches || (row.kp_eproc.e_pgid == group && hasDirectory && workingDirectory(of: pid, matches: directory)) {
                members.insert(Member(pid: pid, group: row.kp_eproc.e_pgid, started: row.kp_proc.p_starttime))
            }
        }
        return members
    }

    // macOS omits the environment of protected executables. Their run group and working directory still identify them.
    private static func workingDirectory(of pid: pid_t, matches directory: stat) -> Bool {
        var paths = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: paths))
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return false }
        let node = paths.pvi_cdir.vip_vi.vi_stat
        return node.vst_dev == UInt32(bitPattern: directory.st_dev) && node.vst_ino == directory.st_ino
    }

    static func hasEnvironmentEntry(_ entry: [UInt8], in bytes: UnsafeRawBufferPointer) -> Bool {
        let header = MemoryLayout<CInt>.size
        guard bytes.count > header, entry.withUnsafeBytes({ memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) }) != nil else { return false }
        let argc = bytes.loadUnaligned(as: CInt.self)
        guard argc >= 0, let pathEnd = bytes[header...].firstIndex(of: 0) else { return false }
        var cursor = pathEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        // A marker in an argument is not an inherited environment entry.
        for _ in 0..<argc {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return false }
            cursor = end + 1
        }
        while cursor < bytes.count, bytes[cursor] != 0, let end = bytes[cursor...].firstIndex(of: 0) {
            if bytes[cursor..<end].elementsEqual(entry) { return true }
            cursor = end + 1
        }
        return false
    }

    static func descendants(of root: pid_t) -> Set<Member> {
        let snapshot = processes([CTL_KERN, KERN_PROC, KERN_PROC_ALL])
        // Some sandboxes hide the global process table but allow querying our own children.
        let children = Dictionary(grouping: snapshot, by: { $0.kp_eproc.e_ppid })
        var parents = [root], found = Set<Member>()
        while let parent = parents.popLast() {
            let rows = snapshot.isEmpty ? childProcesses(of: parent) : children[parent] ?? []
            for row in rows {
                let child = Member(pid: row.kp_proc.p_pid, group: row.kp_eproc.e_pgid, started: row.kp_proc.p_starttime)
                if found.insert(child).inserted { parents.append(child.pid) }
            }
        }
        return found
    }

    private static func childProcesses(of parent: pid_t) -> [kinfo_proc] {
        var capacity = 16
        while true {
            var pids = Array(repeating: pid_t(0), count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            guard count > 0 else { return [] }
            if count < capacity {
                return pids.prefix(Int(count)).compactMap { pid in
                    let row = processes([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]).first
                    return row?.kp_eproc.e_ppid == parent ? row : nil
                }
            }
            capacity *= 2
        }
    }

    static func isAlive(_ member: Member) -> Bool {
        guard let row = processes([CTL_KERN, KERN_PROC, KERN_PROC_PID, member.pid]).first else { return false }
        let started = row.kp_proc.p_starttime
        return started.tv_sec == member.started.tv_sec && started.tv_usec == member.started.tv_usec
    }
}
