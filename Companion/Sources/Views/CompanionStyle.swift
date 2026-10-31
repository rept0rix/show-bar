import SwiftUI

enum CompanionStyle {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.065)
    static let surface = Color(red: 0.085, green: 0.10, blue: 0.115)
    static let yellow = Color(red: 0.98, green: 0.88, blue: 0.31)
    static let cyan = Color(red: 0.34, green: 0.86, blue: 0.91)
    static let secondary = Color(red: 0.61, green: 0.66, blue: 0.70)
}

struct ShelfCard<Content: View>: View {
    var accent: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(accent ? CompanionStyle.yellow.opacity(0.7) : Color.white.opacity(0.065), lineWidth: 1)
            }
    }
}

struct ShelfSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(CompanionStyle.secondary)
            }
        }
    }
}

struct ShelfEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 35, weight: .light))
                .foregroundStyle(CompanionStyle.cyan)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(CompanionStyle.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PermissionNote: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(CompanionStyle.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(CompanionStyle.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionStyle.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}
