package main

import (
	"context"
	stdfs "io/fs"
	"slices"
	"strings"
	"testing"

	iceio "github.com/apache/iceberg-go/io"
	"github.com/apache/iceberg-go/io/gocloud/blobfs"
	"gocloud.dev/blob/memblob"
)

// memTable returns a blob FileIO over an in-memory bucket holding one table
// directory with an object at exactly its data path, which is how an ADLS Gen2
// account with a hierarchical namespace lists a directory.
func memTable(t *testing.T) *blobfs.FileIO {
	t.Helper()
	ctx := context.Background()
	bucket := memblob.OpenBucket(nil)
	t.Cleanup(func() { _ = bucket.Close() })
	for _, key := range []string{"t/data", "t/data/a.parquet", "t/metadata/v1.metadata.json"} {
		if err := bucket.WriteAll(ctx, key, []byte("x"), nil); err != nil {
			t.Fatal(err)
		}
	}
	return blobfs.New(ctx, bucket, blobfs.DefaultObjectLocationExtractor("bkt", "s3"))
}

// walkPaths collects every path a walk reports, failing on the first error the
// way iceberg-go's orphan cleanup does.
func walkPaths(walk func(string, stdfs.WalkDirFunc) error) ([]string, error) {
	var got []string
	err := walk("s3://bkt/t", func(path string, _ stdfs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		got = append(got, path)
		return nil
	})
	return got, err
}

// iceberg-go's own walk dies on an object at a directory path. When this test
// fails, the collision is gone and so can flatWalkIO be.
func TestBlobWalkDir_ObjectAtDirectoryPathFails(t *testing.T) {
	_, err := walkPaths(memTable(t).WalkDir)
	if err == nil || !strings.Contains(err.Error(), "not implemented") {
		t.Fatalf("iceberg-go's walk returned %v, want the readdir failure flatWalkIO avoids", err)
	}
}

func TestFlatWalkIO_ListsObjectAtDirectoryPath(t *testing.T) {
	got, err := walkPaths(flatWalkIO{memTable(t)}.WalkDir)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"s3://bkt/t/data", "s3://bkt/t/data/a.parquet", "s3://bkt/t/metadata/v1.metadata.json"}
	if !slices.Equal(got, want) {
		t.Errorf("walked %v, want %v", got, want)
	}
}

// The FileIO iceberg-go loads for an object store is a *blobfs.FileIO, which is
// what flatWalkIO lists through; any other type takes the wrapped walk.
func TestLoadFS_ObjectStoreIsBlobFileIO(t *testing.T) {
	fio, err := iceio.LoadFS(context.Background(), map[string]string{
		iceio.S3Region:          "us-east-1",
		iceio.S3EndpointURL:     "http://127.0.0.1:9",
		iceio.S3AccessKeyID:     "key",
		iceio.S3SecretAccessKey: "secret",
	}, "s3://bkt/t")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := fio.(*blobfs.FileIO); !ok {
		t.Fatalf("LoadFS returned %T, not *blobfs.FileIO", fio)
	}
}

func TestListPrefix(t *testing.T) {
	cases := []struct{ in, want string }{
		// Table dir (no trailing slash): must gain one so the request prefix
		// satisfies the vended s3:ListBucket condition "<table-dir>/*".
		{"/coldfront/ns-uuid/tbl-uuid", "coldfront/ns-uuid/tbl-uuid/"},
		{"coldfront/ns-uuid/tbl-uuid", "coldfront/ns-uuid/tbl-uuid/"},
		// Already slash-terminated: unchanged.
		{"/coldfront/ns-uuid/tbl-uuid/", "coldfront/ns-uuid/tbl-uuid/"},
		// Bucket root: empty prefix, left empty (no phantom "/").
		{"/", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := listPrefix(c.in); got != c.want {
			t.Errorf("listPrefix(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
