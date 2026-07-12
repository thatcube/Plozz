import SwiftUI
import SearchIndexKit
import Darwin

#if DEBUG && canImport(NaturalLanguage)
@main
struct SearchIndexSpikeHostApp: App {
    @State private var status = "Running local search spike…"

    var body: some Scene {
        WindowGroup {
            Text(status)
                .font(.title3.monospaced())
                .multilineTextAlignment(.leading)
                .padding(80)
                .task {
                    do {
                        let report = try await SearchIndexSpikeRunner().run(
                            sqliteScaleCounts: [10_000, 50_000, 100_000]
                        )
                        let output = report.lines.joined(separator: "\n")
                        status = output
                        print(output)
                        fflush(stdout)
                        try? await Task.sleep(for: .milliseconds(500))
                        exit(EXIT_SUCCESS)
                    } catch {
                        status = "SEARCH_INDEX_SPIKE_ERROR \(error)"
                        print(status)
                        fflush(stdout)
                        try? await Task.sleep(for: .milliseconds(500))
                        exit(EXIT_FAILURE)
                    }
                }
        }
    }
}
#else
@main
struct SearchIndexSpikeHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Search spike requires a Debug build.")
        }
    }
}
#endif
