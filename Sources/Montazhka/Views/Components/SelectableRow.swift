import SwiftUI

/// Строка списка с выбором: качество экспорта, мелодия, найденная пауза.
///
/// Раньше каждая из трёх панелей рисовала такую строку сама, поэтому они
/// расходились в отступах, радиусе и подсветке выбранного.
struct SelectableRow<Accessory: View>: View {
    /// Чем отмечен выбор слева.
    enum Marker {
        /// Один из нескольких вариантов: галочка в кружке.
        case choice
        /// Независимая галочка, которую можно снять.
        case checkbox(Binding<Bool>)
        /// Без отметки — выбор виден по подсветке строки.
        case none
    }

    let marker: Marker
    let title: String
    var titleStyle: TypeStyle = .bodyEmphasis
    var subtitle: String?
    var leadingSystemImage: String?
    let isSelected: Bool
    var tint: Color = Theme.accent
    var accessibilityIdentifier: String?
    /// Нажатие по всей строке. Если действия нет, строка не кликается целиком —
    /// как у найденной паузы, где работают только галочка и кнопка прослушивания.
    var select: (() -> Void)?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        if let select {
            Button(action: select) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
        } else {
            content
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
        }
    }

    private var content: some View {
        HStack(spacing: Theme.Spacing.snug) {
            markerView

            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
                    .font(.system(size: IconScale.inline + 2))
                    .foregroundStyle(isSelected ? tint : Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(title)
                    .typeStyle(titleStyle)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            accessory()
        }
        .padding(.horizontal, Theme.Spacing.snug)
        .padding(.vertical, Theme.Spacing.small)
        .background(isSelected ? tint.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var markerView: some View {
        switch marker {
        case .choice:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: IconScale.inline + 4))
                .foregroundStyle(isSelected ? tint : Theme.textSecondary.opacity(0.5))
        case .checkbox(let binding):
            Toggle("", isOn: binding)
                .toggleStyle(.checkbox)
                .labelsHidden()
        case .none:
            EmptyView()
        }
    }
}

extension SelectableRow where Accessory == EmptyView {
    init(
        marker: Marker,
        title: String,
        titleStyle: TypeStyle = .bodyEmphasis,
        subtitle: String? = nil,
        leadingSystemImage: String? = nil,
        isSelected: Bool,
        tint: Color = Theme.accent,
        accessibilityIdentifier: String? = nil,
        select: (() -> Void)? = nil
    ) {
        self.init(
            marker: marker,
            title: title,
            titleStyle: titleStyle,
            subtitle: subtitle,
            leadingSystemImage: leadingSystemImage,
            isSelected: isSelected,
            tint: tint,
            accessibilityIdentifier: accessibilityIdentifier,
            select: select,
            accessory: { EmptyView() })
    }
}
