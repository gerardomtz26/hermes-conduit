import SwiftUI

/// Shared title and close affordance for full-height sheets.
///
/// On iOS 26 the strip is Liquid Glass: the sheet's content slides beneath
/// it like a system navigation bar instead of meeting an opaque `.bar`
/// material. Earlier systems keep that exact `.bar` fill — same frame, same
/// covered area, only the material differs.
struct ConduitSheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .conduitGlassControl(cornerRadius: 18)
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(headerBackground)
    }

    @ViewBuilder
    private var headerBackground: some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Rectangle()
                .fill(.bar)
        }
    }
}
