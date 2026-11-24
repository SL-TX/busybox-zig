#!/bin/sh
# Self-checking shell-semantics script. Runs identically under the reference
# and the Zig implementation; every assertion prints "ok" and the final line
# confirms the whole suite passed.
set -u

check() {
	if [ "$1" = "$2" ]; then
		echo ok
	else
		echo "FAIL: expected [$1] got [$2]"
		exit 1
	fi
}

# quoting and escapes
check "$(echo 'a b')" "a b"
check "$(echo "x y")" "x y"
check "$(echo a\ b)" "a b"

# variables and expansions
X=world
check "$X" "world"
check "${X}" "world"
check "${UNSET-par}" "par"
check "${#X}" "5"
check "${X#wo}" "rld"
check "${X/w/W}" "World"

# arithmetic
check "$((3+5*2))" "13"
check "$((2**8))" "256"
check "$((16#ff))" "255"

# control flow
if true; then echo ok; else echo bad; fi
i=0
while [ $i -lt 3 ]; do i=$((i+1)); done
check "$i" "3"
for w in a b c; do printf '%s' "$w"; done
echo

case abc in
	a*) echo ok ;;
	*) echo bad ;;
esac

# functions and local scope
f() { local inner=local; echo "$inner:$1"; }
outer=global
check "$(f arg)" "local:arg"
check "$outer" "global"

# pipelines, redirection, substitution
check "$(echo abc | tr a-z A-Z)" "ABC"
check "$(echo sub)" "sub"
tmp="$$".tmp
echo written > "$tmp"
check "$(cat "$tmp")" "written"
rm -f "$tmp"

# here-doc
check "$(cat <<EOF
doc line
EOF
)" "doc line"

# positional parameters and options
set -- one two three
check "$#" "3"
check "$2" "two"
shift
check "$1" "two"

echo ALL_OK
