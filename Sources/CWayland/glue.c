#define _GNU_SOURCE
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "CWayland.h"

const struct wl_interface *nsx_interface(const char *name) {
    static const struct {
        const char *name;
        const struct wl_interface *interface;
    } known[] = {
        { "wl_compositor", &wl_compositor_interface },
        { "wl_shm", &wl_shm_interface },
        { "wl_seat", &wl_seat_interface },
        { "wl_output", &wl_output_interface },
        { "xdg_wm_base", &xdg_wm_base_interface },
        { "zxdg_decoration_manager_v1", &zxdg_decoration_manager_v1_interface },
        { "wp_fractional_scale_manager_v1", &wp_fractional_scale_manager_v1_interface },
        { "wp_viewporter", &wp_viewporter_interface },
    };
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++)
        if (strcmp(known[i].name, name) == 0)
            return known[i].interface;
    return NULL;
}

int nsx_shm_file(size_t size) {
    int fd = memfd_create("nsxiv-mac", MFD_CLOEXEC);
    if (fd >= 0 && ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}
