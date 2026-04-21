/*
 solink-protocol.h — SOLink shared protocol definition
 ======================================================
 Shared between publisher (OBS plugin) and subscriber (SyphonOut).
 MUST NOT include any OBS or platform-specific headers here —
 this header is included by both C (OBS plugin) and ObjC (SyphonOut).

 Zero-copy transport model
 ─────────────────────────
 1. Publisher creates SOLINK_BUFFER_COUNT IOSurfaces (triple buffer).
 2. Publisher mmap-opens a POSIX shared memory region (name from solink_shm_name()).
 3. Publisher writes the latest frame into SOLinkHeader via atomic ops.
 4. Subscriber opens the same shm read-only, polls frame_counter on its
    CVDisplayLink tick. When frame_counter changes, subscriber calls
    IOSurfaceLookup(ids[current_index]) and hands the IOSurfaceRef to Metal
    — zero CPU copy.

 Discovery
 ─────────
 NSDistributedNotificationCenter broadcasts lifecycle events.
 All notification names and userInfo keys are defined below.
 Frames are NOT signalled per-frame — subscriber polls (no IPC per frame).

 Reliability
 ───────────
 • publisher_pid == 0  → publisher exited cleanly.
 • timestamp_ns not updated for > SOLINK_LIVENESS_TIMEOUT_NS → crash/hang.
 • In both cases subscriber shows "No Signal".
 • Multiple subscribers can mmap the same shm read-only simultaneously.
 • Multiple publishers each have their own UUID and independent shm regions.

 Memory layout (128 bytes = 2 cache lines)
 ──────────────────────────────────────────
 Offset   Size  Field
 0        4     magic
 4        4     version
 8        4     width
 12       4     height
 16       4     pixel_format
 20       4     buffer_count
 24       12    iosurface_ids[3]
 36       4     _pad0
 40       8     frame_counter   (_Atomic)
 48       4     current_index   (_Atomic)
 52       4     publisher_pid   (_Atomic)
 56       8     timestamp_ns    (_Atomic)
 64       32    server_name     (utf-8)
 96       16    app_name        (utf-8)
 112      16    _reserved
 ──────────────
 128 bytes total
*/

#pragma once

#include <stdint.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Version / magic ────────────────────────────────────────────────────────

/// 'SLNK' in little-endian
#define SOLINK_MAGIC   0x4B4E4C53u
#define SOLINK_VERSION 1u

// ─── Triple-buffer pool ─────────────────────────────────────────────────────

/// Number of IOSurfaces in the circular pool.
/// Triple buffer: publisher always writes to (current+1)%N,
/// subscriber reads current — they never collide.
#define SOLINK_BUFFER_COUNT 3u

// ─── Pixel formats (mirrors MTLPixelFormat values) ──────────────────────────

/// BGRA 8-bit — default OBS output format on macOS.
#define SOLINK_PIXEL_FORMAT_BGRA8 80u
/// RGBA 8-bit — alternate.
#define SOLINK_PIXEL_FORMAT_RGBA8 70u

// ─── Shared memory path ─────────────────────────────────────────────────────

/// Maximum length of the shm name including null terminator.
/// macOS PSHMNAMLEN = 31 (name without leading slash).
/// Full buffer including slash and NUL: 33 bytes.
#define SOLINK_SHM_NAME_MAX 33u

/// Build the POSIX shm_open name from a UUID string.
/// macOS restricts shm names to 31 chars (without leading slash).
///
/// Strategy: "/slnk-" (6 chars) + first 25 chars of UUID = 31 chars + NUL.
/// Example UUID "422D73FE-0831-441A-A862-0C7605891DC4"
/// → "/slnk-422D73FE-0831-441A-A862-0" (32 chars total, 31 without slash)
///
/// 25 chars of UUID still covers the first 20 hex digits — 80 bits of entropy.
/// Collision probability on a single machine: negligible.
static inline void solink_shm_name(const char *uuid,
                                   char out[SOLINK_SHM_NAME_MAX]) {
    const char prefix[] = "/slnk-";
    unsigned int i = 0, pi = 0;
    while (prefix[pi] && i < SOLINK_SHM_NAME_MAX - 1u) out[i++] = prefix[pi++];
    /* Append exactly 25 chars of UUID (covers all uniqueness we need) */
    unsigned int uuid_chars = 0;
    const char *p = uuid;
    while (*p && i < SOLINK_SHM_NAME_MAX - 1u && uuid_chars < 25u) {
        out[i++] = *p++;
        uuid_chars++;
    }
    out[i] = '\0';
}

// ─── Shared memory layout ───────────────────────────────────────────────────

/// Placed at offset 0 of the POSIX shared memory region.
/// Exactly 128 bytes (2 cache lines).
typedef struct SOLinkHeader {

    // ── Static fields — written once at publisher init ─────────────────────

    uint32_t magic;                         ///< SOLINK_MAGIC sanity check
    uint32_t version;                       ///< SOLINK_VERSION
    uint32_t width;                         ///< Frame width  in pixels
    uint32_t height;                        ///< Frame height in pixels
    uint32_t pixel_format;                  ///< SOLINK_PIXEL_FORMAT_*
    uint32_t buffer_count;                  ///< Always SOLINK_BUFFER_COUNT

    /// IOSurface global IDs — one per buffer slot.
    /// Written once at publisher init. Subscriber calls IOSurfaceLookup(id).
    uint32_t iosurface_ids[SOLINK_BUFFER_COUNT];

    uint32_t _pad0;                         ///< align next field to 8 bytes

    // ── Dynamic fields — updated every frame via atomic ops ───────────────

    /// Monotonically increasing frame counter.
    /// Publisher: atomic_fetch_add(&hdr->frame_counter, 1) AFTER writing slot.
    /// Subscriber: compare to last seen; if changed, read current_index.
    _Atomic uint64_t frame_counter;

    /// Index (0–2) of the most recently completed buffer.
    /// Subscriber reads iosurface_ids[current_index] for the latest frame.
    _Atomic uint32_t current_index;

    /// Publisher process ID. Set to 0 in atexit handler (clean shutdown).
    _Atomic uint32_t publisher_pid;

    /// Monotonic clock timestamp of the last frame, in nanoseconds.
    /// Subscriber uses this for liveness detection (SOLINK_LIVENESS_TIMEOUT_NS).
    _Atomic uint64_t timestamp_ns;

    // ── Metadata — written once at init, read-only for subscriber ─────────

    /// Human-readable server name, null-terminated UTF-8.
    /// Same as SOLinkKeyName in the announce notification.
    char server_name[32];

    /// Publisher application name, null-terminated UTF-8.
    char app_name[16];

    uint8_t _reserved[16];                  ///< reserved for future use, zero-init

} SOLinkHeader;

_Static_assert(sizeof(SOLinkHeader) == 128,
    "SOLinkHeader must be 128 bytes — check padding if fields change");

/* Verify shm name fits macOS PSHMNAMLEN=31 limit:
   "/slnk-" (6) + 25 UUID chars + NUL = 32 bytes in buffer, 31 chars after slash. */
_Static_assert(SOLINK_SHM_NAME_MAX == 33u,
    "SOLINK_SHM_NAME_MAX must be 33 (32 chars + NUL) to satisfy macOS PSHMNAMLEN=31");

// ─── Liveness timeout ───────────────────────────────────────────────────────

/// If timestamp_ns has not advanced for this long, subscriber declares NO_SIGNAL.
#define SOLINK_LIVENESS_TIMEOUT_NS  500000000ULL   /* 500 ms */

// ─── Discovery — NSDistributedNotificationCenter notification names ──────────

/// New SOLink publisher available. userInfo: see SOLINK_KEY_* below.
#define SOLINK_NOTIF_ANNOUNCE   "SOLinkServerAnnounce"

/// Publisher going away (clean exit). userInfo: {SOLINK_KEY_UUID}.
#define SOLINK_NOTIF_RETIRE     "SOLinkServerRetire"

/// Subscriber starting up — publishers reply with a fresh Announce.
/// Allows late-joining subscribers to discover already-running publishers.
#define SOLINK_NOTIF_ENUMERATE  "SOLinkServerEnumerate"

// ─── Discovery — userInfo dictionary keys ───────────────────────────────────

/// NSString. Stable UUID for this publisher instance.
#define SOLINK_KEY_UUID         "SOLinkUUID"
/// NSString. Human-readable server name (e.g. "Main Scene").
#define SOLINK_KEY_NAME         "SOLinkName"
/// NSString. Application name (e.g. "OBS").
#define SOLINK_KEY_APP_NAME     "SOLinkAppName"
/// NSString. POSIX shm name as passed to shm_open (e.g. "/solink-<uuid>").
#define SOLINK_KEY_SHM_NAME     "SOLinkShmName"
/// NSNumber (uint32_t). Frame width in pixels.
#define SOLINK_KEY_WIDTH        "SOLinkWidth"
/// NSNumber (uint32_t). Frame height in pixels.
#define SOLINK_KEY_HEIGHT       "SOLinkHeight"
/// NSNumber (uint32_t). SOLINK_PIXEL_FORMAT_* value.
#define SOLINK_KEY_PIXEL_FORMAT "SOLinkPixelFormat"

#ifdef __cplusplus
}
#endif
