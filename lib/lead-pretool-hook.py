#!/usr/bin/env python3
# lib/lead-pretool-hook.py v1.0 (DESIGN.md s12 full runtime gate).
#
# Pipeline per fire (fail-closed, in strict order):
#   1. Env contract               (s12.1)
#   2. Trust anchor               (s12.6 step 10 + s12.8 step 1; C7 v0.6)
#   3. 9-file pin chain           (s12.8 with self-hash terminator; CM1 v0.5)
#   4. wcmatch importability      (s12.3 _se_n3_note; V8-2 v0.9)
#   5. Tool dispatch              (Bash s12.2 / Edit-Write s12.3 / Read s12.3 /
#                                  MCP s12.4 / Agent s12.9 / internal-tools)
#   6. Decision (stdout JSON + exit code per Claude Code hook protocol)
#
# Hook protocol:
#   - stdin  = PreToolUse event JSON
#   - stdout = {"decision": "allow"|"block", "reason": "..."}
#   - stderr = generic surface msg (visible to model on deny)
#   - exit   = 0 (allow) | 2 (block)
#
# All deny surfaces use generic strings (SE-S5 v0.4). Specific failure mode is
# logged to ~/.claude/hooks/lead-pretool-hook.log as a JSONL record.

import hashlib
import importlib.util as _ilu
import json
import os
import pathlib
import re
import sys
import time
import traceback


# === Trust anchor =============================================================
#
# _ANCHOR_SHA is the SHA-256 of lib/install-hook.ps1 bytes as released by the
# distributor. Every fire the hook re-reads install-hook.ps1, hashes it, and
# compares to this constant. Mismatch -> DENY ALL. Terminates the trust chain
# at a compile-time constant rather than a mutable file (C7 v0.6).
#
# v1.0 PROVISIONING NOTE: leave this empty for first-install bootstrap; the
# hook falls back to ~/.claude/lead-agent-trust-anchor.txt with a WARN log
# entry until you paste the SHA below. After running install-hook.ps1 once,
# replace the empty string with the printed SHA. From then on the hook is
# fully bootstrapped and any tampering of install-hook.ps1 fails closed.
_ANCHOR_SHA = "60ac9d6c8c3eb49e9c95416bbbecbd3664fafcdb333401ab4caace888a714b48"


# === Constants ================================================================

_HOOK_SCHEMA = 3                                     # s12.1 LEAD_HOOK_SCHEMA
_GENERIC_DENY = "denied: not in allowlist"           # SE-S5 v0.4
_GENERIC_INTEGRITY = "denied: integrity check failed"
_GENERIC_CONFIG = "denied: lead-agent hook config invalid; refuse all"  # s12.1
_GENERIC_MCP = "denied: not in mcp-allow.json"

_HERE = pathlib.Path(__file__).resolve().parent      # .../skills/lead-agent/lib
_SKILL = _HERE.parent                                # .../skills/lead-agent
_LOG_PATH = pathlib.Path.home() / ".claude" / "hooks" / "lead-pretool-hook.log"

# 11-file pin set per s12.8 (v1.1.0: + secret-scan.ps1 + jsonl-watcher.ps1).
# launch.ps1 lives in skill_dir; the rest in lib/. Order is for diff-readability
# only -- the verifier matches entries by name, not by index.
_PIN_FILES = (
    "allowlist.json",
    "path-guard.json",
    "mcp-allow.json",
    "notify-sh.sha256",
    "canonicalize-path.py",
    "allowlist_parser.py",
    "lead-pretool-hook.py",
    "sanitize-jsonl.py",
    "secret-scan.ps1",
    "jsonl-watcher.ps1",
    "launch.ps1",
)

# Required env contract per s12.1. LEAD_HOOK_SCHEMA bumped to 3 in CM3 v0.5.
_REQUIRED_ENV = (
    "LEAD_AGENT",
    "LEAD_WORKTREE_PARENT",
    "LEAD_ALLOWLIST",
    "LEAD_PATH_GUARD",
    "LEAD_MCP_ALLOW",
    "LEAD_NOTIFY_SHA256",
    "LEAD_EXTENSION_SHA256",
    "LEAD_CANONICALIZER",
    "LEAD_HOOK_SCHEMA",
    "LEAD_TOOLS_DIR",
)

# Internal CC tools that don't mutate state; safe to passthrough in lead-mode.
# Anything outside this set + the explicit dispatchers below is denied.
_INTERNAL_PASSTHROUGH = frozenset({
    "TodoWrite", "TaskCreate", "TaskList", "TaskGet", "TaskUpdate", "TaskOutput",
    "TaskStop", "ExitPlanMode", "SlashCommand", "ScheduleWakeup",
    "BashOutput", "KillShell", "Monitor", "ListMcpResourcesTool",
    "ToolSearch",
})

# Bypass-token regex (s12.5; B8 v0.4). The bypass exists for human-driven main
# CC use only; in lead-mode, any command bearing this trailing comment is
# refused regardless of whether allowlist would otherwise match.
_BYPASS_RE = re.compile(r"(?:^|;)\s*#\s*secrets-ok-leaky\s*$", re.MULTILINE)


# === Late import allowlist_parser (which loads canonicalize-path.py) ==========
#
# allowlist_parser.py is in the pin set; its bytes are verified BEFORE we trust
# the import. The chicken-and-egg is resolved by the trust anchor: install-
# hook.ps1 is anchored at compile time, and install-hook.ps1 produces
# lead-extension.sha256 atomically, so by the time we exec_module here the
# pin chain has already been verified.

def _safe_import_parser():
    spec = _ilu.spec_from_file_location(
        "allowlist_parser", str(_HERE / "allowlist_parser.py")
    )
    if spec is None or spec.loader is None:
        return None
    mod = _ilu.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        return None
    return mod


# === Logging ==================================================================

def _log(level, msg, **fields):
    """Best-effort JSONL log; never raises."""
    try:
        _LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": level,
            "msg": msg,
            "pid": os.getpid(),
        }
        rec.update(fields)
        with open(_LOG_PATH, "ab") as fh:
            fh.write((json.dumps(rec, default=str) + "\n").encode("utf-8"))
    except Exception:
        pass


def _emit_decision(decision, reason=""):
    payload = {"decision": decision}
    if reason:
        payload["reason"] = reason
    sys.stdout.write(json.dumps(payload))


def _deny(generic, log_reason, **fields):
    _log("DENY", log_reason, generic=generic, **fields)
    _emit_decision("block", generic)
    sys.stderr.write(generic + "\n")
    sys.exit(2)


def _allow(log_reason, **fields):
    _log("ALLOW", log_reason, **fields)
    _emit_decision("allow")
    sys.exit(0)


# === Atomic read + hash =======================================================

def _atomic_read(path):
    with open(path, "rb") as fh:
        return fh.read()


def _sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


# === Trust anchor verification (s12.6 step 10, s12.8 step 1) ==================

def _verify_trust_anchor():
    install_hook = _HERE / "install-hook.ps1"
    try:
        bytes_ = _atomic_read(install_hook)
    except Exception as e:
        _deny(_GENERIC_INTEGRITY, "install-hook.ps1 unreadable",
              err=f"{type(e).__name__}: {e}")
    actual = _sha256_hex(bytes_)
    expected = _ANCHOR_SHA
    if not expected:
        anchor_file = pathlib.Path.home() / ".claude" / "lead-agent-trust-anchor.txt"
        if not anchor_file.exists():
            _deny(_GENERIC_INTEGRITY, "no trust anchor (constant empty + file absent)")
        try:
            expected = anchor_file.read_text(encoding="utf-8").strip().lower()
        except Exception as e:
            _deny(_GENERIC_INTEGRITY, "trust-anchor.txt unreadable",
                  err=f"{type(e).__name__}: {e}")
        _log("WARN", "using trust-anchor.txt fallback; paste SHA into _ANCHOR_SHA")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        _deny(_GENERIC_INTEGRITY, "trust anchor malformed", expected=expected)
    if actual.lower() != expected.lower():
        _deny(_GENERIC_INTEGRITY, "anchor mismatch",
              actual=actual, expected=expected.lower())


# === 9-file pin chain (s12.8) =================================================

def _verify_pin_chain(extension_sha_path):
    """Returns dict[name -> bytes] for the verified pinned configs.

    Self-hash chain: last `sha256:<hex>` line covers all preceding lines (joined
    with '\\n', with trailing newline). Each preceding line is `<name> <hex>`.
    """
    try:
        manifest_bytes = _atomic_read(extension_sha_path)
    except Exception as e:
        _deny(_GENERIC_INTEGRITY, "lead-extension.sha256 unreadable",
              err=f"{type(e).__name__}: {e}")

    text = manifest_bytes.decode("utf-8", errors="replace")
    raw_lines = text.splitlines()
    body_lines = []
    self_hash = None
    for ln in raw_lines:
        s = ln.strip()
        if s.startswith("sha256:"):
            self_hash = s.split(":", 1)[1].strip().lower()
        else:
            body_lines.append(ln)
    if self_hash is None:
        _deny(_GENERIC_INTEGRITY, "no self-hash line in manifest")
    if not re.fullmatch(r"[0-9a-f]{64}", self_hash):
        _deny(_GENERIC_INTEGRITY, "self-hash malformed")

    body = "\n".join(body_lines)
    if body and not body.endswith("\n"):
        body += "\n"
    actual_self = _sha256_hex(body.encode("utf-8"))
    if actual_self.lower() != self_hash:
        _deny(_GENERIC_INTEGRITY, "self-hash mismatch",
              actual=actual_self, expected=self_hash)

    pinned = {}
    for ln in body_lines:
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        sha = parts[-1].lower()
        if re.fullmatch(r"[0-9a-f]{64}", sha):
            pinned[name] = sha

    bytes_by_name = {}
    for name in _PIN_FILES:
        if name not in pinned:
            _deny(_GENERIC_INTEGRITY, "pin entry missing", name=name)
        target = (_SKILL if name == "launch.ps1" else _HERE) / name
        try:
            data = _atomic_read(target)
        except Exception as e:
            _deny(_GENERIC_INTEGRITY, "pin file unreadable",
                  name=name, err=f"{type(e).__name__}: {e}")
        actual = _sha256_hex(data)
        if actual.lower() != pinned[name]:
            _deny(_GENERIC_INTEGRITY, "pin mismatch",
                  name=name, actual=actual, expected=pinned[name])
        bytes_by_name[name] = data
    return bytes_by_name


# === wcmatch importability (s12.3 _se_n3_note; V8-2 v0.9) =====================

def _verify_wcmatch():
    try:
        from wcmatch import glob as wcglob   # noqa: F401
    except ImportError:
        _deny(_GENERIC_INTEGRITY, "wcmatch not importable")
    if not (hasattr(wcglob, "GLOBSTAR") and hasattr(wcglob, "BRACE")):
        _deny(_GENERIC_INTEGRITY, "wcmatch GLOBSTAR/BRACE constants missing")


# === Env contract =============================================================

def _check_env_contract():
    """Returns env dict if LEAD_AGENT=1; returns None for passthrough."""
    if os.environ.get("LEAD_AGENT") != "1":
        return None
    env = {}
    for name in _REQUIRED_ENV:
        v = os.environ.get(name)
        if not v:
            _deny(_GENERIC_CONFIG, "missing env", name=name)
        env[name] = v
    if env["LEAD_HOOK_SCHEMA"] != str(_HOOK_SCHEMA):
        _deny(_GENERIC_CONFIG, "hook schema mismatch",
              got=env["LEAD_HOOK_SCHEMA"], want=_HOOK_SCHEMA)
    return env


# === Glob match (env-expand + slash normalize) ================================

def _expand_env_str(s, parser_mod):
    def _sub(m):
        var = m.group(1)
        v = os.environ.get(var)
        if v is None:
            raise parser_mod.AllowlistError(f"env {var} not set")
        return v
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", _sub, s)


def _glob_check(target_canon, patterns, parser_mod):
    """Returns first matching pattern or None. target_canon already forward-slash."""
    from wcmatch import glob as wcglob
    flags = wcglob.GLOBSTAR | wcglob.BRACE
    for pat in patterns:
        try:
            expanded = _expand_env_str(pat, parser_mod)
        except parser_mod.AllowlistError:
            continue
        # env-expanded value may contain backslashes (USERPROFILE on Windows)
        expanded = expanded.replace("\\", "/")
        if wcglob.globmatch(target_canon, expanded, flags=flags):
            return pat
    return None


# === Bash dispatch (s12.2) ====================================================

def _check_bash(cmd, ctx, allowlist, path_guard, parser_mod):
    if not isinstance(cmd, str):
        _deny(_GENERIC_DENY, "bash command not a string")

    if _BYPASS_RE.search(cmd):
        _deny(_GENERIC_DENY, "lead-mode bypass token forbidden")

    try:
        argv = parser_mod.tokenize(cmd)
    except Exception as e:
        _deny(_GENERIC_DENY, "tokenize failed", err=f"{type(e).__name__}: {e}")

    rules = allowlist.get("rules", [])

    def denyglobs_loader(ref):
        if ":" not in ref:
            raise parser_mod.AllowlistError(f"bad denyGlobsRef: {ref}")
        _file, key = ref.split(":", 1)
        if key not in path_guard:
            raise parser_mod.AllowlistError(f"key {key} missing in path-guard")
        return path_guard[key]

    res = parser_mod.match_rule(argv, rules, denyglobs_loader)
    if res is None:
        _deny(_GENERIC_DENY, "no rule matched", argv=argv)
    rule, captures = res

    ok, reason = parser_mod.apply_pre_checks(rule, captures, ctx)
    if not ok:
        _deny(_GENERIC_DENY, "preCheck failed",
              rule_id=rule.get("id"), reason=reason)

    ok, reason = parser_mod.apply_post_checks(rule, captures, ctx)
    if not ok:
        _deny(_GENERIC_DENY, "postCheck failed",
              rule_id=rule.get("id"), reason=reason)

    _allow("bash matched", rule_id=rule.get("id"))


# === Path guard for write tools (s12.3) =======================================

# Keys forbidden in package.json (s12.3 writeDenyJsonScriptKeys handling).
# The spec expresses these as dotted globs ("scripts.*", "bin.*", etc.); for
# v1.0 we conservatively reject any package.json whose final state contains
# any of these top-level keys, regardless of whether they were added or pre-
# existed. Cleaner than diff-walking, equally safe, and consistent with the
# spec's "fail closed" stance for npm lifecycle vectors (SE-S4 v0.4).

_PKG_JSON_DENY_HEADS = {
    "scripts", "lint-staged", "husky", "simple-git-hooks",
    "pre-commit", "commit-msg",
    "preinstall", "install", "postinstall",
    "prepublishOnly", "prepare", "prepack",
    "bin",
}


def _is_package_json(canon_path):
    return canon_path.lower().endswith("/package.json")


def _final_pkg_json_text(target_path, tool_name, tool_input):
    """Returns the resulting full text of package.json after the edit, or None
    if we cannot determine it (which forces deny). Doesn't run user code."""
    if tool_name == "Write":
        return tool_input.get("content", "") or ""
    if tool_name == "Edit":
        try:
            existing = pathlib.Path(target_path).read_text(encoding="utf-8")
        except Exception:
            return None
        old = tool_input.get("old_string", "")
        new = tool_input.get("new_string", "")
        if not old:
            return None
        if tool_input.get("replace_all"):
            return existing.replace(old, new)
        # Single replacement only: the Edit tool errors if old_string isn't
        # unique, so a single replace mirrors the tool's behavior.
        if existing.count(old) != 1:
            return None
        return existing.replace(old, new, 1)
    if tool_name == "NotebookEdit":
        # Notebook edits don't apply to package.json; deny conservatively.
        return None
    return None


def _check_pkg_json_safe(target_canon, tool_name, tool_input):
    text = _final_pkg_json_text(target_canon, tool_name, tool_input)
    if text is None:
        _deny(_GENERIC_DENY, "cannot determine final package.json state",
              tool=tool_name)
    try:
        obj = json.loads(text)
    except Exception as e:
        _deny(_GENERIC_DENY, "package.json unparseable post-edit",
              err=f"{type(e).__name__}: {e}")
    if not isinstance(obj, dict):
        _deny(_GENERIC_DENY, "package.json root not an object")
    hits = [k for k in obj if k in _PKG_JSON_DENY_HEADS]
    if hits:
        _deny(_GENERIC_DENY, "package.json contains forbidden key", keys=hits)


def _check_write_path(target_path, tool_name, tool_input, path_guard, parser_mod):
    canonicalize = parser_mod.canonicalize
    CanonicalizeError = parser_mod.CanonicalizeError
    try:
        canon = canonicalize(target_path)
    except CanonicalizeError as e:
        _deny(_GENERIC_DENY, "canonicalize failed",
              target=target_path, err=str(e))

    allow_globs = path_guard.get("writeAllowGlobs", [])
    deny_globs = path_guard.get("writeDenyGlobs", [])

    if not _glob_check(canon, allow_globs, parser_mod):
        _deny(_GENERIC_DENY, "write target not under writeAllowGlobs",
              canon=canon, tool=tool_name)

    hit = _glob_check(canon, deny_globs, parser_mod)
    if hit:
        _deny(_GENERIC_DENY, "write hits deny-glob",
              pattern=hit, canon=canon, tool=tool_name)

    if _is_package_json(canon):
        _check_pkg_json_safe(canon, tool_name, tool_input)

    _allow("write accepted", canon=canon, tool=tool_name)


def _check_read_path(target_path, tool_name, path_guard, parser_mod):
    canonicalize = parser_mod.canonicalize
    CanonicalizeError = parser_mod.CanonicalizeError
    try:
        canon = canonicalize(target_path)
    except CanonicalizeError as e:
        _deny(_GENERIC_DENY, "canonicalize failed",
              target=target_path, err=str(e))
    roots = path_guard.get("readAllowRoots", [])
    if not _glob_check(canon, roots, parser_mod):
        _deny(_GENERIC_DENY, "read target outside readAllowRoots",
              canon=canon, tool=tool_name)
    _allow("read accepted", canon=canon, tool=tool_name)


# === MCP dispatch (s12.4) =====================================================

def _check_mcp(tool_name, mcp_allow):
    if mcp_allow.get("defaultPolicy") != "deny":
        _deny(_GENERIC_INTEGRITY, "mcp-allow defaultPolicy must be 'deny'")
    allowed = set(mcp_allow.get("allowedMcpTools", []))
    if tool_name not in allowed:
        _deny(_GENERIC_MCP, "mcp tool not in allow-list", tool=tool_name)
    _allow("mcp allowed", tool=tool_name)


# === Pinned-bytes JSON parse (CM1 v0.5) =======================================

def _parse_pinned_json(name, bytes_by_name, expected_schema):
    try:
        obj = json.loads(bytes_by_name[name].decode("utf-8"))
    except Exception as e:
        _deny(_GENERIC_INTEGRITY, "pinned JSON parse failed",
              name=name, err=f"{type(e).__name__}: {e}")
    if obj.get("schemaVersion") != expected_schema:
        _deny(_GENERIC_INTEGRITY, "pinned JSON schema mismatch",
              name=name, want=expected_schema, got=obj.get("schemaVersion"))
    return obj


# === Main =====================================================================

def _read_event():
    raw = ""
    try:
        raw = sys.stdin.read()
    except Exception:
        pass
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except Exception as e:
        _deny(_GENERIC_DENY, "stdin parse failed",
              err=f"{type(e).__name__}: {e}")


def main():
    env = _check_env_contract()
    if env is None:
        # Not lead-mode: passthrough. Drain stdin so the protocol pipe doesn't
        # block downstream hooks, then emit allow.
        try:
            sys.stdin.read()
        except Exception:
            pass
        _emit_decision("allow")
        return 0

    _verify_trust_anchor()

    extension_sha_path = pathlib.Path(env["LEAD_EXTENSION_SHA256"])
    bytes_by_name = _verify_pin_chain(extension_sha_path)

    _verify_wcmatch()

    parser_mod = _safe_import_parser()
    if parser_mod is None:
        _deny(_GENERIC_INTEGRITY, "allowlist_parser import failed")

    allowlist = _parse_pinned_json("allowlist.json", bytes_by_name, 2)
    path_guard = _parse_pinned_json("path-guard.json", bytes_by_name, 2)
    mcp_allow = _parse_pinned_json("mcp-allow.json", bytes_by_name, 3)

    event = _read_event()
    tool_name = event.get("tool_name", "") or ""
    tool_input = event.get("tool_input", {}) or {}
    cwd = event.get("cwd") or os.getcwd()
    ctx = {"cwd": cwd, "env": env}

    if tool_name.startswith("mcp__"):
        _check_mcp(tool_name, mcp_allow)

    if tool_name == "Bash":
        _check_bash(tool_input.get("command", ""), ctx, allowlist, path_guard, parser_mod)

    if tool_name in ("Edit", "Write", "NotebookEdit"):
        target = (tool_input.get("file_path")
                  or tool_input.get("notebook_path") or "")
        if not target:
            _deny(_GENERIC_DENY, "write tool missing target path", tool=tool_name)
        _check_write_path(target, tool_name, tool_input, path_guard, parser_mod)

    if tool_name in ("Read", "Grep", "Glob"):
        target = (tool_input.get("file_path")
                  or tool_input.get("path") or cwd)
        _check_read_path(target, tool_name, path_guard, parser_mod)

    if tool_name in ("Agent", "Task"):
        # Subagent inherits LEAD_AGENT env; its tool calls fire this hook with
        # the same gate. Dispatch itself is allowed (s12.9).
        _allow("agent dispatch passthrough", tool=tool_name)

    if tool_name in _INTERNAL_PASSTHROUGH:
        _allow("internal tool passthrough", tool=tool_name)

    # Anything else: fail closed. Includes WebFetch / WebSearch / unknown tools.
    _deny(_GENERIC_DENY, "unhandled tool", tool=tool_name)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        _log("ERROR", "uncaught exception",
             err=f"{type(e).__name__}: {e}",
             tb=traceback.format_exc())
        try:
            _emit_decision("block", _GENERIC_DENY)
        except Exception:
            pass
        sys.stderr.write(_GENERIC_DENY + "\n")
        sys.exit(2)
