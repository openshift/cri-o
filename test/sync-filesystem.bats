#!/usr/bin/env bats

# Integration tests for the overlay.sync=filesystem feature in CRI-O.
#
# overlay.sync=filesystem is an opt-in containers-storage/CRI-O option that
# calls syncfs() before committing layer metadata to disk.  When enabled,
# a hard process kill (or kernel crash) mid-pull leaves the store in a
# deterministically recoverable state:
#
#   1.  The incompleteFlag ("incomplete"=true in layers.json) is written
#       *before* any layer data is extracted — so it is always present on disk
#       even after a SIGKILL.
#   2.  syncfs() is called *after* all layer data is written but *before* the
#       final metadata commit that clears the flag — guaranteeing that if the
#       flag is absent, all layer data is durable.
#
# On restart, containers/storage load() detects incomplete-flagged layers and
# discards them, leaving the store clean without any escalated repair.
#
# Test coverage:
#   - A successfully committed image must survive a CRI-O restart.
#   - An incomplete layer left by a hard kill must be removed on restart.
#   - Pull-time overhead of sync=filesystem is measured and logged
#            (informational — no hard pass/fail threshold).
#   - Negative control — without sync=filesystem CRI-O must still recover
#            from a hard kill (repair always works; this documents the comparison).
#

load helpers

# Large multi-layer image 
SYNCFS_IMAGE="quay.io/crio/fedora-crio-ci:latest"

function setup() {
	setup_test
	# Enable overlay.sync=filesystem for every test in this file.
	# STORAGE_OPTIONS is picked up by setup_crio(); tests that need the
	# negative-control path override it locally before calling setup_crio.
	STORAGE_OPTIONS="${STORAGE_OPTIONS:+$STORAGE_OPTIONS }--storage-opt overlay.sync=filesystem"
}

function teardown() {
	cleanup_test
}

#
# With sync=filesystem, the final metadata commit (clearing incompleteFlag) is
# preceded by syncfs().  A clean restart must find the layer intact, load it
# from the same on-disk state, and report the same image ID.
@test "images pulled with sync=filesystem survive a CRI-O restart" {
	setup_crio
	start_crio_no_setup

	crictl pull "$SYNCFS_IMAGE"
	local image_id
	image_id=$(crictl images -q "$SYNCFS_IMAGE")
	[ -n "$image_id" ]

	# Graceful stop + restart from the same on-disk storage directory.
	# Does NOT call setup_crio again so no config is regenerated.
	stop_crio_no_clean ""
	start_crio_no_setup

	local image_id_after
	image_id_after=$(crictl images -q "$SYNCFS_IMAGE")
	[ "$image_id_after" = "$image_id" ]
}

# ── Incomplete-layer cleanup after hard kill ─────────────────────────────────
#
# A hard kill (SIGKILL / kernel crash) mid-pull leaves containers/storage with
# a layer whose incompleteFlag is still "true" in layers.json: the flag is
# persisted *before* any layer data is written, and cleared only after
# syncfs() + the final metadata commit. On next startup, load() must detect
# and discard any incomplete-flagged layer, logging "Found incomplete layer".
#
# Racing a real "kill mid-pull" against a timer is flaky in this environment:
# once an image's blobs are warm in the local blob-info-cache, the entire
# pull+extract can finish in well under a second, so there is no reliable
# window in which to land the kill. We instead inject the fault directly.
#
# The injected layer is a synthetic ORPHAN (no parent, no names) rather than
# one of the pulled image's real layers, matching what a real interrupted
# pull actually leaves behind — an image record is only committed once every
# layer in its chain is complete, so a genuinely incomplete layer never has
# an image depending on it.
@test "CRI-O removes an incomplete layer left by a hard kill mid-pull" {
	setup_crio
	start_crio_no_setup

	# Establish a real, fully-committed image so we can assert afterward that
	# it is completely unaffected by the unrelated orphan layer's cleanup.
	crictl pull "$SYNCFS_IMAGE"
	local image_id
	image_id=$(crictl images -q "$SYNCFS_IMAGE")
	[ -n "$image_id" ]

	# Stop CRI-O cleanly so layers.json is fully flushed and consistent before
	# we inject the fault.
	stop_crio_no_clean ""

	local layers_json
	layers_json=$(find "$TESTDIR/crio" -maxdepth 2 -name 'layers.json' 2>/dev/null | head -1)
	[ -n "$layers_json" ]

	# Append a synthetic orphan layer flagged incomplete. It has no "parent"
	# and no "names", so nothing (no image, no other layer) references it —
	# deleting it on startup cannot affect the real image pulled above.
	local fake_id="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	jq --arg id "$fake_id" \
		'. + [{"id": $id, "flags": {"incomplete": true}}]' \
		"$layers_json" >"$layers_json.tmp"
	mv "$layers_json.tmp" "$layers_json"

	# Restart CRI-O. containers/storage load() must detect the incomplete-
	# flagged orphan layer and discard it automatically on this startup.
	start_crio_no_setup

	# Confirm cleanup was logged for exactly the injected orphan layer.
	# (Avoid matching literal quote characters around the ID: logrus's text
	# formatter escapes them as \" and exact rendering is formatter-version
	# dependent, so match the substring loosely instead.)
	run grep -c "Found incomplete layer.*$fake_id" "$CRIO_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]

	# The real image pulled above must be completely unaffected.
	run crictl images -q "$SYNCFS_IMAGE"
	[ "$status" -eq 0 ]
	[ "$output" = "$image_id" ]
}

# Pull-time overhead measurement  ─────────────────────
#
# Pass criteria from the test plan: "Overhead is documented as a factual data
# point.  There is no hard pass/fail threshold unless one is agreed with the
# team."  This test always passes; results appear in the CI log.
@test "pull-time overhead of overlay.sync=filesystem is within acceptable range (informational)" {
	local -i runs=3
	local -a times_with=()
	local -a times_without=()

	# --- Timed pulls WITH sync=filesystem ---
	setup_crio
	start_crio_no_setup

	local i start end
	for ((i = 0; i < runs; i++)); do
		crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true
		start=$(date +%s%3N)
		crictl pull "$SYNCFS_IMAGE"
		end=$(date +%s%3N)
		times_with+=($((end - start)))
	done

	# --- Timed pulls WITHOUT sync=filesystem ---
	# Reconfigure with sync disabled for a back-to-back comparison on the
	# same node under equivalent conditions.
	stop_crio_no_clean ""
	STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	for ((i = 0; i < runs; i++)); do
		crictl rmi "$SYNCFS_IMAGE" 2>/dev/null || true
		start=$(date +%s%3N)
		crictl pull "$SYNCFS_IMAGE"
		end=$(date +%s%3N)
		times_without+=($((end - start)))
	done

	# Compute averages and emit results to the BATS tap stream (>&3).
	local sum_with=0 sum_without=0
	for t in "${times_with[@]}"; do ((sum_with += t)); done
	for t in "${times_without[@]}"; do ((sum_without += t)); done
	local avg_with=$((sum_with / runs))
	local avg_without=$((sum_without / runs))
	local delta=$((avg_with - avg_without))

	echo "#  performance results — informational, no hard threshold:" >&3
	echo "#   sync=filesystem: avg ${avg_with}ms over ${runs} runs (${times_with[*]})" >&3
	echo "#   sync=none:       avg ${avg_without}ms over ${runs} runs (${times_without[*]})" >&3
	echo "#   delta:           ${delta}ms" >&3
}

# ──  Negative control — recovery without sync=filesystem ────────────────
#
# Without sync=filesystem, a hard kill mid-pull must still not leave the
# store permanently broken: the incompleteFlag mechanism operates regardless of
# sync mode, so incomplete layers are always cleaned up on restart.
# The distinction from the test above is that without syncfs(), layer
# *content* on disk may be inconsistent at the block level after a real
# power-loss event — but that cannot be demonstrated without kernel-level
# fault injection (dm-flakey).
@test "CRI-O still recovers from a hard kill without sync=filesystem (negative control)" {
	# Explicitly disable sync=filesystem for this negative-control test.
	STORAGE_OPTIONS="" setup_crio
	start_crio_no_setup

	crictl pull "$SYNCFS_IMAGE" &
	local pull_pid=$!
	sleep 3

	# Same fix as UC-08: swallow the expected 128+9 wait exit status.
	kill -9 "$CRIO_PID" 2>/dev/null || true
	wait "$CRIO_PID" 2>/dev/null || true
	unset CRIO_PID
	kill "$pull_pid" 2>/dev/null || true

	# Must start cleanly even without the syncfs durability guarantee.
	start_crio_no_setup

	run crictl images
	[ "$status" -eq 0 ]
}
