import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if !TESTING
@main
#endif
@MainActor
struct LeafApp: App {
    @StateObject private var appState: AppState
    private let wallpaperScheduler: WallpaperScheduler

    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let mountListener: VolumeWatcher.MountListener?
    private let mtpWatcher: MTPKindleWatcher?
    #endif

    init() {
        Self.pruneStaleWallpaperHistoryIfNeeded()

        let appState = Self.makeAppState()
        _appState = StateObject(wrappedValue: appState)

        wallpaperScheduler = WallpaperScheduler(rotateWallpaper: { [weak appState] in
            guard let appState else {
                return false
            }
            return appState.requestWallpaperRotationSynchronously()
        })

        #if canImport(AppKit)
        mountListener = Self.makeMountListener(appState: appState)
        mtpWatcher = Self.makeMTPWatcher(appState: appState)
        appDelegate.configure(appState: appState)
        #endif
    }

    var body: some Scene {
        Settings {
            SettingsView(navigationModel: SettingsNavigationModel())
                .environmentObject(appState)
        }
    }

    private static func makeAppState() -> AppState {
        #if canImport(GRDB)
        return AppState.live()
        #else
        return AppState(
            pickNextHighlight: { nil },
            loadBackgroundImageURLs: { [] },
            generateWallpaper: { _, _ in
                URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("leaf-placeholder-wallpaper.png")
            },
            setWallpaper: { _ in },
            markHighlightShown: { _ in }
        )
        #endif
    }

    nonisolated private static func pruneStaleWallpaperHistoryIfNeeded(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        indexPlistURL: URL? = nil,
        leafDirectoryURL: URL? = nil
    ) {
        guard !userDefaults.didPruneStaleWallpaperHistory else {
            return
        }

        defer {
            userDefaults.didPruneStaleWallpaperHistory = true
        }

        let pruner = WallpaperHistoryPruner(
            fileManager: fileManager,
            indexPlistURL: indexPlistURL
        )
        let stalePaths = pruner.staleLeafPNGPaths(
            leafDirectoryURL: leafDirectoryURL ?? AppSupportPaths.leafDirectory(fileManager: fileManager)
        )
        pruner.prune(pathsToPrune: stalePaths)
    }

    #if canImport(AppKit)
    private static func importStatusPublisher(appState: AppState) -> VolumeWatcher.PublishImportStatus {
        { status in
            Task { @MainActor in
                appState.setImportStatus(
                    AppState.ImportStatus(
                        message: status.message,
                        isError: status.isError,
                        warningDetails: status.warningDetails
                    )
                )
            }
        }
    }

    private static func makeMountListener(appState: AppState) -> VolumeWatcher.MountListener? {
        let publishImportStatusOnMain = importStatusPublisher(appState: appState)

        #if canImport(GRDB)
        let listener = VolumeWatcher.MountListener.live(
            publishImportStatus: publishImportStatusOnMain,
            applyLibrarySnapshot: { snapshot in
                Task { @MainActor in
                    appState.applyLibrarySnapshot(snapshot)
                }
            }
        )
        #else
        let listener = VolumeWatcher.MountListener(
            importFile: { _ in
                VolumeWatcher.ImportPayload(
                    newHighlightCount: 0,
                    error: nil,
                    skippedEntryCount: 0,
                    warningMessages: []
                )
            },
            publishImportStatus: publishImportStatusOnMain
        )
        #endif

        listener.start()
        return listener
    }

    private static func makeMTPWatcher(appState: AppState) -> MTPKindleWatcher? {
        #if canImport(GRDB) && !TESTING
        let helper = MTPHelperProcess.bundled
        let publish = importStatusPublisher(appState: appState)
        let service = MTPImportService(
            download: { id, file in _ = try helper.run(["download", id, file.path]) },
            importFile: { file in
                let result = ImportCoordinator.live.importFile(at: file)
                if let snapshot = result.librarySnapshot {
                    Task { @MainActor in appState.applyLibrarySnapshot(snapshot) }
                }
                return result
            }
        )
        let watcher = MTPKindleWatcher(
            helper: helper,
            prepare: { service.pruneStaleDownloads() },
            syncDevice: { id in
                let result = service.sync(id)
                publish(VolumeWatcher.makeImportStatus(from: VolumeWatcher.ImportPayload(
                    newHighlightCount: result.newHighlightCount, error: result.error,
                    skippedEntryCount: result.skippedEntryCount, warningMessages: result.warningMessages
                ), now: Date()))
            },
            reportError: { message in
                publish(VolumeWatcher.ImportStatus(message: message, isError: true, warningDetails: []))
            }
        )
        watcher.start()
        return watcher
        #else
        return nil
        #endif
    }

    #endif
}

#if TESTING
extension LeafApp {
    nonisolated static func testPruneStaleWallpaperHistoryIfNeeded(
        userDefaults: UserDefaults,
        fileManager: FileManager = .default,
        indexPlistURL: URL,
        leafDirectoryURL: URL
    ) {
        pruneStaleWallpaperHistoryIfNeeded(
            userDefaults: userDefaults,
            fileManager: fileManager,
            indexPlistURL: indexPlistURL,
            leafDirectoryURL: leafDirectoryURL
        )
    }
}
#endif
