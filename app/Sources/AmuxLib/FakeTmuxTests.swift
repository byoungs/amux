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

        // FakeTmux removes option on set -u
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("s")
            try fake.execute(["set-option", "-t", "s", "@amux-foo", "bar"])
            check("option set", fake.sessions["s"]?.options["@amux-foo"] == "bar")
            try fake.execute(["set-option", "-u", "-t", "s", "@amux-foo"])
            check("option removed by -u", fake.sessions["s"]?.options["@amux-foo"] == nil)
        } catch {
            failed += 1
            print("FAIL: set-option -u — \(error)")
        }

        // setSessionState writes @amux-state
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("s")
            Tmux.setSessionState("s", state: .foreground)
            check("foreground state set", fake.sessions["s"]?.options["@amux-state"] == "foreground")
            Tmux.setSessionState("s", state: .background)
            check("background state set", fake.sessions["s"]?.options["@amux-state"] == "background")
        } catch {
            failed += 1
            print("FAIL: setSessionState — \(error)")
        }

        // getSessionState reads @amux-state; defaults to foreground when missing
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("s")
            check("missing state defaults to foreground",
                  (try? Tmux.getSessionState("s")) == .foreground)
            Tmux.setSessionState("s", state: .background)
            check("reads background", (try? Tmux.getSessionState("s")) == .background)
        } catch {
            failed += 1
            print("FAIL: getSessionState — \(error)")
        }

        // listSessionsByState segregates by state
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("a")
            Tmux.markAsManaged("a")
            Tmux.setSessionState("a", state: .foreground)
            try Tmux.createSession("b")
            Tmux.markAsManaged("b")
            Tmux.setSessionState("b", state: .background)
            try Tmux.createSession("c")
            Tmux.markAsManaged("c") // no explicit state — defaults to foreground
            let fg = (try? Tmux.listSessionsByState(.foreground)) ?? []
            let bg = (try? Tmux.listSessionsByState(.background)) ?? []
            check("a is foreground", fg.contains("a"))
            check("c is foreground (default)", fg.contains("c"))
            check("b is not foreground", !fg.contains("b"))
            check("b is background", bg.contains("b"))
            check("a is not background", !bg.contains("a"))
        } catch {
            failed += 1
            print("FAIL: listSessionsByState — \(error)")
        }

        // listFocusSessions delegates to listSessionsByState(.foreground)
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("fg-only")
            Tmux.markAsManaged("fg-only")
            Tmux.setSessionState("fg-only", state: .foreground)
            try Tmux.createSession("bg-only")
            Tmux.markAsManaged("bg-only")
            Tmux.setSessionState("bg-only", state: .background)
            let focus = (try? Tmux.listFocusSessions()) ?? []
            check("listFocusSessions includes fg-only", focus.contains("fg-only"))
            check("listFocusSessions excludes bg-only", !focus.contains("bg-only"))
        } catch {
            failed += 1
            print("FAIL: listFocusSessions — \(error)")
        }

        // listSpacesWithAlerts excludes background sessions
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("fg")
            Tmux.markAsManaged("fg")
            Tmux.setSessionState("fg", state: .foreground)
            try Tmux.createSession("bg")
            Tmux.markAsManaged("bg")
            Tmux.setSessionState("bg", state: .background)
            let spaces = (try? Tmux.listSpacesWithAlerts())
                          ?? (sessions: [], alertCounts: [:])
            check("listSpacesWithAlerts includes fg", spaces.sessions.contains("fg"))
            check("listSpacesWithAlerts excludes bg", !spaces.sessions.contains("bg"))
        } catch {
            failed += 1
            print("FAIL: listSpacesWithAlerts — \(error)")
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

        // FakeTmux resolves set-option -p -t %ID across sessions
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("s1")
            let panes = try Tmux.listPanes("s1")
            let firstIdx = panes.first!.index
            let idStr = try Tmux.paneIdAt("s1", index: firstIdx) // e.g. "%0"
            try fake.execute(["set-option", "-p", "-t", idStr, "@amux-x", "42"])
            let v = try fake.execute(["display-message", "-t", idStr, "-p", "#{@amux-x}"])
            check("pane-id target round trips", v == "42")
        } catch {
            failed += 1
            print("FAIL: pane-id target round trip — \(error)")
        }

        // FakeTmux join-pane moves a pane across sessions, preserving options
        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("src")
            try Tmux.createSession("dst")
            let srcPanes = try Tmux.listPanes("src")
            let paneId = try Tmux.paneIdAt("src", index: srcPanes.first!.index)
            try fake.execute(["set-option", "-p", "-t", paneId, "@amux-foo", "keepme"])
            try fake.execute(["join-pane", "-s", paneId, "-t", "dst:0"])
            let v = try fake.execute(["display-message", "-t", paneId, "-p", "#{@amux-foo}"])
            check("option preserved across join", v == "keepme")
            let dstPanes = try Tmux.listPanes("dst")
            check("pane lives in dst", dstPanes.count >= 1)
        } catch {
            failed += 1
            print("FAIL: join-pane across sessions — \(error)")
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

        // --- parkPane: source has >1 pane → split out to new background session ---

        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("multi")
            Tmux.markAsManaged("multi")
            Tmux.setSessionState("multi", state: .foreground)
            _ = try Tmux.createPane("multi") // now 2 panes
            let panes = try Tmux.listPanes("multi")
            try Tmux.setTitle("multi", paneIndex: panes[1].index, title: "park-me")
            let parkedName = try Tmux.parkPane(
                "multi", paneIndex: panes[1].index, now: 1700000123)
            check("source still has 1 pane", (try? Tmux.paneCount("multi")) == 1)
            check("new background session created", fake.sessions[parkedName] != nil)
            check("new session marked background",
                  fake.sessions[parkedName]?.options["@amux-state"] == "background")
            check("parkedAt stamped",
                  fake.sessions[parkedName]?.options["@amux-parked-at"] == "1700000123")
            check("parkedFrom stamped",
                  fake.sessions[parkedName]?.options["@amux-parked-from"] == "multi")
        } catch {
            failed += 1
            print("FAIL: parkPane split-out — \(error)")
        }

        // --- parkPane: source has exactly 1 pane → flip source to background ---

        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            try Tmux.createSession("solo")
            Tmux.markAsManaged("solo")
            Tmux.setSessionState("solo", state: .foreground)
            let panes = try Tmux.listPanes("solo")
            let parkedName = try Tmux.parkPane(
                "solo", paneIndex: panes[0].index, now: 1700000200)
            check("parked name is the source session", parkedName == "solo")
            check("source flipped to background",
                  fake.sessions["solo"]?.options["@amux-state"] == "background")
            check("parkedAt stamped",
                  fake.sessions["solo"]?.options["@amux-parked-at"] == "1700000200")
            check("parkedFrom stamped",
                  fake.sessions["solo"]?.options["@amux-parked-from"] == "solo")
        } catch {
            failed += 1
            print("FAIL: parkPane flip — \(error)")
        }

        print("FakeTmuxTests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("\(failed) FakeTmux tests failed") }
    }
}
#endif
