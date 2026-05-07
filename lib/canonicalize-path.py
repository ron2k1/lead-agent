#!/usr/bin/env python3
# canonicalize-path.py v1.0 (DESIGN.md s12.3 + B3 v0.4 + SE-R2 v0.4 + EC-5 v0.6).
#
# Six-step canonicalization pipeline:
#   1. pathlib.resolve(strict=False) follows symlinks/junctions, normalizes ./..
#   2. Post-resolve UNC reject (EC-5 v0.6): refuses any path resolving to
#      \\... or //... so the WSL-symlink-to-\\wsl$\Ubuntu\.ssh vector is dead.
#   3. Win32 GetLongPathNameW expands 8.3 short names (PROGRA~1 -> Program Files).
#   4. NTFS drive-letter case-fold (c:\... -> C:\...).
#   5. Forward-slash normalization (so wcmatch globs match the same identity).
#   6. NUL/empty integrity check.
#
# Importable: `from canonicalize_path import canonicalize, CanonicalizeError`
# CLI: `python canonicalize-path.py <path>` -> stdout = canonical, exit 0;
#      stderr = reason, exit 1 (DENY).
#
# Stdlib-only by contract (zero dependency surface for the dependency-root file).

import os
import pathlib
import sys


class CanonicalizeError(Exception):
    pass


def _get_long_path_name_w(path: str) -> str:
    if os.name != "nt":
        return path
    import ctypes
    from ctypes import wintypes

    fn = ctypes.windll.kernel32.GetLongPathNameW
    fn.restype = wintypes.DWORD
    fn.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]

    needed = fn(path, None, 0)
    if needed == 0:
        err = ctypes.get_last_error()
        # Tolerate not-found: glob match still runs against the lexical form.
        if err in (0, 2, 3):
            return path
        raise CanonicalizeError(f"GetLongPathNameW failed (errno={err})")

    buf = ctypes.create_unicode_buffer(needed)
    written = fn(path, buf, needed)
    if written == 0 or written >= needed:
        raise CanonicalizeError("GetLongPathNameW returned unexpected size")
    return buf.value


def canonicalize(input_path: str) -> str:
    if not input_path or not isinstance(input_path, str):
        raise CanonicalizeError("denied: empty or non-string path")

    p = input_path.strip().strip('"').strip("'")
    if not p:
        raise CanonicalizeError("denied: empty after strip")
    if "\x00" in p:
        raise CanonicalizeError("denied: NUL byte in path")

    try:
        resolved = str(pathlib.Path(p).resolve(strict=False))
    except (OSError, ValueError, RuntimeError) as e:
        raise CanonicalizeError(f"denied: resolve failed ({type(e).__name__})")

    if resolved.startswith("\\\\") or resolved.startswith("//"):
        raise CanonicalizeError("denied: resolved path is UNC")

    long_form = _get_long_path_name_w(resolved)

    if os.name == "nt" and len(long_form) >= 2 and long_form[1] == ":":
        long_form = long_form[0].upper() + long_form[1:]

    canonical = long_form.replace("\\", "/")

    if not canonical or "\x00" in canonical:
        raise CanonicalizeError("denied: canonical form invalid")

    return canonical


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: canonicalize-path.py <path>\n")
        return 1
    try:
        sys.stdout.write(canonicalize(sys.argv[1]))
        return 0
    except CanonicalizeError as e:
        sys.stderr.write(f"{e}\n")
        return 1
    except Exception as e:
        sys.stderr.write(f"denied: unexpected ({type(e).__name__}: {e})\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
