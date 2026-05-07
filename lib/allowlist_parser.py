#!/usr/bin/env python3
# allowlist_parser.py v1.0 (DESIGN.md s12.2 + SE-R1 v0.4 + B4 v0.4).
#
# Argv-shape parser + constraint engine for the BUILDER allowlist.
# Imported by lib/lead-pretool-hook.py; separated for unit-testability per SE-R1.
#
# Public API:
#   tokenize(cmd) -> list[str]
#   load_allowlist(path) -> dict          (validates schemaVersion == 2)
#   match_rule(argv, rules, denyglobs_loader) -> tuple[dict, dict] | None
#   apply_pre_checks(rule, captures, ctx) -> tuple[bool, str]
#   apply_post_checks(rule, captures, ctx) -> tuple[bool, str]
#   scan_secrets(text) -> tuple[bool, str]
#
# `ctx` is a mutable dict the hook builds with: cwd, env, lead_state_dir,
# git helpers, etc. Splitting it out keeps this module side-effect-free
# at import time.

import hashlib
import importlib.util as _ilu
import json
import os
import pathlib
import re
import shlex
import subprocess


_HERE = pathlib.Path(__file__).resolve().parent

# Hyphenated filename forces importlib loader.
_canon_path = _HERE / "canonicalize-path.py"
_canon_spec = _ilu.spec_from_file_location("canonicalize_path", str(_canon_path))
if _canon_spec is None or _canon_spec.loader is None:
    raise RuntimeError("denied: cannot load canonicalize-path.py")
_canon_mod = _ilu.module_from_spec(_canon_spec)
_canon_spec.loader.exec_module(_canon_mod)
canonicalize = _canon_mod.canonicalize
CanonicalizeError = _canon_mod.CanonicalizeError


class AllowlistError(Exception):
    pass


# ---------------------------------------------------------------------------
# tokenize + load
# ---------------------------------------------------------------------------

def tokenize(cmd: str) -> list:
    """B4 v0.4: Windows-safe argv tokenization."""
    if not isinstance(cmd, str):
        raise AllowlistError("denied: non-string command")
    if os.name == "nt":
        return shlex.split(cmd, posix=False)
    return shlex.split(cmd, posix=True)


def load_allowlist(path: str) -> dict:
    """Atomic read-once-hash-parse contract (CM1 v0.5) is enforced by the caller;
    this function trusts the bytes it's given and only validates schema."""
    with open(path, "rb") as fh:
        data = fh.read()
    obj = json.loads(data.decode("utf-8"))
    if obj.get("schemaVersion") != 2:
        raise AllowlistError(
            f"denied: allowlist schemaVersion mismatch ({obj.get('schemaVersion')} != 2)"
        )
    if "rules" not in obj or not isinstance(obj["rules"], list):
        raise AllowlistError("denied: allowlist missing 'rules' array")
    return obj


def load_path_guard(path: str) -> dict:
    with open(path, "rb") as fh:
        data = fh.read()
    obj = json.loads(data.decode("utf-8"))
    if obj.get("schemaVersion") != 2:
        raise AllowlistError(
            f"denied: path-guard schemaVersion mismatch ({obj.get('schemaVersion')} != 2)"
        )
    return obj


def _expand_env(s: str) -> str:
    def _sub(m):
        var = m.group(1)
        if var not in os.environ:
            raise AllowlistError(f"denied: env var {var} not set")
        return os.environ[var]
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", _sub, s)


# ---------------------------------------------------------------------------
# glob match (wcmatch GLOBSTAR | BRACE)
# ---------------------------------------------------------------------------

def _glob_match_first(target: str, patterns):
    """Returns first matching pattern or None."""
    try:
        from wcmatch import glob as wcglob
    except ImportError:
        raise AllowlistError("denied: wcmatch not importable (integrity check failed)")
    if not hasattr(wcglob, "GLOBSTAR") or not hasattr(wcglob, "BRACE"):
        raise AllowlistError("denied: wcmatch GLOBSTAR/BRACE missing (integrity check failed)")

    flags = wcglob.GLOBSTAR | wcglob.BRACE
    for pat in patterns:
        try:
            expanded = _expand_env(pat)
        except AllowlistError:
            continue
        # wcmatch is path-syntax aware; we feed forward-slash canonical form.
        if wcglob.globmatch(target, expanded, flags=flags):
            return pat
    return None


# ---------------------------------------------------------------------------
# argv-shape match
# ---------------------------------------------------------------------------

def _match_atom(atom: dict, token: str) -> bool:
    if "literal" in atom:
        return token == atom["literal"]
    if "literalPath" in atom or "literalAbsPath" in atom:
        spec_path = atom.get("literalPath") or atom.get("literalAbsPath")
        try:
            a = canonicalize(_expand_env(spec_path))
            b = canonicalize(token)
        except (CanonicalizeError, AllowlistError):
            return False
        # Windows is case-insensitive on path identity.
        return a.lower() == b.lower()
    if "oneOf" in atom:
        return any(_match_atom(sub, token) for sub in atom["oneOf"])
    return False


def _validate_capture_token(atom: dict, token: str, denyglobs_loader=None):
    """Returns (ok, reason)."""
    if "regex" in atom:
        if not re.fullmatch(atom["regex"], token):
            return False, f"capture regex mismatch"
    if "maxLen" in atom and len(token) > atom["maxLen"]:
        return False, f"capture exceeds maxLen ({atom['maxLen']})"
    if "allowedFlags" in atom and token.startswith("-"):
        if token not in atom["allowedFlags"]:
            return False, f"flag {token!r} not in allowedFlags"
    constraint = atom.get("constraint", "")
    if constraint.startswith("under:"):
        var = constraint.split(":", 1)[1]
        if var not in os.environ:
            return False, f"constraint env var {var} not set"
        try:
            base = canonicalize(os.environ[var])
            tgt = canonicalize(token)
        except CanonicalizeError as e:
            return False, str(e)
        # base may end in / or not; normalize.
        base_norm = base.rstrip("/")
        if not (tgt.lower() == base_norm.lower()
                or tgt.lower().startswith(base_norm.lower() + "/")):
            return False, f"path not under {var}"
    if "denyGlobsRef" in atom and denyglobs_loader is not None:
        try:
            patterns = denyglobs_loader(atom["denyGlobsRef"])
        except Exception as e:
            return False, f"denyGlobsRef load failed ({type(e).__name__})"
        try:
            tgt = canonicalize(token)
        except CanonicalizeError as e:
            return False, str(e)
        hit = _glob_match_first(tgt, patterns)
        if hit is not None:
            return False, f"deny-glob match ({hit})"
    return True, ""


def _try_match(rule: dict, argv: list, denyglobs_loader=None):
    """Returns (matched, captures, reason)."""
    shape = rule.get("argvShape", [])
    captures = {}
    n = len(argv)

    if "argvLengthExact" in rule and n != rule["argvLengthExact"]:
        return False, {}, f"length {n} != exact {rule['argvLengthExact']}"
    if "argvLengthMin" in rule and n < rule["argvLengthMin"]:
        return False, {}, f"length {n} < min {rule['argvLengthMin']}"
    if "argvLengthMax" in rule and n > rule["argvLengthMax"]:
        return False, {}, f"length {n} > max {rule['argvLengthMax']}"

    ai = 0
    for si, atom in enumerate(shape):
        if "capture" in atom:
            cmin = atom.get("argvShapeMin", 1)
            cmax = atom.get("argvShapeMax", 1)
            atoms_after = len(shape) - si - 1
            available = n - ai - atoms_after
            if available < cmin:
                return False, {}, f"capture {atom['capture']} short ({available} < {cmin})"
            take = min(available, cmax)
            captured = argv[ai:ai + take]
            for tok in captured:
                ok, reason = _validate_capture_token(atom, tok, denyglobs_loader)
                if not ok:
                    return False, {}, f"capture {atom['capture']}: {reason}"
            captures[atom["capture"]] = captured if cmax > 1 else (captured[0] if captured else "")
            ai += take
        else:
            if ai >= n:
                return False, {}, f"shape[{si}] needs token, argv exhausted"
            if not _match_atom(atom, argv[ai]):
                return False, {}, f"shape[{si}] mismatch"
            ai += 1

    if ai != n:
        return False, {}, f"{n - ai} extra tokens after shape"
    return True, captures, ""


def match_rule(argv: list, rules: list, denyglobs_loader=None):
    """Returns (rule, captures) on first match, else None."""
    last_reason = "no rule matched"
    for rule in rules:
        ok, caps, reason = _try_match(rule, argv, denyglobs_loader)
        if ok:
            return rule, caps
        last_reason = reason  # captured for log only
    return None


# ---------------------------------------------------------------------------
# secret scan (used by postCheck:scan-secrets-in:)
# ---------------------------------------------------------------------------

_SECRET_PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"gho_[A-Za-z0-9]{36}"),
    re.compile(r"glpat-[A-Za-z0-9_-]{20}"),
    re.compile(r"xoxb-[A-Za-z0-9-]{40,}"),
    re.compile(r"xoxp-[A-Za-z0-9-]{40,}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}"),
    re.compile(r"postgres://[^:]+:[^@]+@"),
    re.compile(r"rk_live_[a-z0-9]+"),
    re.compile(r"Bearer\s+[A-Za-z0-9_=-]{20,}"),
    re.compile(r"mongodb(?:\+srv)?://[^:]+:[^@]{4,}@"),
    re.compile(r"mysql://[^:]+:[^@]{4,}@"),
    re.compile(r"redis(?:s)?://[^:]+:[^@]{4,}@"),
    re.compile(r"\b(?:FQoG|FwoG|IQo[a-zA-Z0-9])[A-Za-z0-9_/+=]{200,}"),
]


def scan_secrets(text: str):
    """Returns (clean, reason)."""
    if not text:
        return True, ""
    if not isinstance(text, str):
        text = str(text)
    for pat in _SECRET_PATTERNS:
        if pat.search(text):
            return False, "secret-shape match"
    return True, ""


# ---------------------------------------------------------------------------
# preCheck dispatcher
# ---------------------------------------------------------------------------

def _verify_sha_pin(target_path: str, pin_path: str):
    try:
        with open(target_path, "rb") as fh:
            actual = hashlib.sha256(fh.read()).hexdigest()
    except Exception as e:
        return False, f"target read failed ({type(e).__name__})"
    try:
        with open(pin_path, "r", encoding="utf-8") as fh:
            pinned = None
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                tokens = line.split()
                for t in tokens:
                    if len(t) == 64 and re.fullmatch(r"[0-9a-fA-F]{64}", t):
                        pinned = t.lower()
                        break
                if pinned:
                    break
    except Exception as e:
        return False, f"pin read failed ({type(e).__name__})"
    if not pinned:
        return False, "no sha in pin file"
    if actual.lower() != pinned:
        return False, "sha mismatch"
    return True, ""


def _git_capture(args, cwd, timeout=10):
    try:
        proc = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return -1, "", f"{type(e).__name__}: {e}"


def _resolve_upstream_rev(branch: str, cwd: str) -> str:
    rc, out, _ = _git_capture(
        ["rev-parse", "--verify", "--quiet", f"origin/{branch}"], cwd
    )
    if rc == 0 and out:
        return out
    # Empty-tree SHA1: stable fallback for first-push scenarios.
    return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _read_scan_pass_manifest(captures: dict, cwd: str):
    """Returns (manifest_path, manifest_dict, diff_sha) or (None, reason_str, None)."""
    branch = captures.get("branch", "")
    if not branch:
        return None, "no branch capture", None
    upstream = _resolve_upstream_rev(branch, cwd)
    rc, _, err = _git_capture(["rev-parse", "--verify", "HEAD"], cwd)
    if rc != 0:
        return None, f"HEAD missing ({err})", None
    # Compute canonical-diff sha (V0.6 same-shape invariant).
    try:
        proc = subprocess.run(
            ["git", "diff", f"{upstream}..HEAD",
             "--no-textconv", "--no-renames", "--no-color", "--binary"],
            cwd=cwd, capture_output=True, timeout=20,
        )
    except Exception as e:
        return None, f"git diff failed ({type(e).__name__})", None
    if proc.returncode != 0:
        return None, "git diff non-zero", None
    diff_bytes = proc.stdout
    if len(diff_bytes) > 10 * 1024 * 1024:
        return None, "diff too large (>10 MB)", None
    diff_sha = hashlib.sha256(diff_bytes).hexdigest()

    localappdata = os.environ.get("LOCALAPPDATA", "")
    if not localappdata:
        return None, "LOCALAPPDATA not set", None
    manifest_path = pathlib.Path(localappdata) / "Temp" / f"lead-scan-passed-{diff_sha[:16]}.json"
    if not manifest_path.exists():
        return None, "manifest absent", None
    try:
        with open(manifest_path, "rb") as fh:
            manifest_bytes = fh.read()
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except Exception as e:
        return None, f"manifest parse failed ({type(e).__name__})", None
    return manifest_path, manifest, diff_sha


def _check_scan_pass(field: str, captures: dict, ctx: dict):
    cwd = ctx.get("cwd") or os.getcwd()
    manifest_path, manifest, diff_sha = _read_scan_pass_manifest(captures, cwd)
    if manifest_path is None:
        return False, manifest

    # Common: TTL + ok.
    import datetime as _dt
    try:
        ts_str = manifest.get("ts", "").replace("Z", "+00:00")
        ts = _dt.datetime.fromisoformat(ts_str)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=_dt.timezone.utc)
        age = (_dt.datetime.now(_dt.timezone.utc) - ts).total_seconds()
        if age > 300:
            return False, f"manifest stale ({age:.0f}s > 300s)"
    except Exception as e:
        return False, f"ts parse failed ({type(e).__name__})"
    if not manifest.get("ok"):
        return False, "manifest ok=false"

    if field == "staged-diff-sha256":
        if manifest.get("stagedDiffSha256") != diff_sha:
            return False, "stagedDiffSha256 mismatch"
    elif field == "branch-matches-head":
        rc, head_branch, _ = _git_capture(
            ["symbolic-ref", "--short", "HEAD"], cwd
        )
        if rc != 0 or not head_branch:
            return False, "git symbolic-ref failed"
        if manifest.get("branch") != head_branch:
            return False, f"branch mismatch"
    elif field == "worktree-path-matches-cwd":
        try:
            cwd_canon = canonicalize(cwd)
            mwt_canon = canonicalize(manifest.get("worktreePath", ""))
        except CanonicalizeError as e:
            return False, str(e)
        if cwd_canon.lower() != mwt_canon.lower():
            return False, "worktreePath mismatch"
    elif field == "upstream-rev-matches-origin":
        live = _resolve_upstream_rev(captures.get("branch", ""), cwd)
        if manifest.get("upstreamRev") != live:
            return False, "upstreamRev mismatch"
    else:
        return False, f"unknown manifest field {field}"
    # Stash the manifest for downstream checks (manifest-mtime-inode-stable).
    ctx["__manifest_path"] = str(manifest_path)
    ctx["__manifest"] = manifest
    return True, ""


def _check_manifest_mtime_inode_stable(captures: dict, ctx: dict):
    manifest_path_s = ctx.get("__manifest_path")
    manifest = ctx.get("__manifest")
    if not manifest_path_s or manifest is None:
        # The scan-pass-manifest:* check populates these; if absent the
        # preCheck list is misordered. Fail closed.
        return False, "manifest not loaded"
    manifest_path = pathlib.Path(manifest_path_s)
    if not manifest_path.exists():
        return False, "manifest vanished mid-fire"
    persisted_mtime = manifest.get("manifestMtime")
    persisted_id = manifest.get("manifestFileId", "")
    if persisted_mtime is None:
        return False, "manifestMtime field missing"
    try:
        persisted_int = int(persisted_mtime)
    except Exception:
        return False, "manifestMtime not integer"
    try:
        st = manifest_path.stat()
    except Exception as e:
        return False, f"stat failed ({type(e).__name__})"
    # Convert epoch seconds to .NET ticks (100ns since 0001-01-01 UTC).
    ticks_per_sec = 10_000_000
    epoch_to_ticks = 621_355_968_000_000_000
    live_mtime = int(st.st_mtime * ticks_per_sec) + epoch_to_ticks
    # Allow +/-2 s slack for filesystem granularity + tick rounding.
    if abs(live_mtime - persisted_int) > 2 * ticks_per_sec:
        return False, "manifest mtime drift"
    if os.name == "nt" and persisted_id:
        try:
            live_id = _query_file_id(str(manifest_path))
        except Exception as e:
            return False, f"file-id query failed ({type(e).__name__})"
        if live_id and persisted_id.lower() != live_id.lower():
            return False, "manifest fileId drift"
    return True, ""


def _query_file_id(path: str) -> str:
    """Windows: returns hex(volSerial 8B || FileId 16B). 24-char hex prefix used by V8-8."""
    import ctypes
    from ctypes import wintypes

    GENERIC_READ = 0x80000000
    FILE_SHARE_READ = 0x00000001
    FILE_SHARE_WRITE = 0x00000002
    FILE_SHARE_DELETE = 0x00000004
    OPEN_EXISTING = 3
    FILE_ATTRIBUTE_NORMAL = 0x80
    FileIdInfo = 18

    class FILE_ID_128(ctypes.Structure):
        _fields_ = [("Identifier", ctypes.c_ubyte * 16)]

    class FILE_ID_INFO(ctypes.Structure):
        _fields_ = [
            ("VolumeSerialNumber", ctypes.c_ulonglong),
            ("FileId", FILE_ID_128),
        ]

    CreateFileW = ctypes.windll.kernel32.CreateFileW
    CreateFileW.restype = wintypes.HANDLE
    CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    GetFileInformationByHandleEx = ctypes.windll.kernel32.GetFileInformationByHandleEx
    GetFileInformationByHandleEx.restype = wintypes.BOOL
    GetFileInformationByHandleEx.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
    ]
    CloseHandle = ctypes.windll.kernel32.CloseHandle
    CloseHandle.restype = wintypes.BOOL
    CloseHandle.argtypes = [wintypes.HANDLE]

    h = CreateFileW(
        path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None,
    )
    INVALID_HANDLE = ctypes.c_void_p(-1).value
    if h == INVALID_HANDLE or h is None:
        raise OSError("CreateFileW failed")
    try:
        info = FILE_ID_INFO()
        ok = GetFileInformationByHandleEx(
            h, FileIdInfo, ctypes.byref(info), ctypes.sizeof(info)
        )
        if not ok:
            raise OSError("GetFileInformationByHandleEx failed")
        vol = f"{info.VolumeSerialNumber:016x}"
        fid = bytes(info.FileId.Identifier).hex()
        return vol + fid
    finally:
        CloseHandle(h)


def apply_pre_checks(rule: dict, captures: dict, ctx: dict):
    """ctx is mutable; carries cwd + scratch state across checks within one fire."""
    if "cwd" not in ctx:
        ctx["cwd"] = os.getcwd()

    for chk in rule.get("preCheck", []):
        if chk == "wc-c-halt-if-diff-over-10mb":
            # Folded into scan-pass-manifest:* (which fails closed at >10 MB);
            # this entry is kept for fixture-traceability per V7-1 v0.8.
            continue
        if chk == "manifest-mtime-inode-stable":
            ok, reason = _check_manifest_mtime_inode_stable(captures, ctx)
            if not ok:
                return False, f"{chk}: {reason}"
            continue
        if chk.startswith("scan-pass-manifest:"):
            field = chk.split(":", 1)[1]
            ok, reason = _check_scan_pass(field, captures, ctx)
            if not ok:
                return False, f"{chk}: {reason}"
            continue
        if chk.startswith("sha256-verify:"):
            parts = chk.split(":", 2)
            if len(parts) != 3:
                return False, f"malformed: {chk}"
            env_var = parts[1]
            pin_path = os.environ.get(env_var)
            if not pin_path:
                return False, f"sha256-verify env var {env_var} not set"
            target = None
            for atom in rule.get("argvShape", []):
                if "literalPath" in atom or "literalAbsPath" in atom:
                    raw = atom.get("literalPath") or atom.get("literalAbsPath")
                    try:
                        target = _expand_env(raw)
                    except AllowlistError:
                        target = raw
                    break
            if not target:
                return False, "sha256-verify: no literalPath in rule"
            ok, reason = _verify_sha_pin(target, pin_path)
            if not ok:
                return False, f"{chk}: {reason}"
            continue
        if chk == "pytest-conftest-check":
            # The pytest-no-conftest rule already requires --no-conftest in shape;
            # this preCheck is a smoke marker that the path was matched. No-op pass.
            continue
        if chk == "assert-no-conftest-py-in-cwd":
            if list(pathlib.Path(ctx["cwd"]).glob("conftest.py")):
                return False, "conftest.py present in cwd"
            continue
        return False, f"unknown preCheck {chk}"
    return True, ""


def apply_post_checks(rule: dict, captures: dict, ctx: dict):
    for chk in rule.get("postCheck", []):
        if chk.startswith("scan-secrets-in:"):
            key = chk.split(":", 1)[1]
            value = captures.get(key, "")
            if isinstance(value, list):
                value = " ".join(str(v) for v in value)
            ok, reason = scan_secrets(value)
            if not ok:
                return False, f"{chk}: {reason}"
            continue
        return False, f"unknown postCheck {chk}"
    return True, ""


# ---------------------------------------------------------------------------
# CLI smoke (allows `python allowlist_parser.py <cmd>` from a shell for
# manual testing; never used in the gate hot path).
# ---------------------------------------------------------------------------

def _cli_smoke(argv: list) -> int:
    import sys as _sys
    if len(argv) < 3:
        _sys.stderr.write("usage: allowlist_parser.py <allowlist.json> <cmd>\n")
        return 2
    rules = load_allowlist(argv[1])["rules"]
    tokens = tokenize(argv[2])
    res = match_rule(tokens, rules)
    if res is None:
        _sys.stderr.write("denied: not in allowlist\n")
        return 1
    rule, caps = res
    _sys.stdout.write(json.dumps({"rule": rule.get("id"), "captures": caps}))
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_cli_smoke(_sys.argv))
