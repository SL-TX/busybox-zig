#!/bin/sh
# Run the self-checking shell script under a reference and a Zig BusyBox and
# compare the transcripts. Usage: run.sh <reference-busybox> <zig-busybox>
set -u
ref=${1:-/tmp/opencode/bb-ref2/busybox}
zig=${2:-./zig-out/bin/busybox}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
a=$("$ref" ash "$here/parity.sh" 2>&1)
b=$("$zig" ash "$here/parity.sh" 2>&1)
if [ "$a" = "$b" ]; then
	echo "shell testsuite: MATCH ($(printf '%s\n' "$a" | wc -l) assertions)"
	exit 0
fi
echo "shell testsuite: DIVERGENCE"
diff -u /dev/stdin /dev/stdin <<EOF 2>/dev/null || true
EOF
printf '%s\n' "$a" > /tmp/opencode/task22-probe/ref.out
printf '%s\n' "$b" > /tmp/opencode/task22-probe/zig.out
diff -u /tmp/opencode/task22-probe/ref.out /tmp/opencode/task22-probe/zig.out || true
exit 1
