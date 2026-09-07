package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeSeedPubkeyAcceptsHexAndNpub(t *testing.T) {
	const hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
	const npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

	cases := []struct{ in, want string }{
		{hex, hex},
		{"  " + hex + "  ", hex},
		{"3BF0C63FCB93463407AF97A5E5EE64FA883D107EF9E558472C4EB9AAAEFA459D", hex},
		{npub, hex},
		{"", ""},
		{"not-a-key", ""},
		{hex[:63], ""},        // too short
		{hex[:63] + "z", ""},  // not hex
		{"npub1nonsense", ""}, // undecodable
	}
	for _, c := range cases {
		if got := normalizeSeedPubkey(c.in); got != c.want {
			t.Errorf("normalizeSeedPubkey(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The built-in list is what a new user actually gets, so a typo in it would
// silently shrink the starter pack rather than fail.
func TestDefaultStarterPackIsAllValidAndUnique(t *testing.T) {
	seen := map[string]struct{}{}
	for i, s := range defaultStarterPack {
		pk := normalizeSeedPubkey(s)
		if pk == "" {
			t.Errorf("defaultStarterPack[%d] = %q is not a usable pubkey", i, s)
			continue
		}
		if _, dup := seen[pk]; dup {
			t.Errorf("defaultStarterPack[%d] = %q is a duplicate", i, s)
		}
		seen[pk] = struct{}{}
	}
	if len(defaultStarterPack) < 10 {
		t.Errorf("starter pack has %d entries; too few to bootstrap a graph", len(defaultStarterPack))
	}
}

func withWorkdir(t *testing.T, dir string) {
	t.Helper()
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(old) })
}

func TestLoadStarterPackUsesBuiltInWhenNoFile(t *testing.T) {
	withWorkdir(t, t.TempDir())
	got := loadStarterPack()
	if len(got) != len(defaultStarterPack) {
		t.Fatalf("got %d seeds, want the %d built-in", len(got), len(defaultStarterPack))
	}
}

func TestLoadStarterPackFileOverridesBuiltIn(t *testing.T) {
	dir := t.TempDir()
	const a = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
	const b = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
	write(t, dir, `["`+a+`","`+b+`"]`)
	withWorkdir(t, dir)

	got := loadStarterPack()
	if len(got) != 2 || got[0] != a || got[1] != b {
		t.Fatalf("got %v, want the two file entries in order", got)
	}
}

// A broken or empty file must not leave a new user with no graph at all —
// that is the failure the starter pack exists to prevent.
func TestLoadStarterPackFallsBackOnUnusableFile(t *testing.T) {
	for _, body := range []string{`{"not":"an array"}`, `[]`, `nonsense`} {
		dir := t.TempDir()
		write(t, dir, body)
		withWorkdir(t, dir)
		if got := loadStarterPack(); len(got) != len(defaultStarterPack) {
			t.Errorf("file %q: got %d seeds, want the %d built-in", body, len(got), len(defaultStarterPack))
		}
	}
}

func TestLoadStarterPackSkipsBadEntriesAndDedupes(t *testing.T) {
	dir := t.TempDir()
	const a = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
	write(t, dir, `["`+a+`","garbage","`+a+`","`+a[:10]+`"]`)
	withWorkdir(t, dir)

	got := loadStarterPack()
	if len(got) != 1 || got[0] != a {
		t.Fatalf("got %v, want exactly one deduped valid entry", got)
	}
}

func write(t *testing.T, dir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, starterPackPath), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}
