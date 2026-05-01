#if DEBUG
import Foundation
import Darwin

public enum FakeTmuxTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else {
                failed += 1
                fputs("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")\n", stderr)
            }
        }

        // --- Session lifecycle ---

        do {
            let tmux = FakeTmux()
            try tmux.execute(["new-session", "-d", "-s", "test"])
            check("new-session creates session", tmux.sessions["test"] != nil)
            check(
                "new-session creates one window",
                tmux.sessions["test"]?.windows.count == 1)
            check(
                "new-session creates one pane",
                tmux.sessions["test"]?.windows.first?.panes.count == 1)

            _ = try tmux.execute(["has-session", "-t", "test"])
            check("has-session succeeds for existing", true)

            var threw = false
            do { _ = try tmux.execute(["has-session", "-t", "nope"]) }
            catch { threw = true }
            check("has-session throws for missing", threw)

            let sessions = try tmux.execute(
                ["list-sessions", "-F", "#{session_name}"])
            check("list-sessions returns name", sessions == "test")

            try tmux.execute(["kill-session", "-t", "test"])
            check("kill-session removes it", tmux.sessions["test"] == nil)
        } catch {
            failed += 1
            print("FAIL: session lifecycle — \(error)")
        }

        // --- Builder helpers ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("dev", panes: 3, width: 100, height: 40)
            check(
                "addSession creates 3 panes",
                tmux.sessions["dev"]?.windows.first?.panes.count == 3)
            check(
                "panes have correct width",
                tmux.pane("dev", index: 0)?.width == 100)
            check(
                "panes have unique ids",
                tmux.pane("dev", index: 0)?.id != tmux.pane("dev", index: 1)?.id)
        }

        // --- Pane options (set/show) ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)

            try tmux.execute([
                "set-option", "-p", "-t", "s:.0", "@amux-title", "hello",
            ])
            let title = try tmux.execute([
                "show-options", "-p", "-t", "s:.0", "-v", "@amux-title",
            ])
            check("pane option set/get", title == "hello")

            // Unset pane option should throw (matching real tmux behavior)
            let unsetResult = try? tmux.execute([
                "show-options", "-p", "-t", "s:.1", "-v", "@amux-title",
            ])
            check("unset pane option throws", unsetResult == nil)
        } catch {
            failed += 1
            print("FAIL: pane options — \(error)")
        }

        // --- Session options ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s")

            try tmux.execute(["set-option", "-t", "s", "@amux-picking", "1"])
            let picking = try tmux.execute([
                "show-options", "-t", "s", "-v", "@amux-picking",
            ])
            check("session option set/get", picking == "1")

            try tmux.execute(["set-option", "-t", "s", "-u", "@amux-picking"])
            let gone = try? tmux.execute([
                "show-options", "-t", "s", "-v", "@amux-picking",
            ])
            check("session option unset throws", gone == nil)
        } catch {
            failed += 1
            print("FAIL: session options — \(error)")
        }

        // --- Global/server options ---

        do {
            let tmux = FakeTmux()
            try tmux.execute(["set", "-g", "pane-border-format", "fancy"])
            let val = try tmux.execute([
                "show-options", "-gv", "pane-border-format",
            ])
            check("global option set/get", val == "fancy")
        } catch {
            failed += 1
            print("FAIL: global options — \(error)")
        }

        // --- Environment ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s")

            try tmux.execute([
                "set-environment", "-t", "s", "AMUX_MANAGED", "1",
            ])
            let env = try tmux.execute([
                "show-environment", "-t", "s", "AMUX_MANAGED",
            ])
            check("environment set/get", env == "AMUX_MANAGED=1")

            try tmux.execute([
                "set-environment", "-t", "s", "-u", "AMUX_MANAGED",
            ])
            let gone = try tmux.execute([
                "show-environment", "-t", "s", "AMUX_MANAGED",
            ])
            check("environment unset", gone == "")
        } catch {
            failed += 1
            print("FAIL: environment — \(error)")
        }

        // --- Zoom toggle ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s")

            let before = try tmux.execute([
                "display-message", "-t", "s", "-p", "#{window_zoomed_flag}",
            ])
            check("not zoomed initially", before == "0")

            try tmux.execute(["resize-pane", "-t", "s", "-Z"])
            let after = try tmux.execute([
                "display-message", "-t", "s", "-p", "#{window_zoomed_flag}",
            ])
            check("zoomed after toggle", after == "1")

            try tmux.execute(["resize-pane", "-t", "s", "-Z"])
            let reverted = try tmux.execute([
                "display-message", "-t", "s", "-p", "#{window_zoomed_flag}",
            ])
            check("unzoomed after second toggle", reverted == "0")
        } catch {
            failed += 1
            print("FAIL: zoom — \(error)")
        }

        // --- Format evaluation with user options ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)
            tmux.setPaneOption("s", paneIndex: 0, key: "@amux-alert", value: "1")

            let result = try tmux.execute([
                "list-panes", "-t", "s", "-F",
                "#{pane_index}\t#{@amux-alert}\t#{pane_width}",
            ])
            let lines = result.split(separator: "\n").map(String.init)
            check("list-panes format line count", lines.count == 2)
            check("list-panes format pane 0", lines[0] == "0\t1\t99")
            check("list-panes format pane 1", lines[1] == "1\t\t100")
        } catch {
            failed += 1
            print("FAIL: format evaluation — \(error)")
        }

        // --- display-message with pane_id ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)

            let paneId = try tmux.execute([
                "display-message", "-t", "s:.1", "-p", "#{pane_id}",
            ])
            check(
                "display-message pane_id starts with %",
                paneId.hasPrefix("%"))
        } catch {
            failed += 1
            print("FAIL: display-message pane_id — \(error)")
        }

        // --- Hooks ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s")

            try tmux.execute([
                "set-hook", "-t", "s", "pane-exited", "run amux cleanup",
            ])
            check(
                "hook stored",
                tmux.sessions["s"]?.hooks["pane-exited"] == "run amux cleanup")

            try tmux.execute(["set-hook", "-u", "-t", "s", "pane-exited"])
            check(
                "hook unset",
                tmux.sessions["s"]?.hooks["pane-exited"] == nil)
        } catch {
            failed += 1
            print("FAIL: hooks — \(error)")
        }

        // --- Pipe-pane ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s")

            try tmux.execute([
                "pipe-pane", "-t", "s:.0",
                "exec amux bell-watch --session s 0",
            ])
            check(
                "pipe-pane stored",
                tmux.pane("s", index: 0)?.pipePaneCommand
                    == "exec amux bell-watch --session s 0")
        } catch {
            failed += 1
            print("FAIL: pipe-pane — \(error)")
        }

        // --- Resize ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 1, width: 200, height: 50)

            try tmux.execute([
                "resize-pane", "-t", "s:.0", "-x", "100", "-y", "30",
            ])
            check("resize width", tmux.pane("s", index: 0)?.width == 100)
            check("resize height", tmux.pane("s", index: 0)?.height == 30)
        } catch {
            failed += 1
            print("FAIL: resize — \(error)")
        }

        // --- Version ---

        do {
            let tmux = FakeTmux()
            let version = try tmux.execute(["-V"])
            check("version returns tmux 3.5", version == "tmux 3.5")
        } catch {
            failed += 1
            print("FAIL: version — \(error)")
        }

        // --- Target parsing: %NNN pane ID ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)
            let paneId = tmux.pane("s", index: 1)!.id
            let result = try tmux.execute([
                "display-message", "-t", "%\(paneId)", "-p", "#{pane_index}",
            ])
            check("target by pane ID resolves index", result == "1")
        } catch {
            failed += 1
            print("FAIL: target parsing — \(error)")
        }

        // --- Unhandled commands recorded ---

        do {
            let tmux = FakeTmux()
            try tmux.execute(["some-unknown-cmd", "-x", "foo"])
            check("unhandled command recorded", tmux.unhandledCommands.count == 1)
        } catch {
            failed += 1
            print("FAIL: unhandled commands — \(error)")
        }

        // --- No-op commands don't throw ---

        do {
            let tmux = FakeTmux()
            _ = try tmux.execute(["switch-client", "-t", "foo"])
            _ = try tmux.execute(["attach-session", "-t", "foo"])
            _ = try tmux.execute([
                "display-popup", "-E", "-w", "70", "-h", "20", "cmd",
            ])
            _ = try tmux.execute(["unbind-key", "-a"])
            check("no-op commands succeed", true)
        } catch {
            failed += 1
            print("FAIL: no-op commands — \(error)")
        }

        // launch() records args
        do {
            let fake = FakeTmux()
            fake.addSession("test", panes: 1)
            fake.launch(["display-popup", "-t", "test", "-E", "echo hi"])
            check("launch-records-args",
                  fake.launchedCommands.count == 1
                  && fake.launchedCommands[0] == ["display-popup", "-t", "test", "-E", "echo hi"])
        }

        // --- split-window ---

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)

            let result = try tmux.execute([
                "split-window", "-t", "s:0", "-d", "-P", "-F", "#{pane_id}",
                "-c", "/foo",
            ])
            check(
                "split-window appends pane",
                tmux.sessions["s"]?.windows.first?.panes.count == 3,
                "expected 3 panes, got \(tmux.sessions["s"]?.windows.first?.panes.count ?? -1)")
            check(
                "split-window returns new pane id",
                result.hasPrefix("%"),
                "expected %N id, got '\(result)'")
            check(
                "split-window -d keeps original active pane",
                tmux.sessions["s"]?.windows.first?.activePaneIndex == 0)
            check(
                "split-window -c sets cwd on new pane",
                tmux.sessions["s"]?.windows.first?.panes.last?.cwd == "/foo")
        } catch {
            failed += 1
            print("FAIL: split-window — \(error)")
        }

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 2)
            _ = try? tmux.execute(["split-window", "-t", "s:0"])
            check(
                "split-window without -d activates new pane",
                tmux.sessions["s"]?.windows.first?.activePaneIndex == 2)
        }

        do {
            let tmux = FakeTmux()
            tmux.addSession("s", panes: 1)
            var threw = false
            do { _ = try tmux.execute(["split-window"]) }
            catch { threw = true }
            check("split-window missing -t throws", threw)
        }

        do {
            let tmux = FakeTmux()
            var threw = false
            do { _ = try tmux.execute(["split-window", "-t", "nope:0"]) }
            catch { threw = true }
            check("split-window unknown session throws", threw)
        }

        print("FakeTmuxTests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("\(failed) FakeTmux tests failed") }
    }
}
#endif
