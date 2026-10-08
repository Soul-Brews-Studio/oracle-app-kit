"""The module map of a Swift library kept as Module.Function.swift files — and the gate that keeps it that way.

usage: python3 -I scripts/module_map.py [--max 500] <dir> [<dir> …]

Groups every .swift file by its module (the name before the first dot): `Views.swift` is the module's root,
`Views.Issues.swift` one of its functions. Prints Module → files with line counts, and exits 1 when a file is
over --max lines or its name is not Module.swift / Module.Function.swift (UpperCamelCase parts).
"""
import pathlib, re, sys

args = sys.argv[1:]
limit = 500
if "--max" in args:
    i = args.index("--max"); limit = int(args[i + 1]); del args[i:i + 2]
if not args:
    print(__doc__.strip()); sys.exit(2)

NAME = re.compile(r"^([A-Z][A-Za-z0-9]*)(?:\.([A-Z][A-Za-z0-9]*))?\.swift$")
bad = []
for d in args:
    root = pathlib.Path(d)
    modules = {}
    for p in sorted(root.glob("*.swift")):
        n = sum(1 for _ in p.open(encoding="utf-8"))
        m = NAME.match(p.name)
        if not m:
            bad.append(f"{p}: name is not Module.swift or Module.Function.swift")
            continue
        if n > limit:
            bad.append(f"{p}: {n} lines, over {limit}")
        modules.setdefault(m.group(1), []).append((m.group(2) or "", n))
    total = sum(n for fs in modules.values() for _, n in fs)
    print(f"{root}  ·  {len(modules)} modules · {sum(len(f) for f in modules.values())} files · {total} lines")
    for mod in sorted(modules):
        fs = sorted(modules[mod], key=lambda f: (f[0] != "", f[0]))
        if len(fs) == 1 and not fs[0][0]:
            print(f"  {mod}.swift {fs[0][1]}")
            continue
        print(f"  {mod}  ({sum(n for _, n in fs)} lines)")
        for fn, n in fs:
            print(f"    {mod + ('.' + fn if fn else '')}.swift {n}{'  ← over ' + str(limit) if n > limit else ''}")
if bad:
    print(f"\n✗ {len(bad)} file(s) break the layout:")
    for b in bad:
        print(f"  {b}")
    print("  split by moving whole declarations into <Module>.<Function>.swift beside it (pure move, see #83), then:")
    print("  make include")
    sys.exit(1)
print(f"\n✓ every file is Module[.Function].swift and at most {limit} lines")
