#pragma once

#include <removefile.h>

// Older SDKs do not expose removefile.h through Swift's Darwin module.
static inline void ezntfs_remove_partial_directory(int parent, const char *name) {
    (void)removefileat(parent, name, 0, REMOVEFILE_RECURSIVE);
}
