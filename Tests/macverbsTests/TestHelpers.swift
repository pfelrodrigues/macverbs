import Foundation
@testable import MacverbsCore

/// Process-wide lock for CLIOutput handles + BackendClients + env overrides.
/// All tests that touch shared process state must take this lock.
let globalCLIStateLock = NSRecursiveLock()

struct StdioPipes {
    let outRead: FileHandle
    let errRead: FileHandle
    let outWrite: FileHandle
    let errWrite: FileHandle

    func readOutput() throws -> String {
        outWrite.closeFile()
        let data = outRead.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func readError() throws -> String {
        errWrite.closeFile()
        let data = errRead.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func restore() {
        CLIOutput.outFile = .standardOutput
        CLIOutput.errFile = .standardError
        outRead.closeFile()
        errRead.closeFile()
    }
}

func withBackendClientsLock(_ body: () throws -> Void) throws {
    globalCLIStateLock.lock()
    defer { globalCLIStateLock.unlock() }
    try body()
}

func withRedirectedStdio(_ body: (StdioPipes) throws -> Void) throws {
    globalCLIStateLock.lock()
    defer { globalCLIStateLock.unlock() }

    let outPipe = Pipe()
    let errPipe = Pipe()
    let pipes = StdioPipes(
        outRead: outPipe.fileHandleForReading,
        errRead: errPipe.fileHandleForReading,
        outWrite: outPipe.fileHandleForWriting,
        errWrite: errPipe.fileHandleForWriting
    )
    CLIOutput.outFile = pipes.outWrite
    CLIOutput.errFile = pipes.errWrite
    defer { pipes.restore() }
    try body(pipes)
}
