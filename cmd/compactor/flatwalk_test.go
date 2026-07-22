package main

import "testing"

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
