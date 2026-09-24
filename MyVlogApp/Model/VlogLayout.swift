import SwiftUI

/// Layout/render constants shared between preview and export.
/// 定数テーブルで可変状態を持たないため、@MainActorがプロジェクト全体の既定
/// （SWIFT_DEFAULT_ACTOR_ISOLATION）になっていても、どのactorからでも
/// awaitなしで安全に参照できるようnonisolatedにしてある
/// （ExportWorkerなど@MainActor以外のactorから参照するため）
nonisolated enum VlogLayout {
    static let canvasWidth:  CGFloat = 1920
    static let canvasHeight: CGFloat = 1080
    static let canvasSize: CGSize = CGSize(width: canvasWidth, height: canvasHeight)
    static let hitokotoFontSize:  CGFloat = 70
    static let hitokotoLineGap:   CGFloat = 10
    static let timestampFontSize: CGFloat = 60
    static let timestampRightPad: CGFloat = 40
    /// ひとことを自動で折り返す幅（キャンバス上）。中央に置くので、左右に(1920-この幅)/2ずつ空く。
    /// 右端の撮影時刻（右余白40＋「22:31」の幅で約200）に重ならないよう、左右とも260空けている。
    /// 折り返さなかった頃は、長いひとことが撮影時刻に重なり、さらに長いと画面の外で切れていた。
    /// 撮影時刻の文字の大きさや余白を変えたら、ここも見直すこと（Android: HITOKOTO_WRAP_WIDTH_PT）
    static let hitokotoWrapWidth: CGFloat = 1400
    static let titleVlogFontSize: CGFloat = 150
    static let titleDateFontSize: CGFloat = 50
    static let titleVlogYOffset:  CGFloat = -70
    static let titleDateYOffset:  CGFloat = 80
    /// タイトルカードの文言が複数行になったときの行間。Android: TITLE_DATE_LINE_SPACING_PT
    static let titleDateLineSpacing: CGFloat = 10
    static let titleCardDuration: Double  = 2.0
    /// タイトルカードのSFXを鳴らし始めるフレーム番号（1始まり、30fps）。Android: TITLE_SFX_FRAME_NUMBER
    static let titleSfxFrameNumber: Int = 21
    /// タイトルカードのフェードアウトが始まるフレーム番号（0始まり）。Android: FADE_START_FRAME
    static let titleFadeStartFrame: Int = 30
    /// フェードアウトにかけるフレーム数。Android: FADE_FRAME_COUNT
    static let titleFadeFrameCount: Int = 20

    /// Android: TOOLBAR_BUTTON_SIZE / TOOLBAR_ICON_SIZE
    static let toolbarButtonSize: CGFloat = 48
    static let toolbarIconSize:   CGFloat = 20

    /// タイムラインに置けるクリップ数の上限。追加時と書き出し前の両方で守る（Android: MAX_CLIPS）。
    ///
    /// 数値はAndroid版と揃えてあるが、理由は違う。あちらは全クリップを1回のFFmpeg呼び出しへ
    /// 同時に入力するためメモリが本数に比例する。iOSはクリップを1本ずつ処理するものの、
    /// 最後のconcatenateで全ファイルを1つのAVMutableCompositionへ載せるため、
    /// 本数が増えるほど結合時のトラック数とファイルハンドルが増える。
    static let maxClips: Int = 100

    /// 一時保存できる件数の上限（Android: ClipStore.MAX_PROJECTS）。
    /// UserDefaultsへ全件を1つのJSONで持つため際限なくは増やさない
    static let maxSavedProjects: Int = 20

    /// 動画を追加するとき、メタデータ（長さ・撮影時刻）の取得を同時に走らせる本数の上限
    /// （Android: METADATA_PARALLELISM）。
    /// 絞らないと、選んだ本数ぶんのタスクがディスクI/Oとデコードでスレッドを食い合う。
    static let metadataParallelism: Int = 4

    /// 「ひとこと」複数行ブロックの先頭行の上端Y（キャンバス上下中央に配置）。
    /// PreviewView（SwiftUI描画）とExportWorker+Drawing（CGContext描画）の両方で使う、
    /// 数値としては完全に同一の計算（過去にここがズレて「プレビューと書き出しの
    /// 黒帯基準ズレ」という不具合になったことがあるため、1箇所にまとめている）。
    ///
    /// 各行は「高さlineHeightのスロットに収めて中央寄せ」という前提の式にしてある
    /// （呼び出し側は各行の中心をtopY + idx*lineHeight + lineHeight/2で求めること。
    /// PreviewView.hitokotoOverlay/ExportWorker+Drawing.drawHitokotoの両方がこの前提）。
    /// 以前はtotalHeightから最後の行ぶんのlineGapを引いていたが、これだとブロック全体が
    /// Android版（各行を`(idx-(n-1)/2)*lineHeight`という対称オフセットでキャンバス中央から
    /// 配置する方式）よりlineGap/2ぶん下にズレる。lineGapを引かない（=lineHeight*lineCount）
    /// ことで、この対称オフセット方式と数式レベルで一致する。
    static func hitokotoBlockTop(lineCount: Int, canvasHeight: CGFloat, fontSize: CGFloat, lineGap: CGFloat) -> CGFloat {
        guard lineCount > 0 else { return canvasHeight * 0.5 }
        let lineHeight = fontSize + lineGap
        let totalHeight = lineHeight * CGFloat(lineCount)
        return canvasHeight * 0.5 - totalHeight / 2
    }

    /// ひとこと・タイトルを行に分ける。空行も1行として残す（Android: String.lines()）。
    ///
    /// `split(separator: "\n")`では足りない。Swiftでは"\r\n"が1つのCharacterなので"\n"と
    /// 一致せず、貼り付けた文字の\r\nでは行が分かれない。分かれないまま1行ぶんの枠に
    /// 描くと、UIKit/SwiftUIは中の\r\n（単独の\rも）で折り返すため、2行が1行の高さに
    /// 押し込まれて、ブロックの中央揃えも崩れる。プレビューと書き出しの両方がここを通る
    static func captionLines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            .map(String.init)
    }
}
