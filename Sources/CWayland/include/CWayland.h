// libwayland, xkbcommon and the protocol glue wayland-scanner 1.26.0 generated from
// wayland-protocols 1.49 (client-header and private-code; regenerate rather than edit)
#include <wayland-client.h>
#include <wayland-cursor.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"

// The table for a registry interface name the viewer binds, or NULL. Swift copies
// imported const globals, and libwayland needs the tables themselves.
const struct wl_interface *nsx_interface(const char *name);

// An unlinked shared-memory file of the given size for wl_shm buffers, or -1.
int nsx_shm_file(size_t size);
