"""Publish a staged bundle or disk image atomically on the same macOS filesystem."""

import ctypes
import errno
import os
import sys

RENAME_EXCL = 0x00000004  # Darwin <sys/stdio.h>

source, destination = map(os.fsencode, sys.argv[1:])
rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
rename.restype = ctypes.c_int
if rename(source, destination, RENAME_EXCL) != 0:
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        sys.exit(f"已有交付产物：{os.fsdecode(destination)}")
    sys.exit(f"交付失败：{os.fsdecode(destination)}（{os.strerror(error)}）")
