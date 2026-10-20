import MountagentDeskKit
import AppKit
import UniformTypeIdentifiers

/// Images pasted or dropped into the composer, stored as files Mountagent Desk owns so the
/// transcript can show them later. Large images are scaled down to fit Claude's limits.
enum ImageAttachments {
    static var directory: URL {
        ProjectStore.defaultRoot().appendingPathComponent("attachments", isDirectory: true)
    }

    private static let maxSide: CGFloat = 2048
    private static let maxBytes = 3_500_000

    /// What the clipboard holds that the composer should take instead of text.
    struct Pasted {
        var images: [URL] = []
        var files: [URL] = []
        var isEmpty: Bool { images.isEmpty && files.isEmpty }
    }

    static func read(_ pasteboard: NSPasteboard = .general) -> Pasted {
        var pasted = Pasted()
        // Files copied in Finder: images become attachments, other files are mentioned.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                if isImage(url), let saved = importImage(at: url) {
                    pasted.images.append(saved)
                } else {
                    pasted.files.append(url)
                }
            }
            return pasted
        }
        // Screenshots and images copied from apps or browsers.
        if let image = NSImage(pasteboard: pasteboard), let saved = save(image) {
            pasted.images.append(saved)
        }
        return pasted
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func importImage(at url: URL) -> URL? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        // Small PNG/JPEG files go in as they are.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes,
           ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()),
           max(image.pixelSize.width, image.pixelSize.height) <= maxSide {
            let target = newURL(extension: url.pathExtension.lowercased())
            return (try? FileManager.default.copyItem(at: url, to: target)).map { target }
        }
        return save(image)
    }

    /// Writes PNG, or JPEG when the PNG would be too large, scaling down past 2048px.
    static func save(_ image: NSImage) -> URL? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(source.width, source.height)))
        let width = Int(CGFloat(source.width) * scale), height = Int(CGFloat(source.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        var data = rep.representation(using: .png, properties: [:])
        var ext = "png"
        if (data?.count ?? 0) > maxBytes {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            ext = "jpg"
        }
        guard let data else { return nil }
        let url = newURL(extension: ext)
        return (try? data.write(to: url)).map { url }
    }

    private static func newURL(extension ext: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        return directory.appendingPathComponent("image-\(stamp)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}

private extension NSImage {
    var pixelSize: CGSize {
        guard let rep = representations.first else { return size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// Lets ⌘V in the composer take images and files, which a plain-text editor would drop.
/// A local key monitor sees the shortcut before the text view does; text pastes pass through.
@MainActor
final class ComposerPasteRouter {
    #if DEBUG
    /// The router of the composer on screen (debug hooks paste through it).
    static weak var current: ComposerPasteRouter?
    #endif
    var isFocused = false
    var onPaste: ((ImageAttachments.Pasted) -> Void)?
    private var monitor: Any?

    func install() {
        #if DEBUG
        Self.current = self
        #endif
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard self.isFocused, Self.clipboardHasMedia else { return false }
                let pasted = ImageAttachments.read()
                guard !pasted.isEmpty else { return false }
                self.onPaste?(pasted)
                return true
            }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static var clipboardHasMedia: Bool {
        let types = NSPasteboard.general.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
            || NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}

/// Puts text on the general pasteboard, replacing what was there.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Cursor editor app, for "Open in Cursor". `nil` when it isn't installed.
enum CursorApp {
    private static let bundleID = "com.todesktop.230313mzl4w4u92"

    static var isInstalled: Bool { location != nil }

    static func open(_ urls: [URL]) {
        guard let location else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: location, configuration: NSWorkspace.OpenConfiguration())
    }

    private static var location: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
