package partcfg

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/pgedge/coldfront/internal/watermark"
)

// extensionTableDDL returns the CREATE TABLE block for one table from the
// extension's install script, without its trailing comments and semicolon.
func extensionTableDDL(t *testing.T, table string) string {
	t.Helper()
	script, err := os.ReadFile("../../extension/coldfront/coldfront--1.0.sql")
	if err != nil {
		t.Fatal(err)
	}
	head := "CREATE TABLE IF NOT EXISTS coldfront." + table + " ("
	start := strings.Index(string(script), head)
	if start < 0 {
		t.Fatalf("%s not found in the extension script", head)
	}
	end := strings.Index(string(script)[start:], "\n);")
	if end < 0 {
		t.Fatalf("%s: no closing line in the extension script", head)
	}
	return regexp.MustCompile(`--[^\n]*`).ReplaceAllString(string(script)[start:start+end+2], "")
}

// tokens collapses whitespace so two spellings of one DDL compare equal.
func tokens(ddl string) string {
	return strings.Join(strings.Fields(ddl), " ")
}

// The Go copies of the two tables the extension owns are what a database gets
// when the partitioner or the archiver runs before CREATE EXTENSION, and the
// extension adopts those tables as its own at install. So each copy has to be
// the extension's DDL, token for token.
func TestMirrorDDL_MatchesExtension(t *testing.T) {
	for table, mirror := range map[string]string{
		"partition_config":  CreateTableSQL,
		"archive_watermark": watermark.CreateTableSQL,
	} {
		if got, want := tokens(mirror), tokens(extensionTableDDL(t, table)); got != want {
			t.Errorf("%s: the Go copy differs from the extension script\n got: %s\nwant: %s", table, got, want)
		}
	}
}
