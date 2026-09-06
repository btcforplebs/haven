#!/usr/bin/env python3
"""Compare two project.pbxproj files by what each target actually builds.

The path-set check in check-project-sync.sh answers "is this file in the
project?". This one answers "is this file in a target's build phase?", which is
the question that decides whether it compiles or ships. A file can hold a
PBXFileReference and a group entry while belonging to no Sources or Resources
phase at all: it then does not build, and a path-set diff sees nothing wrong.
That is the shape notification.mp3 fails in.

Usage: pbx-target-files.py <a/project.pbxproj> <b/project.pbxproj>
Exit:  0 every target builds the same set of files, 1 otherwise.
"""
import re
import sys

PHASE = re.compile(
    r"([0-9A-F]{24}) /\* (?:Sources|Resources|Frameworks) \*/ = \{\s*"
    r"isa = PBX\w+BuildPhase;(.*?)\n\t*\};",
    re.S,
)
TARGET = re.compile(
    r"[0-9A-F]{24} /\* ([^*]+?) \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t*\};", re.S
)
MEMBER = re.compile(r"/\* (.+?) in (?:Sources|Resources|Frameworks) \*/")


def target_files(path):
    """target name -> set of basenames in its Sources/Resources/Frameworks phases."""
    text = open(path, encoding="utf-8", errors="replace").read()
    phases = {m.group(1): set(MEMBER.findall(m.group(2))) for m in PHASE.finditer(text)}
    out = {}
    for m in TARGET.finditer(text):
        files = set()
        for phase_id in re.findall(r"([0-9A-F]{24}) /\* \w+ \*/", m.group(2)):
            files |= phases.get(phase_id, set())
        out[m.group(1).strip()] = {f.rsplit("/", 1)[-1] for f in files}
    return out


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    a, b = target_files(argv[1]), target_files(argv[2])

    # A parse failure and a clean result both print nothing, so refuse to pass
    # quietly: this project has native targets, and a run that finds none has
    # broken rather than agreed.
    for path, parsed in ((argv[1], a), (argv[2], b)):
        if not parsed or not any(parsed.values()):
            print(f"could not read any target build phases from {path}")
            return 1

    status = 0
    for name in sorted(set(a) | set(b)):
        if name not in a or name not in b:
            side = "generated" if name not in a else "committed"
            print(f"target {name!r} exists only in the {side} project")
            status = 1
            continue
        dropped, added = sorted(a[name] - b[name]), sorted(b[name] - a[name])
        if not dropped and not added:
            continue
        status = 1
        print(f"target {name}:")
        for f in dropped:
            print(f"  - {f} builds in the committed project, not in the generated one")
        for f in added:
            print(f"  + {f} builds in the generated project, not in the committed one")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
