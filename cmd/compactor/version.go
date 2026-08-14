package main

// Version and BuildTime are set via ldflags at build time. A copy of
// internal/version, carried here because this module quarantines its heavy
// dependencies from the main module and takes no edge back to it for two
// variables.
var (
	Version   = "unknown"
	BuildTime = "unknown"
)
