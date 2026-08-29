package server

import (
	"context"
	"errors"
	"fmt"
	"path"

	"go.podman.io/storage"
	"golang.org/x/sys/unix"

	"github.com/cri-o/cri-o/internal/log"
	"github.com/cri-o/cri-o/utils"
)

// RunDedup runs a single storage deduplication pass using reflinks.
// It calls store.Dedup with SHA256 hashing. If showPhysicalUsage is true,
// measures real physical disk usage before and after dedup using FIEMAP (Linux only).
func RunDedup(ctx context.Context, store storage.Store, showPhysicalUsage bool) error {
	var beforeUsage uint64

	// Measure physical usage before dedup
	if showPhysicalUsage {
		log.Infof(ctx, "Measuring physical disk usage before deduplication...")

		usage, err := measurePhysicalUsage(ctx, store)
		if err != nil {
			log.Warnf(ctx, "Failed to measure initial disk usage: %v", err)
		} else {
			beforeUsage = usage
			log.Infof(ctx, "Physical disk usage before dedup: %s", formatBytes(beforeUsage))
		}
	}

	log.Infof(ctx, "Starting storage deduplication (this may take several minutes)...")

	_, err := store.Dedup(storage.DedupArgs{
		Options: storage.DedupOptions{
			HashMethod: storage.DedupHashSHA256,
		},
	})
	if err != nil {
		if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EOPNOTSUPP) {
			return fmt.Errorf("storage deduplication not supported on current filesystem: %w", err)
		}

		return fmt.Errorf("storage deduplication failed: %w", err)
	}

	log.Infof(ctx, "Storage deduplication complete")

	// Measure physical usage after dedup and show savings
	if showPhysicalUsage && beforeUsage > 0 {
		log.Infof(ctx, "Measuring physical disk usage after deduplication...")

		afterUsage, err := measurePhysicalUsage(ctx, store)
		if err != nil {
			log.Warnf(ctx, "Failed to measure final disk usage: %v", err)
		} else {
			log.Infof(ctx, "Physical disk usage after dedup: %s", formatBytes(afterUsage))

			if beforeUsage > afterUsage {
				saved := beforeUsage - afterUsage
				pct := float64(saved) / float64(beforeUsage) * 100
				log.Infof(ctx, "Space saved by deduplication: %s (%.1f%%)", formatBytes(saved), pct)
			} else {
				log.Infof(ctx, "No space savings detected (blocks may already be shared)")
			}

			// Show detailed breakdown (reuses afterUsage, only measures standard once)
			if err := reportPhysicalUsage(ctx, store, afterUsage); err != nil {
				log.Warnf(ctx, "Failed to report detailed physical disk usage: %v", err)
			}
		}
	}

	return nil
}

func measurePhysicalUsage(_ context.Context, store storage.Store) (uint64, error) {
	rootPath := store.GraphRoot()
	imagePath := store.ImageStore()
	storageDriver := store.GraphDriverName()

	var totalReal uint64

	// When imagePath is empty, everything is under rootPath
	// When imagePath is set, rootPath has containers, imagePath has images
	if imagePath == "" {
		// Single root: measure images directory only
		imagesPath := path.Join(rootPath, storageDriver+"-images")

		realBytes, _, err := utils.GetRealPhysicalUsage(imagesPath)
		if err != nil {
			return 0, fmt.Errorf("failed to get real usage for %s: %w", imagesPath, err)
		}

		totalReal += realBytes
	} else {
		// Split layout: measure both containers and images
		containersPath := path.Join(rootPath, storageDriver+"-containers")

		realBytes, _, err := utils.GetRealPhysicalUsage(containersPath)
		if err != nil {
			return 0, fmt.Errorf("failed to get real usage for %s: %w", containersPath, err)
		}

		totalReal += realBytes

		imagesPath := path.Join(imagePath, storageDriver+"-images")

		realBytes, _, err = utils.GetRealPhysicalUsage(imagesPath)
		if err != nil {
			return 0, fmt.Errorf("failed to get real usage for %s: %w", imagesPath, err)
		}

		totalReal += realBytes
	}

	return totalReal, nil
}

func reportPhysicalUsage(ctx context.Context, store storage.Store, totalRealUsage uint64) error {
	rootPath := store.GraphRoot()
	imagePath := store.ImageStore()
	storageDriver := store.GraphDriverName()

	log.Infof(ctx, "")
	log.Infof(ctx, "=== Detailed Physical Disk Usage (FIEMAP - Reflink-Aware) ===")
	log.Infof(ctx, "Storage driver: %s", storageDriver)
	log.Infof(ctx, "Graph root: %s", rootPath)

	var totalStandard uint64

	// When imagePath is empty, everything is under rootPath
	// When imagePath is set, rootPath has containers, imagePath has images
	if imagePath == "" {
		// Single root: measure standard bytes for images directory only
		imagesPath := path.Join(rootPath, storageDriver+"-images")

		log.Infof(ctx, "")
		log.Infof(ctx, "Image storage: %s", imagesPath)

		standardBytes, _, err := utils.GetDiskUsageStats(imagesPath)
		if err != nil {
			return fmt.Errorf("failed to get standard usage for %s: %w", imagesPath, err)
		}

		totalStandard += standardBytes
	} else {
		// Split layout: measure standard bytes for both containers and images
		containersPath := path.Join(rootPath, storageDriver+"-containers")

		log.Infof(ctx, "")
		log.Infof(ctx, "Container storage: %s", containersPath)

		standardBytes, _, err := utils.GetDiskUsageStats(containersPath)
		if err != nil {
			return fmt.Errorf("failed to get standard usage for %s: %w", containersPath, err)
		}

		totalStandard += standardBytes

		imagesPath := path.Join(imagePath, storageDriver+"-images")

		log.Infof(ctx, "")
		log.Infof(ctx, "Image storage: %s", imagesPath)

		standardBytes, _, err = utils.GetDiskUsageStats(imagesPath)
		if err != nil {
			return fmt.Errorf("failed to get standard usage for %s: %w", imagesPath, err)
		}

		totalStandard += standardBytes
	}

	// Summary
	log.Infof(ctx, "")
	log.Infof(ctx, "=== Summary ===")

	saved := int64(totalStandard) - int64(totalRealUsage)
	if saved > 0 {
		pct := float64(saved) / float64(totalStandard) * 100
		log.Infof(ctx, "Standard reporting (stat.Blocks): %s", formatBytes(totalStandard))
		log.Infof(ctx, "Real physical usage (FIEMAP):     %s", formatBytes(totalRealUsage))
		log.Infof(ctx, "Shared blocks from reflinks:      %s (%.1f%%)", formatBytes(uint64(saved)), pct)
	} else {
		log.Infof(ctx, "Total physical usage: %s", formatBytes(totalRealUsage))
		log.Infof(ctx, "No shared blocks detected (standard and FIEMAP match)")
	}

	return nil
}

func formatBytes(bytes uint64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}

	div, exp := uint64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}

	return fmt.Sprintf("%.2f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
