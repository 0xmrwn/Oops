/// An async mutex: waiters run one after another, in arrival order.
actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

#if DEBUG
extension SerialGate {
    var waiterCount: Int { waiting.count }
}
#endif
