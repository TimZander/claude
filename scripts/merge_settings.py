#!/usr/bin/env python3
"""Deep-merge team settings (base) into user settings (override) for setup-env.sh.

Replaces the jq-based merge so the sync works without jq (which is often absent
on Windows/Git-Bash, where it silently skipped the whole settings sync). Prints
the merged JSON to stdout.

Semantics match scripts/Merge-JsonObjects.ps1 (the PowerShell path):
  - objects deep-merge key-by-key; the override (user) wins on scalar conflict
  - arrays union with order-preserving, case-sensitive dedup (base items first,
    then override items not already present)
  - a null on either side heals toward the non-null side (a corrupted
    "permissions": null keeps the team value instead of crashing/erasing)
  - object keys containing whitespace (a prior-corruption signature) are dropped
    so a corrupted file self-heals on the next sync

Usage: merge_settings.py <base.json> <override.json>
"""
import json
import sys


def merge(base, override):
    if override is None:
        return base
    if base is None:
        return override
    if isinstance(base, dict) and isinstance(override, dict):
        result = {}
        # base keys first (in order), then override-only keys
        keys = list(base.keys()) + [k for k in override if k not in base]
        for k in keys:
            if any(c.isspace() for c in k):
                print(f"skipping corrupted settings key (contains whitespace): {k!r}",
                      file=sys.stderr)
                continue
            if k in base and k in override:
                result[k] = merge(base[k], override[k])
            elif k in override:
                result[k] = override[k]
            else:
                result[k] = base[k]
        return result
    if isinstance(base, list) and isinstance(override, list):
        seen, out = set(), []
        for item in base + override:
            key = item if isinstance(item, str) else json.dumps(item, sort_keys=True)
            if key not in seen:
                seen.add(key)
                out.append(item)
        return out
    return override


def main():
    if len(sys.argv) != 3:
        print("usage: merge_settings.py <base.json> <override.json>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            base = json.load(f)
        with open(sys.argv[2], encoding="utf-8") as f:
            override = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error reading/parsing settings: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(merge(base, override), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
