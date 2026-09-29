import Foundation

#if DEBUG
public enum SpaceNameTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ actual: String?, _ expected: String?) {
            if actual == expected { passed += 1 }
            else { failed += 1; print("FAIL: \(name) — got \(actual ?? "nil"), want \(expected ?? "nil")") }
        }

        check("plain name unchanged", SpaceName.normalize("backend"), "backend")
        check("dash and underscore kept", SpaceName.normalize("api_v2-fix"), "api_v2-fix")
        check("spaces become one dash", SpaceName.normalize("my   space"), "my-space")
        check("shell metacharacters removed",
              SpaceName.normalize("bob's $(rm) \"x\";y"), "bob-s-rm-x-y")
        check("tmux separators removed", SpaceName.normalize("a.b:c"), "a-b-c")
        check("surrounding whitespace dropped", SpaceName.normalize("  --x--  "), "--x--")
        check("leading junk dropped", SpaceName.normalize("!!!work"), "work")
        check("nothing usable is nil", SpaceName.normalize(" '\"; "), nil)
        check("non-ASCII letters kept", SpaceName.normalize("café notes"), "café-notes")

        print("SpaceName tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("SpaceName tests failed") }
    }
}
#endif
