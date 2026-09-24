#!/usr/bin/env bash
# Quick check: can this filesystem reflink-duplicate files in the graphroot?
set -euo pipefail

GRAPHROOT="${GRAPHROOT:-/var/tmp/crio-storage/graphroot}"

mapfile -t files < <(find "$GRAPHROOT" -path '*/diff/*' -type f -size +0 2>/dev/null | head -200)
if ((${#files[@]} < 2)); then
	echo "Need at least 2 non-empty files under $GRAPHROOT" >&2
	exit 1
fi

declare -A byhash
for f in "${files[@]}"; do
	h=$(md5sum "$f" | awk '{print $1}')
	if [[ -n "${byhash[$h]:-}" ]]; then
		src="${byhash[$h]}"
		dst="$f"
		echo "Testing reflink: same md5"
		echo "  src: $src"
		echo "  dst: $dst"
		if cp --reflink=always "$src" "$dst" 2>/tmp/reflink.err; then
			echo "OK: cp --reflink=always succeeded"
		else
			echo "FAIL: cp --reflink=always failed:"
			cat /tmp/reflink.err
		fi
		in1=$(stat -c '%i' "$src")
		in2=$(stat -c '%i' "$dst")
		echo "src inode=$in1 dst inode=$in2 (same inode => already shared)"
		exit 0
	fi
	byhash[$h]=$f
done

echo "No duplicate md5 found in sample; cannot test reflink pair"
