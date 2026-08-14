// Package version provides build version information.
package version

// Version and BuildTime are set via ldflags at build time.
var (
	Version   = "unknown"
	BuildTime = "unknown"
)
