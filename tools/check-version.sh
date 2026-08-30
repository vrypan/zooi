#!/bin/sh
# Assert that a release tag matches the version build.zig.zon declares.
#
# These are two facts kept in sync by memory, which is how v0.1.2 shipped
# declaring 0.1.1. Zig stamps the declared version into the dependency hash a
# consumer records, so a mismatch ends up in every consumer's build.zig.zon and
# cannot be corrected in place: moving a published tag leaves anyone who
# already fetched it holding a hash Zig will reject. The only fix is another
# release, so it is worth not making the mistake.
#
# Usage: tools/check-version.sh v0.1.3
set -eu

tag="${1:?usage: check-version.sh <tag>}"
want="${tag#v}"
got=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)

if [ -z "$got" ]; then
    echo "check-version: no .version found in build.zig.zon" >&2
    exit 1
fi
if [ "$want" != "$got" ]; then
    echo "check-version: tag $tag wants version $want, build.zig.zon declares $got" >&2
    exit 1
fi
echo "check-version: $tag matches build.zig.zon ($got)"
