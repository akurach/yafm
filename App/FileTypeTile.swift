import SwiftUI
import AppKit
import Core

/// Drawn filetype tile — the redesign's "name cell" leading glyph
/// (`design_handoff §6 Table`): a rounded square tinted by file-type *category*
/// with the extension in tiny mono. Known categories render as a colored chip;
/// unknown extensions (and folders) fall back to the real macOS icon. Toggleable
/// in Settings ▸ Appearance (`AppSettings.filetypeTiles`).
///
/// The category's color is resolved through `AppSettings` (override → default) so
/// it is the single source of truth for BOTH the tile and the optional name tint.
enum FileTypeCategory: String, CaseIterable, Identifiable {
    case image, raw, video, audio, pdf, doc, archive
    case code, model, design, data, font, binary
    case videoProject, audioProject

    var id: String { rawValue }

    /// Human label for the Settings category list.
    var displayName: String {
        switch self {
        case .image: "Image";  case .raw: "RAW photo";  case .video: "Video"
        case .audio: "Audio";  case .pdf: "PDF";        case .doc: "Document"
        case .archive: "Archive"; case .code: "Code";   case .model: "3D / CAD"
        case .design: "Design"; case .data: "Data";     case .font: "Font"
        case .binary: "Binary"; case .videoProject: "Video project"
        case .audioProject: "Audio / music project"
        }
    }

    /// Default sRGB — shared across light/dark. User overrides live in AppSettings.
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .image:        return (0.21, 0.72, 0.48)  // green
        case .raw:          return (0.18, 0.69, 0.66)  // teal  (photo RAW)
        case .video:        return (0.94, 0.35, 0.61)  // pink
        case .audio:        return (0.66, 0.40, 0.92)  // purple
        case .pdf:          return (0.94, 0.35, 0.29)  // red
        case .doc:          return (0.54, 0.58, 0.66)  // slate
        case .archive:      return (0.90, 0.65, 0.23)  // amber
        case .code:         return (0.56, 0.50, 0.95)  // violet
        case .model:        return (0.96, 0.55, 0.24)  // orange (3D)
        case .design:       return (0.86, 0.31, 0.74)  // magenta
        case .data:         return (0.29, 0.60, 0.95)  // blue
        case .font:         return (0.45, 0.46, 0.86)  // indigo
        case .binary:       return (0.78, 0.42, 0.34)  // brick
        case .videoProject: return (0.83, 0.27, 0.45)  // deep rose (NLE projects)
        case .audioProject: return (0.62, 0.74, 0.24)  // lime      (DAW projects)
        }
    }

    var nsTint: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
}

/// Built-in extension → (category, label). A dictionary (not a switch) so it can
/// be both looked up AND enumerated — the Settings type browser lists every entry,
/// grouped by category, so users can see what's already mapped (python? vcf?).
/// Catalog skews toward dev / geek / photographer / videographer / musician types.
enum FileTypeCatalog {
    static let map: [String: (category: FileTypeCategory, label: String)] = [
        // images
        "jpg": (.image, "JPG"), "jpeg": (.image, "JPG"), "png": (.image, "PNG"),
        "gif": (.image, "GIF"), "heic": (.image, "HEIC"), "heif": (.image, "HEIC"),
        "webp": (.image, "WEBP"), "avif": (.image, "AVIF"), "jxl": (.image, "JXL"),
        "bmp": (.image, "BMP"), "tif": (.image, "TIF"), "tiff": (.image, "TIF"),
        "svg": (.image, "SVG"), "ico": (.image, "ICO"),
        // RAW photo
        "raw": (.raw, "RAW"), "dng": (.raw, "DNG"), "cr2": (.raw, "CR2"), "cr3": (.raw, "CR3"),
        "nef": (.raw, "NEF"), "arw": (.raw, "ARW"), "raf": (.raw, "RAF"), "orf": (.raw, "ORF"),
        "rw2": (.raw, "RW2"), "pef": (.raw, "PEF"), "srw": (.raw, "SRW"), "nrw": (.raw, "NRW"),
        "x3f": (.raw, "X3F"),
        // video
        "mp4": (.video, "MP4"), "m4v": (.video, "MP4"), "mov": (.video, "MOV"),
        "avi": (.video, "AVI"), "mkv": (.video, "MKV"), "webm": (.video, "WEBM"),
        "flv": (.video, "FLV"), "wmv": (.video, "WMV"), "mpg": (.video, "MPG"), "mpeg": (.video, "MPG"),
        "m2ts": (.video, "M2TS"), "mts": (.video, "M2TS"), "vob": (.video, "VOB"),
        "ogv": (.video, "OGV"), "3gp": (.video, "3GP"),
        "braw": (.video, "BRAW"), "r3d": (.video, "R3D"), "ari": (.video, "ARRI"), "arri": (.video, "ARRI"),
        "mxf": (.video, "MXF"), "dpx": (.video, "DPX"), "exr": (.video, "EXR"),
        "cube": (.video, "LUT"), "3dl": (.video, "LUT"),
        "srt": (.video, "SRT"), "vtt": (.video, "SRT"), "ass": (.video, "SRT"), "ssa": (.video, "SRT"), "sub": (.video, "SRT"),
        // audio
        "mp3": (.audio, "MP3"), "wav": (.audio, "WAV"), "flac": (.audio, "FLAC"),
        "aac": (.audio, "AAC"), "m4a": (.audio, "M4A"), "m4b": (.audio, "M4B"),
        "ogg": (.audio, "OGG"), "oga": (.audio, "OGG"), "opus": (.audio, "OPUS"),
        "aiff": (.audio, "AIFF"), "aif": (.audio, "AIFF"), "aifc": (.audio, "AIFF"),
        "mid": (.audio, "MIDI"), "midi": (.audio, "MIDI"), "wma": (.audio, "WMA"),
        "caf": (.audio, "CAF"), "dsd": (.audio, "DSD"), "dsf": (.audio, "DSD"), "dff": (.audio, "DSD"),
        "ape": (.audio, "APE"), "wv": (.audio, "WV"), "au": (.audio, "AU"), "snd": (.audio, "AU"),
        "ac3": (.audio, "AC3"), "dts": (.audio, "DTS"), "mka": (.audio, "MKA"), "amr": (.audio, "AMR"),
        "sf2": (.audio, "SF2"), "sfz": (.audio, "SF2"),
        "nki": (.audio, "NKI"), "nkm": (.audio, "NKI"), "nkx": (.audio, "NKI"),
        "vst": (.audio, "VST"), "vst3": (.audio, "VST"), "fxp": (.audio, "FXP"), "fxb": (.audio, "FXP"),
        // pdf
        "pdf": (.pdf, "PDF"),
        // documents / office
        "doc": (.doc, "DOC"), "docx": (.doc, "DOC"), "txt": (.doc, "TXT"), "text": (.doc, "TXT"),
        "rtf": (.doc, "RTF"), "pages": (.doc, "PG"), "odt": (.doc, "ODT"),
        "xls": (.doc, "XLS"), "xlsx": (.doc, "XLS"), "numbers": (.doc, "NUM"),
        "ppt": (.doc, "PPT"), "pptx": (.doc, "PPT"), "key": (.doc, "KEY"),
        "epub": (.doc, "EPUB"), "tex": (.doc, "TEX"),
        // archives
        "zip": (.archive, "ZIP"), "rar": (.archive, "RAR"), "7z": (.archive, "7Z"),
        "tar": (.archive, "TAR"), "gz": (.archive, "GZ"), "tgz": (.archive, "GZ"),
        "bz2": (.archive, "BZ2"), "xz": (.archive, "XZ"), "zst": (.archive, "ZST"),
        "dmg": (.archive, "DMG"), "iso": (.archive, "ISO"), "pkg": (.archive, "PKG"), "jar": (.archive, "JAR"),
        // code
        "swift": (.code, "SWIFT"), "js": (.code, "JS"), "mjs": (.code, "JS"), "cjs": (.code, "JS"),
        "ts": (.code, "TS"), "jsx": (.code, "JSX"), "tsx": (.code, "TSX"),
        "py": (.code, "PY"), "pyw": (.code, "PY"), "rb": (.code, "RB"), "go": (.code, "GO"),
        "rs": (.code, "RS"), "c": (.code, "C"), "cpp": (.code, "CPP"), "cc": (.code, "CPP"), "cxx": (.code, "CPP"),
        "h": (.code, "H"), "hpp": (.code, "H"), "m": (.code, "M"), "mm": (.code, "MM"),
        "java": (.code, "JAVA"), "kt": (.code, "KT"), "kts": (.code, "KT"), "cs": (.code, "CS"),
        "php": (.code, "PHP"), "pl": (.code, "PL"), "pm": (.code, "PL"), "lua": (.code, "LUA"),
        "scala": (.code, "SCALA"), "sc": (.code, "SCALA"), "clj": (.code, "CLJ"), "cljs": (.code, "CLJ"),
        "ex": (.code, "EX"), "exs": (.code, "EX"), "dart": (.code, "DART"), "r": (.code, "R"),
        "jl": (.code, "JL"), "nim": (.code, "NIM"), "zig": (.code, "ZIG"), "hs": (.code, "HS"),
        "ml": (.code, "ML"), "mli": (.code, "ML"), "fs": (.code, "FS"), "fsx": (.code, "FS"),
        "sol": (.code, "SOL"), "vue": (.code, "VUE"), "svelte": (.code, "SVELTE"),
        "html": (.code, "HTML"), "htm": (.code, "HTML"),
        "css": (.code, "CSS"), "scss": (.code, "CSS"), "sass": (.code, "CSS"), "less": (.code, "CSS"),
        "sh": (.code, "SH"), "bash": (.code, "SH"), "zsh": (.code, "SH"), "fish": (.code, "SH"),
        "ps1": (.code, "PS1"), "bat": (.code, "BAT"), "cmd": (.code, "BAT"),
        "md": (.code, "MD"), "markdown": (.code, "MD"), "ipynb": (.code, "IPYNB"), "gradle": (.code, "GRD"),
        "asm": (.code, "ASM"), "s": (.code, "ASM"), "wat": (.code, "WAT"),
        "proto": (.code, "PROTO"), "graphql": (.code, "GQL"), "gql": (.code, "GQL"),
        "vcf": (.code, "VCF"),  // vCard (often hand-edited contact data)
        // data / config
        "json": (.data, "JSON"), "jsonc": (.data, "JSON"), "jsonl": (.data, "JSONL"), "ndjson": (.data, "JSONL"),
        "yaml": (.data, "YAML"), "yml": (.data, "YAML"), "toml": (.data, "TOML"), "xml": (.data, "XML"),
        "csv": (.data, "CSV"), "tsv": (.data, "TSV"), "sql": (.data, "SQL"),
        "db": (.data, "DB"), "sqlite": (.data, "DB"), "sqlite3": (.data, "DB"),
        "parquet": (.data, "PARQ"), "plist": (.data, "PLIST"),
        "ini": (.data, "CFG"), "cfg": (.data, "CFG"), "conf": (.data, "CFG"),
        "env": (.data, "ENV"), "lock": (.data, "LOCK"),
        // 3D / CAD
        "obj": (.model, "OBJ"), "fbx": (.model, "FBX"), "stl": (.model, "STL"),
        "gltf": (.model, "GLTF"), "glb": (.model, "GLB"), "blend": (.model, "BLEND"),
        "dae": (.model, "DAE"), "3ds": (.model, "3DS"),
        "usd": (.model, "USD"), "usda": (.model, "USD"), "usdc": (.model, "USD"), "usdz": (.model, "USD"),
        "ply": (.model, "PLY"), "abc": (.model, "ABC"), "c4d": (.model, "C4D"),
        "max": (.model, "MAX"), "ma": (.model, "MA"), "mb": (.model, "MB"), "3mf": (.model, "3MF"),
        "step": (.model, "STEP"), "stp": (.model, "STEP"), "igs": (.model, "IGES"), "iges": (.model, "IGES"),
        "dwg": (.model, "DWG"), "dxf": (.model, "DXF"), "skp": (.model, "SKP"),
        // design
        "psd": (.design, "PSD"), "psb": (.design, "PSD"), "ai": (.design, "AI"), "xd": (.design, "XD"),
        "fig": (.design, "FIG"), "sketch": (.design, "SK"), "afdesign": (.design, "AFD"),
        "afphoto": (.design, "AFP"), "indd": (.design, "INDD"), "eps": (.design, "EPS"),
        // fonts
        "ttf": (.font, "TTF"), "otf": (.font, "OTF"), "woff": (.font, "WOFF"),
        "woff2": (.font, "WOFF2"), "eot": (.font, "EOT"),
        // binaries
        "exe": (.binary, "EXE"), "bin": (.binary, "BIN"), "so": (.binary, "SO"),
        "dll": (.binary, "DLL"), "dylib": (.binary, "DYLIB"), "o": (.binary, "O"), "a": (.binary, "A"),
        "wasm": (.binary, "WASM"), "deb": (.binary, "DEB"), "rpm": (.binary, "RPM"), "class": (.binary, "CLASS"),
        // video-editing projects
        "prproj": (.videoProject, "PR"), "aep": (.videoProject, "AE"), "aepx": (.videoProject, "AE"),
        "drp": (.videoProject, "DRP"), "fcpxml": (.videoProject, "FCP"), "fcpbundle": (.videoProject, "FCP"),
        "veg": (.videoProject, "VEG"), "kdenlive": (.videoProject, "KDEN"),
        "mlt": (.videoProject, "MLT"), "imovieproj": (.videoProject, "IMOV"),
        // DAW / music projects + notation
        "als": (.audioProject, "ALS"), "flp": (.audioProject, "FLP"), "logicx": (.audioProject, "LOGIC"),
        "ptx": (.audioProject, "PT"), "ptf": (.audioProject, "PT"), "cpr": (.audioProject, "CPR"),
        "rpp": (.audioProject, "RPP"), "band": (.audioProject, "BAND"),
        "aup": (.audioProject, "AUP"), "aup3": (.audioProject, "AUP"),
        "song": (.audioProject, "RNS"), "reason": (.audioProject, "RNS"), "rns": (.audioProject, "RNS"),
        "bwproject": (.audioProject, "BW"), "sesx": (.audioProject, "SESX"),
        "mmp": (.audioProject, "LMMS"), "mmpz": (.audioProject, "LMMS"),
        "musicxml": (.audioProject, "MXML"), "mxl": (.audioProject, "MXML"),
        "mscz": (.audioProject, "MSCZ"), "mscx": (.audioProject, "MSCZ"),
        "gp": (.audioProject, "GP"), "gp5": (.audioProject, "GP"), "gp4": (.audioProject, "GP"), "gpx": (.audioProject, "GP"),
        "sib": (.audioProject, "SIB"),
    ]

    static func entry(forExtension ext: String) -> (FileTypeCategory, String)? {
        guard let hit = map[ext.lowercased()] else { return nil }
        return (hit.category, hit.label)
    }

    /// Extensions in a category, sorted — for the Settings type browser.
    static func extensions(in category: FileTypeCategory) -> [String] {
        map.filter { $0.value.category == category }.keys.sorted()
    }
}

/// Renders the tile to a cached `NSImage`. Drawing to a bitmap is deliberate:
/// a SwiftUI `Text` inside a fixed-size cell in every List row drove an Auto
/// Layout / layout-pass recursion in `NSHostingView` that hung and crashed on
/// large folders (Downloads). An `Image(nsImage:)` has a fixed intrinsic size
/// and cannot feed back into layout — the only loop-proof option. Cached by
/// (color, label, size, appearance) so a big folder draws each distinct tile once.
@MainActor
enum FileTypeTileRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(rgb: (r: CGFloat, g: CGFloat, b: CGFloat), label: String, size: CGFloat, isDark: Bool) -> NSImage {
        let key = "\(Int(rgb.r*255)),\(Int(rgb.g*255)),\(Int(rgb.b*255))|\(label)|\(Int(size.rounded()))|\(isDark)"
        if let hit = cache[key] { return hit }
        let img = render(rgb: rgb, label: label, size: size, isDark: isDark)
        cache[key] = img
        return img
    }

    private static func fontSize(_ label: String, _ size: CGFloat) -> CGFloat {
        switch label.count {
        case 0...2: return size * 0.46
        case 3:     return size * 0.40
        case 4:     return size * 0.31
        case 5:     return size * 0.26
        default:    return size * 0.22
        }
    }

    private static func render(rgb: (r: CGFloat, g: CGFloat, b: CGFloat), label: String, size: CGFloat, isDark: Bool) -> NSImage {
        let (r, g, b) = rgb
        let tint = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        // On a light row the bright tints (lime, amber, green) wash out as text, so
        // darken the label toward black for contrast; dark mode keeps the bright tint.
        let textColor = isDark ? tint : NSColor(srgbRed: r * 0.55, green: g * 0.55, blue: b * 0.55, alpha: 1)
        let fillAlpha: CGFloat = isDark ? 0.22 : 0.18
        let strokeAlpha: CGFloat = isDark ? 0.45 : 0.55
        let radius = size * 0.25
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: radius, yRadius: radius)
            tint.withAlphaComponent(fillAlpha).setFill()
            path.fill()
            tint.withAlphaComponent(strokeAlpha).setStroke()
            path.lineWidth = 1
            path.stroke()

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize(label, size), weight: .bold),
                .foregroundColor: textColor,
                .paragraphStyle: para,
            ]
            let str = label as NSString
            let textSize = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: (size - textSize.width) / 2,
                                 y: (size - textSize.height) / 2),
                     withAttributes: attrs)
            return true
        }
    }
}

/// Loop-proof tile: a cached bitmap shown as a fixed-size image (no SwiftUI
/// text layout participates, so it can never drive a per-row layout cycle).
struct FileTypeTile: View {
    @Environment(\.colorScheme) private var scheme
    let rgb: (r: CGFloat, g: CGFloat, b: CGFloat)
    let label: String
    var size: CGFloat = Theme.Col.icon

    var body: some View {
        Image(nsImage: FileTypeTileRenderer.image(rgb: rgb, label: label,
                                                  size: size, isDark: scheme == .dark))
            .frame(width: size, height: size)
    }
}
