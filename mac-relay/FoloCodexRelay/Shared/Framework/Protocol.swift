import Foundation

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - Codex Relay wire protocol v2 constants

/// byte1 ("kind") of every DATA-characteristic frame, Mac -> device.
enum RelayKind {
    static let workspaceItem: UInt8 = 0
    static let sessionItem: UInt8 = 1
    static let pageUser: UInt8 = 2
    static let pageAssistant: UInt8 = 3
    static let status: UInt8 = 4
    /// Pinned on the device until the user presses a key to dismiss it (unlike `status`,
    /// which the device's 1s auto-refresh can silently overwrite within a second) --
    /// see CODEX_KIND_ERROR / s_error_pinned in demo_codex.c.
    static let error: UInt8 = 5
}

/// byte0 ("flags") of every DATA-characteristic frame.
enum RelayFlags {
    static let start: UInt8 = 0x01
    static let end: UInt8 = 0x02
}

/// byte0 ("req") of every CMD-characteristic frame, device -> Mac.
enum CmdReq {
    static let activeSession: UInt8 = 0
    static let listWorkspaces: UInt8 = 1
    static let listSessions: UInt8 = 2
    static let openSession: UInt8 = 3
    static let page: UInt8 = 4
}

/// byte1 ("kind") of every App Store DATA-characteristic frame -- independent numbering
/// from RelayKind above (different service, see main/demo_appstore.c).
enum AppStoreKind {
    static let item: UInt8 = 0
    static let firmware: UInt8 = 1
}

/// byte0 ("flags") of every App Store DATA-characteristic frame. Mirrors
/// APPSTORE_FLAG_* in main/demo_appstore.c -- keep both sides in sync.
enum AppStoreFlag {
    /// First chunk of a logical message (catalog item) / of the whole firmware stream.
    static let start: UInt8 = 0x01
    /// Last chunk of a logical message / of the whole firmware stream.
    static let end: UInt8 = 0x02
    /// Last chunk of ONE send batch -- the device reports its progress exactly when it
    /// finishes writing a chunk carrying this, so each batch produces exactly one ack
    /// whose count lands precisely on the batch boundary. Set at send time (batch
    /// boundaries depend on what's confirmed right then), not when framing the chunks.
    ///
    /// The device cannot derive this moment on its own -- both attempts failed, and both
    /// ended up SLOWER than not batching at all: acking on a fixed multiple of chunks
    /// written drifts out of alignment the moment a duplicate re-ack shifts the count
    /// (observed: batch 2881..<2945 vs. device only ever acking at 2944), leaving every
    /// batch to crawl forward via the 5s retry timeout; and acking whenever the device's
    /// OTA write queue drains degenerates into one ack per chunk, because flash writes
    /// far outpace BLE delivery -- and an indication is a full acknowledged ATT
    /// transaction, so that is exactly the per-chunk round trip batching exists to avoid.
    static let batchEnd: UInt8 = 0x04
}

/// byte0 ("req") of every App Store CMD-characteristic frame, device -> Mac. Values 0-1
/// are real requests; installAborted (2) is a device-initiated notification, not a
/// request -- the device sends it the instant an install attempt fails (bad partition,
/// esp_ota_begin/write error), rather than making the Mac push its remaining thousands of
/// queued chunks all the way to the end before finding out. See main/demo_appstore.c's
/// APPSTORE_EVT_INSTALL_ABORTED.
enum AppStoreCmdReq {
    static let listApps: UInt8 = 0
    static let installApp: UInt8 = 1
    static let installAborted: UInt8 = 2
    /// Device-initiated notification (not a request): "I've actually written N chunks so
    /// far" -- little-endian u16 packed into a/b, since the count can run into the
    /// thousands. Sent every APPSTORE_PROGRESS_BATCH chunks, on a duplicate/replay chunk
    /// (lets a retry stop early), and once right after a CMD re-subscribe if an install
    /// was already in progress (BLE-level reconnect mid-transfer). See
    /// main/demo_appstore.c's APPSTORE_EVT_PROGRESS and AppStoreModel.handleProgressAck.
    static let progress: UInt8 = 3
}

