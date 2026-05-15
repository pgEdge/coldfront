package sqlutil

import "testing"

func TestLiteral(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "''"},
		{"hello", "'hello'"},
		{"o'clock", "'o''clock'"},
		{"a'b'c", "'a''b''c'"},
		{"''", "''''''"},
	}
	for _, c := range cases {
		if got := Literal(c.in); got != c.want {
			t.Errorf("Literal(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
