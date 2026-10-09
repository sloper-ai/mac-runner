import Foundation

/// Startup recovery can race a CLI start after the app's launch snapshot.
@MainActor
enum RunnerStartupRecovery {
    static func failure(start: () async throws -> Void) async -> Error? {
        do {
            try await start()
            return nil
        } catch RunnerError.alreadyRunning {
            // startRunner reloaded the other process's published state before
            // checking its live PID. Keep that state and supervise its exit.
            return nil
        } catch RunnerError.startInProgress {
            // Another start still owns startup coordination. The supervisor
            // follows its result once it releases the lock.
            return nil
        } catch {
            return error
        }
    }
}
