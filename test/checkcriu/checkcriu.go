package main

import (
	"os"

	"github.com/containers/podman/v4/pkg/criu"
)

func main() {
	if err := criu.CheckForCriu(criu.PodCriuVersion); err != nil {
		os.Exit(1)
	}

	os.Exit(0)
}
