import SwiftUI
import VektorEngine

/// The Calculator pane — Vektor's core surface. Drives the shared
/// `NumiEngine` over the active document and renders results in the gutter.
struct CalculatorView: View {
    let engine: NumiEngine?
    let error: String?
    @ObservedObject var documents: DocumentStore

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var results: [LineResult] = []
    @State private var evaluateTask: Task<Void, Never>?

    // Periodic re-evaluation so live data (FX, current-time results)
    // refreshes without the user typing.
    private let recomputeTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Engine failed to start",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                CalcEditor(
                    text: Binding(
                        get: { documents.selected.content },
                        set: { documents.updateSelectedContent($0) }
                    ),
                    results: results,
                    gutterWidth: sizeClass == .compact ? 120 : 160,
                    resolvePageReference: { documents.resolvesSlug($0) }
                )
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .background(VektorTheme.background)
        .navigationTitle(documents.selected.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { evaluate() }
        .onChange(of: documents.selectedID) { _, _ in evaluate() }
        .onChange(of: documents.selected.content) { _, _ in scheduleEvaluate() }
        // FX / crypto rates just landed — re-evaluate so currency
        // conversions drop their offline placeholder.
        .onReceive(NotificationCenter.default.publisher(for: NumiEngine.ratesUpdatedNotification)) { _ in
            evaluate()
        }
        .onReceive(recomputeTick) { _ in evaluate() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                let doc = documents.newDocument()
                documents.select(doc.id)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New calculation")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(documents.listed) { doc in
                    Button {
                        documents.select(doc.id)
                    } label: {
                        Label(
                            doc.title,
                            systemImage: doc.id == documents.selectedID
                                ? "checkmark"
                                : (doc.isPinned ? "pin.fill" : "doc.text")
                        )
                    }
                }
                if documents.documents.count > 1 {
                    Divider()
                    Button(role: .destructive) {
                        documents.delete(documents.selectedID)
                    } label: {
                        Label("Delete current sheet", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Switch sheet")
        }
    }

    // MARK: - Evaluation

    private func scheduleEvaluate() {
        evaluateTask?.cancel()
        evaluateTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { evaluate() }
        }
    }

    private func evaluate() {
        guard let engine else { return }
        results = engine.evaluate(documents.selected.content)
    }
}
