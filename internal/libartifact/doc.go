// UPSTREAM: <carry>: libartifact carried from go.podman.io/common/pkg/libartifact
//
// This package is a copy of the libartifact implementation from the upstream
// go.podman.io/common module (pre podman 5.8 version). It is carried here
// because the downstream container libs fork (podman 5.8 rhel branch on
// gitlab.cee) does not include this implementation, and CRI-O requires it
// for OCI Artifact mount functionality.
//
// When the downstream container libs fork includes a compatible libartifact
// implementation, this carry patch should be removed and the import paths
// reverted to go.podman.io/common/pkg/libartifact.
package libartifact
