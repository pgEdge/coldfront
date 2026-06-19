package main

import (
	"context"
	"fmt"
	"io"
	stdfs "io/fs"
	"net/url"
	"reflect"
	"strings"
	"time"

	iceio "github.com/apache/iceberg-go/io"
	"github.com/apache/iceberg-go/table"
	"gocloud.dev/blob"
)

// flatWalkIO wraps an iceberg-go FileIO and replaces WalkDir with a FLAT object
// list (no delimiter). iceberg-go's blob WalkDir does a hierarchical fs.WalkDir
// whose per-path Open() decides directory-vs-file via Exists(): on an object
// store an object at exactly a "directory" path (e.g. .../data) collides with
// the .../data/ prefix, gets returned by List as BOTH a file and a directory,
// and the recursive ReadDir on the phantom directory fails with the Go stdlib's
// literal "readdir …: not implemented". A flat list never opens a path as a
// directory, so the collision cannot occur. Everything else delegates to the
// wrapped FileIO, and orphan reachability + deletion stay iceberg-go's.
type flatWalkIO struct {
	iceio.IO
}

func (f flatWalkIO) WalkDir(root string, fn stdfs.WalkDirFunc) error {
	bucket, err := bucketOf(f.IO)
	if err != nil {
		// Non-blob backend (e.g. local FS): defer to the wrapped walk.
		if lw, ok := f.IO.(iceio.ListableIO); ok {
			return lw.WalkDir(root, fn)
		}
		return err
	}
	u, err := url.Parse(root)
	if err != nil {
		return fmt.Errorf("invalid URL %s: %w", root, err)
	}
	prefix := strings.TrimPrefix(u.Path, "/")
	iter := bucket.List(&blob.ListOptions{Prefix: prefix}) // empty Delimiter => flat
	for {
		obj, err := iter.Next(context.Background())
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if obj.IsDir { // not set without a delimiter, but be defensive
			continue
		}
		full := *u
		full.Path = "/" + obj.Key // preserve scheme + container@host, swap the key
		if err := fn(full.String(), flatDirEntry{obj}, nil); err != nil {
			return err
		}
	}
	return nil
}

// bucketOf extracts the *blob.Bucket from a gocloud-backed iceberg FileIO by
// reflection — the same access iceberg-go itself uses internally
// (table/orphan_cleanup.go getBucketName). Errors for a non-blob FileIO.
func bucketOf(fio iceio.IO) (*blob.Bucket, error) {
	v := reflect.ValueOf(fio)
	if v.Kind() == reflect.Pointer {
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return nil, fmt.Errorf("FileIO %T is not a struct", fio)
	}
	field := v.FieldByName("Bucket")
	if !field.IsValid() {
		return nil, fmt.Errorf("FileIO %T has no Bucket field", fio)
	}
	b, ok := field.Interface().(*blob.Bucket)
	if !ok {
		return nil, fmt.Errorf("FileIO %T Bucket field is not *blob.Bucket", fio)
	}
	return b, nil
}

// flatDirEntry / flatFileInfo adapt a gocloud ListObject to fs.DirEntry so
// iceberg-go's scanFiles can read ModTime/Size for the orphan-age filter.
type flatDirEntry struct{ obj *blob.ListObject }

func (e flatDirEntry) Name() string                  { return e.obj.Key }
func (e flatDirEntry) IsDir() bool                   { return false }
func (e flatDirEntry) Type() stdfs.FileMode          { return 0 }
func (e flatDirEntry) Info() (stdfs.FileInfo, error) { return flatFileInfo(e), nil }

type flatFileInfo struct{ obj *blob.ListObject }

func (i flatFileInfo) Name() string         { return i.obj.Key }
func (i flatFileInfo) Size() int64          { return i.obj.Size }
func (i flatFileInfo) Mode() stdfs.FileMode { return 0 }
func (i flatFileInfo) ModTime() time.Time   { return i.obj.ModTime }
func (i flatFileInfo) IsDir() bool          { return false }
func (i flatFileInfo) Sys() any             { return nil }

// withFlatWalk reconstructs tbl so DeleteOrphanFiles walks via flatWalkIO.
// Orphan cleanup only reads metadata and lists/deletes files — it never calls
// the catalog — so a nil CatalogIO is safe here.
func withFlatWalk(ctx context.Context, tbl *table.Table) (*table.Table, error) {
	realIO, err := tbl.FS(ctx)
	if err != nil {
		return nil, err
	}
	fsF := func(context.Context) (iceio.IO, error) { return flatWalkIO{realIO}, nil }
	return table.New(tbl.Identifier(), tbl.Metadata(), tbl.MetadataLocation(), fsF, nil), nil
}
