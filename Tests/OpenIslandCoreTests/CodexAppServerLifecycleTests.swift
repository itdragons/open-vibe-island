import Foundation
import Testing
@testable import OpenIslandCore

struct CodexAppServerLifecycleTests {
    @Test
    func outputHandlersUnregisterAtEndOfFile() async throws {
        let client = CodexAppServerClient()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        client.configureOutputHandlers(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )

        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()

        #expect(await waitUntil {
            stdoutPipe.fileHandleForReading.readabilityHandler == nil
                && stderrPipe.fileHandleForReading.readabilityHandler == nil
        })
    }

    @Test
    func stopUnregistersOutputHandlers() throws {
        let client = CodexAppServerClient()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        defer {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        client.configureOutputHandlers(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )

        client.stop()

        #expect(stdoutPipe.fileHandleForReading.readabilityHandler == nil)
        #expect(stderrPipe.fileHandleForReading.readabilityHandler == nil)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
