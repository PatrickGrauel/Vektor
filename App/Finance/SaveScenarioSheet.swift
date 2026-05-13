import SwiftUI

/// Shared "name your saved scenario" sheet. Used by both the Loan form
/// (saved loan scenarios) and the Real-Estate form (saved deals).
struct SaveScenarioSheet: View {
    let title: String
    let placeholder: String
    let initialName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(title: String, placeholder: String, initialName: String,
         onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.initialName = initialName
        self.onSave = onSave
        self.onCancel = onCancel
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).foregroundStyle(TallyTheme.text)
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .themedSheet()
    }
}
