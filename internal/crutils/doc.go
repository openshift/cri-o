// UPSTREAM: <carry>: crutils carried from go.podman.io/common/pkg/crutils
//
// This package is a copy of crutils from the upstream go.podman.io/common
// module. It is carried here because the downstream container libs fork
// (podman 5.8 rhel branch on gitlab.cee) uses go-criu/v7, while CRI-O
// uses go-criu/v8. Both versions register the same protobuf file
// (stats/stats.proto), causing a runtime panic. This copy imports
// go-criu/v8 instead of v7 to avoid the conflict.
//
// When the downstream container libs fork upgrades to go-criu/v8,
// this carry patch should be removed and the import paths reverted
// to go.podman.io/common/pkg/crutils.
package crutils
