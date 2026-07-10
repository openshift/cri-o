#!/usr/bin/env bash
# Scale test for crio storage dedup (OCPNODE-4588).
#
# Builds NUM_IMAGES container images with:
#   - varied per-image sizes (unique random layer)
#   - duplicated file content across images in DISTINCT layers (same bytes, different
#     layer digest — podman layer reuse would otherwise hide duplicates from dedup)
#
# Then runs `crio dedup`, records wall time, disk usage, and bytes saved.
#
# Usage (pass env vars before sudo; -E is optional and often ignored):
#   export GRAPHROOT=/var/tmp/crio-storage/graphroot
#   export RUNROOT=/var/tmp/crio-storage/runroot
#   sudo NUM_IMAGES=10 ./test/dedup-scale-test.sh
#
# Options (env):
#   NUM_IMAGES=100          number of images to build (default: 100)
#   SKIP_BUILD=1            skip image build, only run dedup
#   FRESH=1                 wipe graphroot/runroot before building
#   CRIO_BIN=./bin/crio
#   CRIO_CONF=/etc/crio/crio.conf
#   RESULTS_FILE=/tmp/dedup-scale-results.txt
#   TEST_WORKDIR=/var/tmp/crio-storage/dedup-scale-work  # build staging (default: next to graphroot)

set -euo pipefail

NUM_IMAGES="${NUM_IMAGES:-100}"
GRAPHROOT="${GRAPHROOT:-/var/tmp/crio-storage/graphroot}"
RUNROOT="${RUNROOT:-/var/tmp/crio-storage/runroot}"
CRIO_BIN="${CRIO_BIN:-./bin/crio}"
CRIO_CONF="${CRIO_CONF:-/etc/crio/crio.conf}"
RESULTS_FILE="${RESULTS_FILE:-/tmp/dedup-scale-results.txt}"
TEST_WORKDIR="${TEST_WORKDIR:-$(dirname "$GRAPHROOT")/dedup-scale-work}"
SKIP_BUILD="${SKIP_BUILD:-0}"
FRESH="${FRESH:-0}"

WORKDIR=""

PODMAN=(podman --root "$GRAPHROOT" --runroot "$RUNROOT" --storage-driver overlay)

cleanup() {
	if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT

log() {
	echo "[$(date -Iseconds)] $*" >&2
}

require_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		echo "Run as root: sudo NUM_IMAGES=10 $0" >&2
		exit 1
	fi
}

check_reflink() {
	local mountpoint
	mountpoint=$(findmnt -n -o TARGET --target "$GRAPHROOT" 2>/dev/null || true)
	if [[ -z "$mountpoint" ]]; then
		log "WARN: could not determine mount for $GRAPHROOT"
		return
	fi
	if command -v xfs_info >/dev/null 2>&1; then
		if ! xfs_info "$mountpoint" 2>/dev/null | grep -q 'reflink=1'; then
			log "WARN: $mountpoint may not have XFS reflink=1; dedup may report no savings"
		fi
	else
		log "WARN: xfs_info not found; assuming reflink is configured"
	fi
}

# CRI-O reads root/runroot from [crio], NOT [crio.storage]. Wrong section => dedup hits
# the default /var/lib/containers/storage while podman populated $GRAPHROOT.
write_crio_conf() {
	local conf="${CRIO_CONF:-/etc/crio/crio.conf}"
	mkdir -p "$(dirname "$conf")"
	cat >"$conf" <<EOF
# Written by dedup-scale-test.sh — storage keys must be under [crio]
[crio]
root = "$GRAPHROOT"
runroot = "$RUNROOT"
storage_driver = "overlay"
EOF
	log "Wrote $conf (root=$GRAPHROOT)"
}

graphroot_mount() {
	findmnt -n -o TARGET --target "$GRAPHROOT" 2>/dev/null || df -P "$GRAPHROOT" | awk 'NR==2 {print $NF}'
}

# Logical sum of file sizes (st_size). Reflink dedup shares disk blocks but does NOT
# shrink this number — each path still reports its full size.
du_apparent_bytes() {
	du -sb "$GRAPHROOT" 2>/dev/null | awk '{print $1}'
}

# Best-effort block usage under graphroot (st_blocks). May still over-count shared
# XFS reflink extents depending on kernel/tools; prefer df_used_bytes for savings.
du_disk_bytes() {
	du -s --block-size=1 "$GRAPHROOT" 2>/dev/null | awk '{print $1}'
}

# Actual bytes used on the filesystem hosting GRAPHROOT — this drops after reflink dedup.
df_used_bytes() {
	local mountpoint=${1:-}
	local used
	if [[ -z "$mountpoint" ]]; then
		mountpoint=$(graphroot_mount)
	fi
	used=$(df -B1 --output=used "$mountpoint" 2>/dev/null | tail -1 | tr -d ' ')
	if [[ -z "$used" || ! "$used" =~ ^[0-9]+$ ]]; then
		echo 0
	else
		echo "$used"
	fi
}

human_bytes() {
	numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
}

prepare_shared_blobs() {
	local workdir=$1
	local shared_dir="$workdir/shared-blobs"
	mkdir -p "$shared_dir"

	local sizes_mb=(1 2 5 10 10 20 20 50)
	local i=0
	for size in "${sizes_mb[@]}"; do
		local f="$shared_dir/shared-$(printf '%02d' "$i")-${size}mb.dat"
		if [[ ! -f "$f" ]]; then
			log "Creating shared blob $(basename "$f")"
			dd if=/dev/urandom of="$f" bs=1M count="$size" status=none
		fi
		i=$((i + 1))
	done

	echo "$shared_dir"
}

build_images() {
	local workdir=$1
	local shared_dir=$2
	local build_start build_end build_secs n

	log "Building $NUM_IMAGES images into $GRAPHROOT (this may take a while)..."

	"${PODMAN[@]}" pull docker.io/library/alpine:3.19 >/dev/null 2>&1

	build_start=$(date +%s)

	for n in $(seq 1 "$NUM_IMAGES"); do
		local tag="localhost/dedup-scale-$(printf '%03d' "$n"):latest"
		local ctx="$workdir/build-$n"
		mkdir -p "$ctx"

		local b0=$(( (n - 1) % 8 ))
		local b1=$(( (n + 2) % 8 ))
		local b2=$(( (n + 5) % 8 ))
		local blob0 blob1 blob2
		blob0=$(ls "$shared_dir"/shared-$(printf '%02d' "$b0")-*)
		blob1=$(ls "$shared_dir"/shared-$(printf '%02d' "$b1")-*)
		blob2=$(ls "$shared_dir"/shared-$(printf '%02d' "$b2")-*)

		local unique_mb=$(( (n % 15) + 1 ))
		dd if=/dev/urandom of="$ctx/unique.dat" bs=1M count="$unique_mb" status=none
		echo "layer-marker-$n" >"$ctx/layer-marker.txt"

		cp "$blob0" "$ctx/blob0.dat"
		cp "$blob1" "$ctx/blob1.dat"
		cp "$blob2" "$ctx/blob2.dat"

		# Shared blob bytes are identical across images, but each COPY layer also
		# includes a per-image marker so podman cannot reuse the layer (different
		# digest, duplicate bytes on disk — what crio dedup should collapse).
		cat >"$ctx/Dockerfile" <<EOF
FROM alpine:3.19
COPY blob0.dat blob1.dat blob2.dat layer-marker.txt /shared/
COPY unique.dat /app/unique.dat
RUN echo dedup-scale-$n > /app/id.txt
EOF

		if ! "${PODMAN[@]}" build -q -t "$tag" "$ctx" >/dev/null 2>&1; then
			log "ERROR: build failed for $tag"
			exit 1
		fi

		rm -rf "$ctx"

		if (( n % 10 == 0 )); then
			log "Built $n / $NUM_IMAGES images..."
		fi
	done

	build_end=$(date +%s)
	build_secs=$((build_end - build_start))
	log "Image build complete in ${build_secs}s ($(( build_secs / 60 ))m $(( build_secs % 60 ))s)"
	printf '%s' "$build_secs"
}

run_dedup() {
	local dedup_log=$1
	local start end elapsed

	log "Running crio dedup..."
	start=$(date +%s)
	# Log to file and stderr only; stdout stays clean for timing capture.
	"$CRIO_BIN" -c "$CRIO_CONF" dedup 2>&1 | tee "$dedup_log" >&2
	end=$(date +%s)
	elapsed=$((end - start))
	log "Dedup finished in ${elapsed}s"
	printf '%s' "$elapsed"
}

parse_saved_line() {
	local dedup_log=$1
	if grep -q 'no savings' "$dedup_log"; then
		echo "no savings"
	else
		grep 'Storage deduplication complete:' "$dedup_log" | tail -1 | sed 's/.*msg="//;s/"$//' || echo "unknown"
	fi
}

diagnose_on_disk_duplicates() {
	local pattern=${1:-'*/diff/shared/blob0.dat'}
	local count unique_md5 unique_inodes
	count=$(find "$GRAPHROOT" -path "$pattern" 2>/dev/null | wc -l | tr -d ' ')
	unique_md5=$(find "$GRAPHROOT" -path "$pattern" -exec md5sum {} + 2>/dev/null | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
	unique_inodes=$(find "$GRAPHROOT" -path "$pattern" -exec stat -c '%d:%i' {} + 2>/dev/null | sort -u | wc -l | tr -d ' ')
	log "On-disk duplicates ($pattern): files=$count unique_md5=$unique_md5 unique_inodes=$unique_inodes"
	if [[ "$count" -gt 0 && "$unique_md5" == "1" && "$unique_inodes" == "$count" ]]; then
		log "OK: identical content with separate inodes — dedup should be able to save space"
	elif [[ "$count" -gt 0 && "$unique_inodes" -lt "$count" ]]; then
		log "NOTE: some files already share inodes (partial dedup/hardlink at build time)"
	fi
}

main() {
	require_root
	check_reflink

	if [[ ! -x "$CRIO_BIN" ]]; then
		echo "CRI-O binary not found: $CRIO_BIN" >&2
		exit 1
	fi

	write_crio_conf

	if [[ "$FRESH" == "1" ]]; then
		log "FRESH=1: wiping $GRAPHROOT and $RUNROOT"
		rm -rf "$GRAPHROOT" "$RUNROOT"
		mkdir -p "$GRAPHROOT" "$RUNROOT"
		rm -rf "$TEST_WORKDIR"
	fi

	mkdir -p "$TEST_WORKDIR"
	WORKDIR=$(mktemp -d "$TEST_WORKDIR/run.XXXXXX")
	log "Build staging dir: $WORKDIR (on same mount as graphroot; avoids filling /tmp)"

	local build_secs=0
	if [[ "$SKIP_BUILD" != "1" ]]; then
		local shared_dir
		shared_dir=$(prepare_shared_blobs "$WORKDIR")
		build_secs=$(build_images "$WORKDIR" "$shared_dir")
	else
		log "SKIP_BUILD=1: using existing storage"
	fi

	local image_count mountpoint
	local before_apparent after_apparent before_fs after_fs before_du after_du
	local dedup_log dedup_secs delta_fs delta_apparent saved_line
	mountpoint=$(graphroot_mount)
	image_count=$("${PODMAN[@]}" images -q 2>/dev/null | wc -l | tr -d ' ')
	before_apparent=$(du_apparent_bytes)
	before_du=$(du_disk_bytes)
	before_fs=$(df_used_bytes "$mountpoint")

	log "Storage before dedup (filesystem $mountpoint): $(human_bytes "$before_fs") used on disk"
	log "Storage before dedup (graphroot apparent): $(human_bytes "$before_apparent") ($before_apparent bytes)"
	log "Images in store: $image_count"
	diagnose_on_disk_duplicates '*/diff/shared/blob0.dat'

	dedup_log="$WORKDIR/dedup.log"
	dedup_secs=$(run_dedup "$dedup_log")

	after_apparent=$(du_apparent_bytes)
	after_du=$(du_disk_bytes)
	after_fs=$(df_used_bytes "$mountpoint")
	delta_fs=$((before_fs - after_fs))
	delta_apparent=$((before_apparent - after_apparent))
	saved_line=$(parse_saved_line "$dedup_log")

	{
		echo "=============================================="
		echo "CRI-O storage dedup scale test results"
		echo "Date: $(date -Iseconds)"
		echo "Host: $(hostname)"
		echo "NUM_IMAGES (requested): $NUM_IMAGES"
		echo "Images in store: $image_count"
		echo "GRAPHROOT: $GRAPHROOT"
		echo "Mount: $mountpoint"
		echo "----------------------------------------------"
		echo "Build time: ${build_secs}s"
		echo "Dedup wall time: ${dedup_secs}s"
		echo "Filesystem used before dedup: $(human_bytes "$before_fs") ($before_fs bytes)"
		echo "Filesystem used after dedup:  $(human_bytes "$after_fs") ($after_fs bytes)"
		echo "Filesystem delta (before-after): $(human_bytes "$delta_fs") ($delta_fs bytes)"
		echo "Graphroot apparent size before: $(human_bytes "$before_apparent") ($before_apparent bytes)"
		echo "Graphroot apparent size after:  $(human_bytes "$after_apparent") ($after_apparent bytes)"
		echo "Graphroot apparent delta: $(human_bytes "$delta_apparent") ($delta_apparent bytes)"
		echo "Graphroot block usage (du -s) before: $(human_bytes "$before_du") ($before_du bytes)"
		echo "Graphroot block usage (du -s) after:  $(human_bytes "$after_du") ($after_du bytes)"
		echo "crio dedup reported: $saved_line"
		echo "----------------------------------------------"
		echo "Notes:"
		echo "- Reflink dedup shares physical disk blocks; file logical sizes are unchanged."
		echo "  du -sb (apparent size) often stays flat — use filesystem used (df) for real savings."
		echo "- Each image COPY layer includes identical shared blobs plus a unique marker"
		echo "  so podman does not reuse layers and duplicates remain on disk for dedup."
		echo "- Unique per-image layer sizes vary 1-15 MB."
		echo "- Report dedup wall time for boot SLA; build time is one-time, not per reboot."
		echo "=============================================="
	} | tee "$RESULTS_FILE"

	log "Results written to $RESULTS_FILE"
}

main "$@"
