import SwiftUI

/// Общая оболочка правой панели редактора.
struct InspectorPanel<Content: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let close: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Label(title, systemImage: systemImage)
                    .typeStyle(.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.mzIcon(.quiet, iconSize: IconScale.inline, width: 24, height: 24))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Закрыть панель")
                    .accessibilityLabel("Закрыть панель")
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: 52)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer()
        }
        .cardStyle()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

extension InspectorPanel where Footer == EmptyView {
    init(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        close: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            accessibilityIdentifier: accessibilityIdentifier,
            close: close,
            content: content,
            footer: { EmptyView() })
    }
}
