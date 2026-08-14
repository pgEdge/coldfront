package version

import "testing"

// The defaults are placeholders the Makefile overrides; a binary must never
// print an empty version line.
func TestDefaultsNonEmpty(t *testing.T) {
	if Version == "" || BuildTime == "" {
		t.Errorf("Version = %q, BuildTime = %q; want non-empty defaults", Version, BuildTime)
	}
}
