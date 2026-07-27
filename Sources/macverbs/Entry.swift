import Foundation
import MacverbsCore

/// Process entry only. CLI logic lives in `MacverbsCore.MacverbsApp`.
@main
enum Entry {
    static func main() {
        Foundation.exit(
            MacverbsApp.run(arguments: Array(CommandLine.arguments.dropFirst()))
        )
    }
}
