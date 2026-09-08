import Foundation

@MainActor final class Harness {
    private var failures = 0
    private var total = 0

    func expect(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("  ok   \(label)")
        } else {
            print("  FAIL \(label)")
            failures += 1
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, "\(label) (got \(actual), want \(expected))")
    }

    func section(_ name: String) { print("\n\(name)") }

    func report() -> Int32 {
        print(failures == 0 ? "\nPASS \(total)/\(total)" : "\nFAILED \(failures)/\(total)")
        return failures == 0 ? 0 : 1
    }
}
