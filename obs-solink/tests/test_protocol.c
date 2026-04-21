/*
 test_protocol.c — Verify SOLink protocol layout and helper functions
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>

#include "../include/solink-protocol.h"

#define FAIL_IF(cond, msg) do { \
    if (cond) { \
        fprintf(stderr, "FAIL: %s\n", msg); \
        return 1; \
    } \
} while(0)

int main(void)
{
    printf("=== SOLink Protocol Tests ===\n");

    // ── Layout ──────────────────────────────────────────────────────────────
    printf("[test] sizeof(SOLinkHeader) == 128 ... ");
    FAIL_IF(sizeof(SOLinkHeader) != 128,
            "SOLinkHeader size != 128 — padding/layout changed");
    printf("PASS\n");

    printf("[test] SOLINK_MAGIC value ... ");
    FAIL_IF(SOLINK_MAGIC != 0x4B4E4C53u,
            "SOLINK_MAGIC mismatch");
    printf("PASS\n");

    printf("[test] SOLINK_VERSION == 1 ... ");
    FAIL_IF(SOLINK_VERSION != 1u,
            "SOLINK_VERSION mismatch");
    printf("PASS\n");

    printf("[test] SOLINK_BUFFER_COUNT == 3 ... ");
    FAIL_IF(SOLINK_BUFFER_COUNT != 3u,
            "SOLINK_BUFFER_COUNT mismatch");
    printf("PASS\n");

    printf("[test] SOLINK_SHM_NAME_MAX == 33 ... ");
    FAIL_IF(SOLINK_SHM_NAME_MAX != 33u,
            "SOLINK_SHM_NAME_MAX mismatch");
    printf("PASS\n");

    // ── solink_shm_name truncation ──────────────────────────────────────────
    printf("[test] solink_shm_name truncates UUID to 25 chars ... ");
    {
        char buf[SOLINK_SHM_NAME_MAX];
        const char *full_uuid = "422D73FE-0831-441A-A862-0C7605891DC4";
        solink_shm_name(full_uuid, buf);

        size_t len = strlen(buf);
        FAIL_IF(buf[0] != '/', "shm name missing leading slash");
        FAIL_IF(strncmp(buf, "/slnk-", 6) != 0, "shm name wrong prefix");
        FAIL_IF(len > 32, "shm name too long for macOS PSHMNAMLEN");

        // Should be "/slnk-" + 25 chars + NUL = 32 chars total
        const char expected[] = "/slnk-422D73FE-0831-441A-A862-0";
        FAIL_IF(strcmp(buf, expected) != 0, "shm name content mismatch");
    }
    printf("PASS\n");

    printf("[test] solink_shm_name with short UUID ... ");
    {
        char buf[SOLINK_SHM_NAME_MAX];
        solink_shm_name("short", buf);
        FAIL_IF(strcmp(buf, "/slnk-short") != 0,
                "short UUID not handled correctly");
    }
    printf("PASS\n");

    // ── Pixel format values (must match Rust/MMetal) ────────────────────────
    printf("[test] pixel format constants ... ");
    FAIL_IF(SOLINK_PIXEL_FORMAT_BGRA8 != 80u,
            "SOLINK_PIXEL_FORMAT_BGRA8 must be 80 (matches MTLPixelFormatBGRA8Unorm)");
    FAIL_IF(SOLINK_PIXEL_FORMAT_RGBA8 != 70u,
            "SOLINK_PIXEL_FORMAT_RGBA8 must be 70 (matches MTLPixelFormatRGBA8Unorm)");
    printf("PASS\n");

    // ── Field offsets (regression guard) ────────────────────────────────────
    printf("[test] field offsets ... ");
    {
        SOLinkHeader hdr;
        memset(&hdr, 0, sizeof(hdr));

        FAIL_IF((uintptr_t)&hdr.magic != (uintptr_t)&hdr,
                "magic not at offset 0");
        FAIL_IF((uintptr_t)&hdr.version != (uintptr_t)&hdr + 4,
                "version not at offset 4");
        FAIL_IF((uintptr_t)&hdr.width != (uintptr_t)&hdr + 8,
                "width not at offset 8");
        FAIL_IF((uintptr_t)&hdr.height != (uintptr_t)&hdr + 12,
                "height not at offset 12");
        FAIL_IF((uintptr_t)&hdr.pixel_format != (uintptr_t)&hdr + 16,
                "pixel_format not at offset 16");
        FAIL_IF((uintptr_t)&hdr.buffer_count != (uintptr_t)&hdr + 20,
                "buffer_count not at offset 20");
        FAIL_IF((uintptr_t)&hdr.iosurface_ids != (uintptr_t)&hdr + 24,
                "iosurface_ids not at offset 24");
        FAIL_IF((uintptr_t)&hdr.frame_counter != (uintptr_t)&hdr + 40,
                "frame_counter not at offset 40");
        FAIL_IF((uintptr_t)&hdr.current_index != (uintptr_t)&hdr + 48,
                "current_index not at offset 48");
        FAIL_IF((uintptr_t)&hdr.publisher_pid != (uintptr_t)&hdr + 52,
                "publisher_pid not at offset 52");
        FAIL_IF((uintptr_t)&hdr.timestamp_ns != (uintptr_t)&hdr + 56,
                "timestamp_ns not at offset 56");
        FAIL_IF((uintptr_t)&hdr.server_name != (uintptr_t)&hdr + 64,
                "server_name not at offset 64");
        FAIL_IF((uintptr_t)&hdr.app_name != (uintptr_t)&hdr + 96,
                "app_name not at offset 96");
    }
    printf("PASS\n");

    printf("\nAll protocol tests passed.\n");
    return 0;
}
