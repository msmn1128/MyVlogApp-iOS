import CoreText
import Foundation

/// Android版のassets/fonts配下と同じフォント（LogoTypeGothic.otf, MPLUSU-Regular.ttf）を
/// アプリバンドルから読み込み、CoreTextに登録して実際のフォント名を返す。
/// Info.plistのUIAppFontsに頼らず、プロセス単位でその場登録する（自動生成Info.plistは
/// 配列キーの追加がしづらいため）。
enum VlogFonts {
    /// タイトルロゴ・ひとこと字幕用（Android: LogoTypeGothic.otf）
    static let logoTypeName: String = register(resource: "LogoTypeGothic", ext: "otf")
    /// 撮影時刻用（Android: MPLUSU-Regular.ttf）
    static let timeFontName: String = register(resource: "MPLUSU-Regular", ext: "ttf")

    private static func register(resource: String, ext: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
            assertionFailure("font resource not found: \(resource).\(ext)")
            return "System"
        }

        var resolvedName = resource
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first,
           let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
            resolvedName = postScriptName
        }

        var errorRef: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
        return resolvedName
    }
}
