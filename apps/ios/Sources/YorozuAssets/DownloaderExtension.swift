import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Lets the system fetch Yorozu's Apple-hosted asset packs (the voice model). The app asks for the pack
/// on demand; this extension only has to exist.
@main
struct DownloaderExtension: StoreDownloaderExtension {}
