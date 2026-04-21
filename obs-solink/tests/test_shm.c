/*
 test_shm.c — Standalone POSIX shared memory smoke test
 Compiles without OBS headers — mocks the minimal bits needed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <stdint.h>
#include <errno.h>

#include "../include/solink-protocol.h"

#define FAIL_IF(cond, msg) do { \
    if (cond) { \
        fprintf(stderr, "FAIL: %s (errno=%d %s)\n", msg, errno, strerror(errno)); \
        return 1; \
    } \
} while(0)

int main(void)
{
    printf("=== SOLink SHM Tests ===\n");

    const char *shm_name = "/slnk-test-shm-0001";
    const size_t shm_size = sizeof(SOLinkHeader);

    // ── Clean up any stale test shm ─────────────────────────────────────────
    shm_unlink(shm_name);

    // ── Create ──────────────────────────────────────────────────────────────
    printf("[test] shm_open create ... ");
    int fd = shm_open(shm_name, O_CREAT | O_RDWR, 0644);
    FAIL_IF(fd < 0, "shm_open failed");
    printf("PASS\n");

    printf("[test] ftruncate to %zu bytes ... ", shm_size);
    FAIL_IF(ftruncate(fd, (off_t)shm_size) < 0, "ftruncate failed");
    printf("PASS\n");

    printf("[test] mmap read-write ... ");
    SOLinkHeader *hdr = mmap(NULL, shm_size, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
    FAIL_IF(hdr == MAP_FAILED, "mmap failed");
    printf("PASS\n");

    // ── Init header ─────────────────────────────────────────────────────────
    printf("[test] init static fields ... ");
    memset(hdr, 0, shm_size);
    hdr->magic        = SOLINK_MAGIC;
    hdr->version      = SOLINK_VERSION;
    hdr->width        = 1920;
    hdr->height       = 1080;
    hdr->pixel_format = SOLINK_PIXEL_FORMAT_BGRA8;
    hdr->buffer_count = SOLINK_BUFFER_COUNT;
    hdr->iosurface_ids[0] = 101;
    hdr->iosurface_ids[1] = 102;
    hdr->iosurface_ids[2] = 103;
    snprintf(hdr->server_name, sizeof(hdr->server_name), "Test Server");
    snprintf(hdr->app_name,    sizeof(hdr->app_name),    "TestApp");

    atomic_store(&hdr->frame_counter, 0);
    atomic_store(&hdr->current_index, 0);
    atomic_store(&hdr->publisher_pid, (uint32_t)getpid());
    atomic_store(&hdr->timestamp_ns,  0);
    printf("PASS\n");

    // ── Read back static fields ─────────────────────────────────────────────
    printf("[test] verify static fields ... ");
    FAIL_IF(hdr->magic != SOLINK_MAGIC, "magic mismatch");
    FAIL_IF(hdr->version != SOLINK_VERSION, "version mismatch");
    FAIL_IF(hdr->width != 1920, "width mismatch");
    FAIL_IF(hdr->height != 1080, "height mismatch");
    FAIL_IF(hdr->pixel_format != SOLINK_PIXEL_FORMAT_BGRA8, "pixel_format mismatch");
    FAIL_IF(hdr->buffer_count != SOLINK_BUFFER_COUNT, "buffer_count mismatch");
    FAIL_IF(hdr->iosurface_ids[0] != 101, "iosurface_id[0] mismatch");
    FAIL_IF(strcmp(hdr->server_name, "Test Server") != 0, "server_name mismatch");
    printf("PASS\n");

    // ── Atomic publish loop ─────────────────────────────────────────────────
    printf("[test] atomic publish 100 frames ... ");
    for (int i = 0; i < 100; i++) {
        uint32_t next_idx = (uint32_t)(i % SOLINK_BUFFER_COUNT);
        atomic_store_explicit(&hdr->current_index, next_idx,
                              memory_order_release);
        uint64_t counter = atomic_fetch_add_explicit(
            &hdr->frame_counter, 1, memory_order_release);
        FAIL_IF(counter != (uint64_t)i,
                "frame_counter did not increment monotonically");
    }
    printf("PASS\n");

    printf("[test] final frame_counter == 100 ... ");
    uint64_t final_counter = atomic_load_explicit(
        &hdr->frame_counter, memory_order_relaxed);
    FAIL_IF(final_counter != 100, "final frame_counter != 100");
    printf("PASS\n");

    // ── Simulate publisher clean shutdown ───────────────────────────────────
    printf("[test] clean shutdown zeroes publisher_pid ... ");
    atomic_store(&hdr->publisher_pid, 0u);
    uint32_t pid_after = atomic_load(&hdr->publisher_pid);
    FAIL_IF(pid_after != 0, "publisher_pid not zero after shutdown");
    printf("PASS\n");

    // ── Cleanup ─────────────────────────────────────────────────────────────
    printf("[test] munmap + close + unlink ... ");
    FAIL_IF(munmap(hdr, shm_size) != 0, "munmap failed");
    close(fd);
    FAIL_IF(shm_unlink(shm_name) != 0, "shm_unlink failed");
    printf("PASS\n");

    printf("\nAll SHM tests passed.\n");
    return 0;
}
