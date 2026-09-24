import SwiftUI

/// ライセンスの表示（Android: LicenseDialog）。保存ダイアログの「ライセンス」から開く。
///
/// 同梱のフォントの著作権表示を載せる（それぞれのフォントファイルの中の表記と同じ）。
/// M PLUS U は SIL Open Font License で、同梱して配るときは著作権表示とライセンスを添える必要がある。
/// タイトルの効果音（title.mp3）は表記の要らない素材なので載せていない。
///
/// Android版と違ってFFmpegは使っていない（書き出しはAVFoundation）ので、GPLの表示は要らない。
struct LicenseView: View {
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    static let notice = """
    MyVlog.
    Copyright (c) 2026 msmn1128

    このアプリは無保証です。商品性や特定の目的への適合性の保証を含め、いかなる保証もありません。

    フォント
    ・M PLUS U（撮影時刻・タイトルの文言）：Copyright 2025 The M+ FONTS Project Authors（https://github.com/coz-m/MPLUS_FONTS）。SIL Open Font License, Version 1.1（https://openfontlicense.org）
    ・07ロゴたいぷゴシック7（ひとこと・「Vlog.」）：Copyright (c) 2013 M+ FONTS PROJECT／フォントな（www.fontna.com）
    """

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("ライセンス")
                    .vlogFont(20, weight: .semibold)
                    .padding(.bottom, 16)

                ScrollView {
                    // URLを長押しでコピーできるようにする（リンクを開く仕組みは持たせていない）
                    Text(Self.notice)
                        .vlogFont(12)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)

                HStack {
                    Spacer()
                    Button("閉じる") { onDismiss() }
                        .foregroundStyle(AppColors.primary(colorScheme))
                        .vlogFont(14, weight: .semibold)
                }
                .padding(.top, 16)
            }
            .padding(24)
            .background(AppColors.cardHigh(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
            .accessibilityAddTraits(.isModal)
        }
    }
}
