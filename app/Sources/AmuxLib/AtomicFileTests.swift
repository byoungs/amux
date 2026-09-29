#if DEBUG
import Foundation

/// AtomicFile under concurrent writers: the app and amux-cli (from tmux
/// hooks) can save the same snapshot/state file at the same moment.
public enum AtomicFileTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        struct Payload: Codable { let writer: Int; let body: [Int] }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-atomicfile-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.json")

        let lock = NSLock()
        var writeErrors: [String] = []
        var torn = 0
        let writers = 8, writesEach = 25

        // Writers race each other while a reader keeps decoding whatever is
        // in place. Payloads are large enough that a write isn't instant, so
        // a shared temp path gets clobbered mid-write.
        DispatchQueue.concurrentPerform(iterations: writers + 1) { worker in
            if worker == writers {
                for _ in 0..<(writers * writesEach) {
                    guard let data = try? Data(contentsOf: path) else { continue }
                    if (try? JSONDecoder().decode(Payload.self, from: data)) == nil {
                        lock.lock(); torn += 1; lock.unlock()
                    }
                }
                return
            }
            let data = try! JSONEncoder().encode(
                Payload(writer: worker, body: Array(repeating: worker, count: 20_000)))
            for _ in 0..<writesEach {
                do {
                    try AtomicFile.write(data, to: path)
                } catch {
                    lock.lock(); writeErrors.append("\(error)"); lock.unlock()
                }
            }
        }

        check("concurrent-writes-succeed", writeErrors.isEmpty,
              "\(writeErrors.count) errors, first: \(writeErrors.first ?? "")")
        check("concurrent-reads-never-torn", torn == 0, "\(torn) undecodable reads")

        let final = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        check("final-file-decodes-whole",
              final.map { p in p.body.count == 20_000 && p.body.allSatisfy { $0 == p.writer } } ?? false)

        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != "state.json" }
        check("no-temp-files-left", leftovers.isEmpty, "\(leftovers)")

        print("AtomicFile tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("AtomicFile tests failed") }
    }
}
#endif
