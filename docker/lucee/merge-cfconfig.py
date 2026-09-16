#!/usr/bin/env python3
"""Merge one or more .CFConfig.json fragments into Lucee's configuration.

    mura-merge-cfconfig <target .CFConfig.json> <fragment.json> [fragment.json ...]

Lucee keeps its configuration in a single JSON document. The official image
ships one at /opt/lucee/server/lucee-server/context/.CFConfig.json and, in
the "single" mode this image runs in, that is the only context there is - no
web context, no deploy folder to drop overrides into. Adding keys to that
document before Lucee starts means the settings are live from the very first
request, with no runtime `cfadmin` call that could fail on the boot where it
matters. Lucee round-trips keys it does not know and ${ENV:default}
placeholders unchanged.

Merge rules, per top-level key of each fragment, in argument order:
  * "//"           - ignored, so a fragment can carry documentation;
  * object values  - per-key shallow merge into the target's object (a
                     fragment's "caches" entries are ADDED to whatever the
                     document already defines; a same-named entry replaces);
  * anything else  - replaces the target's value (scalars such as
                     "inspectTemplate", and arrays).

The merge is idempotent, so docker/entrypoint.sh runs it on every boot.
Exit status is 0 when the target was written (even if nothing changed), 1 on
a target or fragment that is not a JSON object, 2 on a usage error.
"""

import json
import sys


def merge_fragment(config, fragment, applied):
    for key, value in fragment.items():
        if key == "//":
            continue
        if isinstance(value, dict):
            section = config.get(key)
            if not isinstance(section, dict):
                section = {}
                config[key] = section
            section.update(value)
            applied.extend("%s.%s" % (key, name) for name in sorted(value))
        else:
            config[key] = value
            applied.append("%s=%s" % (key, value))


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    target_path, fragment_paths = argv[1], argv[2:]

    with open(target_path, encoding="utf-8") as handle:
        config = json.load(handle)
    if not isinstance(config, dict):
        print("merge-cfconfig: %s is not a JSON object" % target_path, file=sys.stderr)
        return 1

    applied = []
    for fragment_path in fragment_paths:
        with open(fragment_path, encoding="utf-8") as handle:
            fragment = json.load(handle)
        if not isinstance(fragment, dict):
            print("merge-cfconfig: %s is not a JSON object" % fragment_path, file=sys.stderr)
            return 1
        before = len(applied)
        merge_fragment(config, fragment, applied)
        if len(applied) == before:
            print("merge-cfconfig: %s contained nothing to merge" % fragment_path, file=sys.stderr)

    with open(target_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=1)
        handle.write("\n")

    print("merge-cfconfig: merged %d fragment(s) into %s: %s"
          % (len(fragment_paths), target_path, ", ".join(applied) or "(nothing)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
