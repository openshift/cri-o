#!/usr/bin/env bats

load helpers

function setup() {
	setup_test
}

function teardown() {
	cleanup_test
}

@test "dedup: crio dedup command succeeds with populated storage" {
	start_crio

	# Populate storage with images
	crictl pull "$IMAGE_LIST"

	# Stop crio before running dedup (dedup should run while crio is stopped)
	stop_crio

	run "$CRIO_BINARY_PATH" \
		-c "$CRIO_CONFIG" \
		-d "$CRIO_CONFIG_DIR" \
		dedup

	[ "$status" -eq 0 ]
	[[ "$output" == *"Starting storage deduplication"* ]]
	[[ "$output" == *"Storage deduplication complete"* ]]

	# Dedup may or may not find duplicates to deduplicate - both are valid outcomes
	# The important thing is it completes successfully
}

@test "dedup: crio dedup with --physical-disk-usage on populated storage" {
	start_crio

	# Populate storage with images
	crictl pull "$IMAGE_LIST"

	# Stop crio before running dedup
	stop_crio

	run "$CRIO_BINARY_PATH" \
		-c "$CRIO_CONFIG" \
		-d "$CRIO_CONFIG_DIR" \
		dedup --physical-disk-usage

	[ "$status" -eq 0 ]
	[[ "$output" == *"Starting storage deduplication"* ]]
	[[ "$output" == *"Storage deduplication complete"* ]]
	[[ "$output" == *"Measuring physical disk usage before deduplication"* ]]
	[[ "$output" == *"Measuring physical disk usage after deduplication"* ]]
	[[ "$output" == *"Physical disk usage"* ]]

	# Should show either savings or "No space savings detected"
	# Both are valid outcomes depending on whether dedup found duplicates
}

@test "dedup: server remains functional after dedup on populated storage" {
	start_crio

	# Populate storage with images and containers
	crictl pull "$IMAGE_LIST"
	pod_id=$(crictl runp "$TESTDATA"/sandbox_config.json)
	crictl stopp "$pod_id"
	crictl rmp "$pod_id"

	# Stop crio and run dedup
	stop_crio

	run "$CRIO_BINARY_PATH" \
		-c "$CRIO_CONFIG" \
		-d "$CRIO_CONFIG_DIR" \
		dedup

	[ "$status" -eq 0 ]

	# Restart and verify server still works
	start_crio

	# Verify we can still create and run pods after dedup
	pod_id=$(crictl runp "$TESTDATA"/sandbox_config.json)
	crictl stopp "$pod_id"
	crictl rmp "$pod_id"
}
