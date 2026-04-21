/*
 solink-shm.c — POSIX shared memory (publisher side)
 =====================================================
 Creates the /solink-<uuid> shared memory region and keeps it updated
 every frame via lock-free atomic stores.

 Subscriber opens the same region read-only — no coordination needed.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <time.h>

#include <obs-module.h>

#include "solink-shm.h"
#include "solink-protocol.h"
#include "solink-surface-pool.h"

// ─── Internal struct ─────────────────────────────────────────────────────────

struct solink_shm {
    SOLinkHeader *header;       // mmap'd pointer to the shared header
    int           fd;           // file descriptor from shm_open
    char          name[SOLINK_SHM_NAME_MAX];
};

// ─── Monotonic clock (nanoseconds) ───────────────────────────────────────────

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_UPTIME_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// ─── Create ──────────────────────────────────────────────────────────────────

solink_shm_t *solink_shm_create(const char            *shm_name,
                                  solink_surface_pool_t *pool,
                                  uint32_t               width,
                                  uint32_t               height,
                                  uint32_t               pixel_format,
                                  const char            *server_name,
                                  const char            *app_name)
{
    // Unlink any stale shm from a previous crashed publisher
    shm_unlink(shm_name);

    int fd = shm_open(shm_name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        blog(LOG_ERROR, "[SOLink] shm_open('%s') failed", shm_name);
        return NULL;
    }

    if (ftruncate(fd, sizeof(SOLinkHeader)) < 0) {
        blog(LOG_ERROR, "[SOLink] ftruncate failed");
        close(fd);
        shm_unlink(shm_name);
        return NULL;
    }

    SOLinkHeader *hdr = mmap(NULL, sizeof(SOLinkHeader),
                              PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
    if (hdr == MAP_FAILED) {
        blog(LOG_ERROR, "[SOLink] mmap failed");
        close(fd);
        shm_unlink(shm_name);
        return NULL;
    }

    // Zero-init before writing — clears _reserved and any padding
    memset(hdr, 0, sizeof(SOLinkHeader));

    // Static fields (written once)
    hdr->magic        = SOLINK_MAGIC;
    hdr->version      = SOLINK_VERSION;
    hdr->width        = width;
    hdr->height       = height;
    hdr->pixel_format = pixel_format;
    hdr->buffer_count = SOLINK_BUFFER_COUNT;

    for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
        hdr->iosurface_ids[i] = solink_pool_iosurface_id(pool, i);
    }

    // Metadata
    snprintf(hdr->server_name, sizeof(hdr->server_name), "%s", server_name ? server_name : "");
    snprintf(hdr->app_name,    sizeof(hdr->app_name),    "%s", app_name    ? app_name    : "");

    // Dynamic fields — atomic stores
    atomic_store(&hdr->frame_counter,  0);
    atomic_store(&hdr->current_index,  0);
    atomic_store(&hdr->publisher_pid,  (uint32_t)getpid());
    atomic_store(&hdr->timestamp_ns,   now_ns());

    solink_shm_t *shm = calloc(1, sizeof(*shm));
    if (!shm) {
        munmap(hdr, sizeof(SOLinkHeader));
        close(fd);
        shm_unlink(shm_name);
        return NULL;
    }

    shm->header = hdr;
    shm->fd     = fd;
    strncpy(shm->name, shm_name, SOLINK_SHM_NAME_MAX - 1);

    blog(LOG_INFO, "[SOLink] shm created: %s (pid=%d)", shm_name, (int)getpid());
    return shm;
}

// ─── Publish frame ───────────────────────────────────────────────────────────

void solink_shm_publish_frame(solink_shm_t *shm, uint32_t next_idx)
{
    if (!shm || !shm->header) return;

    SOLinkHeader *hdr = shm->header;

    // Publish atomically:
    // 1. Write current_index BEFORE incrementing frame_counter.
    //    Subscriber: reads frame_counter first, then current_index.
    //    Both are atomic → subscriber always sees a consistent pair.
    atomic_store_explicit(&hdr->current_index, next_idx,
                          memory_order_release);
    atomic_fetch_add_explicit(&hdr->frame_counter, 1,
                               memory_order_release);
    atomic_store_explicit(&hdr->timestamp_ns, now_ns(),
                          memory_order_relaxed);
}

// ─── Destroy ─────────────────────────────────────────────────────────────────

void solink_shm_destroy(solink_shm_t *shm)
{
    if (!shm) return;

    if (shm->header) {
        // Signal clean shutdown to all subscribers
        atomic_store(&shm->header->publisher_pid, 0u);
        munmap(shm->header, sizeof(SOLinkHeader));
        shm->header = NULL;
    }

    if (shm->fd >= 0) {
        close(shm->fd);
        shm->fd = -1;
    }

    shm_unlink(shm->name);
    blog(LOG_INFO, "[SOLink] shm destroyed: %s", shm->name);
    free(shm);
}
