package criocli

import (
	"fmt"

	"github.com/urfave/cli/v2"

	"github.com/cri-o/cri-o/internal/log"
	"github.com/cri-o/cri-o/server"
)

// DedupCommand is the `crio dedup` subcommand for running storage
// deduplication on demand. It opens the storage, runs deduplication
// using reflinks, and reports the result. This should be run while
// CRI-O is stopped to avoid lock contention with image pulls.
var DedupCommand = &cli.Command{
	Name:  "dedup",
	Usage: "deduplicate image storage using reflinks",
	Description: `Deduplicate identical files across container image layers using
filesystem-level reflinks (copy-on-write clones). This reduces disk
usage without the drawbacks of hard links, as modifying one copy does
not affect others.

Requires a filesystem that supports reflinks (e.g., XFS with reflink=1
or Btrfs). On unsupported filesystems, the command exits with an error.

This command should be run while CRI-O is stopped to avoid lock
contention with image pull operations.`,
	Action: crioDedup,
	Flags: []cli.Flag{
		&cli.BoolFlag{
			Name:    "physical-disk-usage",
			Aliases: []string{"p"},
			Usage:   "report real physical disk usage after dedup (FIEMAP-based, Linux only)",
		},
	},
}

func crioDedup(c *cli.Context) error {
	ctx := c.Context

	config, err := GetConfigFromContext(c)
	if err != nil {
		return fmt.Errorf("unable to load configuration: %w", err)
	}

	store, err := config.GetStore()
	if err != nil {
		return fmt.Errorf("unable to open storage: %w", err)
	}

	defer func() {
		if _, err := store.Shutdown(true); err != nil {
			log.Errorf(ctx, "Unable to shutdown storage: %v", err)
		}
	}()

	showPhysicalUsage := c.Bool("physical-disk-usage")

	return server.RunDedup(ctx, store, showPhysicalUsage)
}
