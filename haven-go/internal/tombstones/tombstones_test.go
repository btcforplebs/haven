package tombstones

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

func id(c byte) string { return strings.Repeat(string(c), 64) }

func TestAddHasRange(t *testing.T) {
	fs := afero.NewMemMapFs()
	s, err := Open(fs, "db/tombstones.jsonl", 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	now := nostr.Now()
	if err := s.Add(id('a'), now-100); err != nil {
		t.Fatal(err)
	}
	if err := s.Add(id('b'), now-200); err != nil {
		t.Fatal(err)
	}
	// duplicate add is a no-op
	if err := s.Add(id('a'), now-100); err != nil {
		t.Fatal(err)
	}

	if !s.Has(id('a')) || !s.Has(id('b')) {
		t.Fatal("expected both ids present")
	}
	if s.Has(id('c')) {
		t.Fatal("unexpected id present")
	}
	if s.Len() != 2 {
		t.Fatalf("Len = %d, want 2", s.Len())
	}

	// Range bounded to only the newer entry
	var got []string
	s.Range(now-150, 0, func(i string, _ nostr.Timestamp) bool {
		got = append(got, i)
		return true
	})
	if len(got) != 1 || got[0] != id('a') {
		t.Fatalf("Range since bound returned %v", got)
	}

	// Range with early exit
	count := 0
	s.Range(0, 0, func(string, nostr.Timestamp) bool {
		count++
		return false
	})
	if count != 1 {
		t.Fatalf("early exit visited %d entries", count)
	}
}

func TestReloadAndCompaction(t *testing.T) {
	fs := afero.NewMemMapFs()
	now := nostr.Now()

	s, err := Open(fs, "db/t.jsonl", 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	s.Add(id('a'), now)                                              // fresh — survives
	s.Add(id('b'), now-nostr.Timestamp(40*24*time.Hour/time.Second)) // stale — pruned on reload
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(fs, "db/t.jsonl", 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if !s2.Has(id('a')) {
		t.Fatal("fresh entry lost on reload")
	}
	if s2.Has(id('b')) {
		t.Fatal("stale entry not pruned on reload")
	}

	// compacted file should contain exactly one line
	data, err := afero.ReadFile(fs, "db/t.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(data), "\n"); n != 1 {
		t.Fatalf("compacted file has %d lines, want 1: %q", n, data)
	}
}

func TestTornLineTolerated(t *testing.T) {
	fs := afero.NewMemMapFs()
	now := nostr.Now()
	s, _ := Open(fs, "t.jsonl", 30*24*time.Hour)
	s.Add(id('a'), now)
	s.Close()

	// simulate a crash mid-append: garbage partial line at EOF
	f, err := fs.OpenFile("t.jsonl", os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.Write([]byte(`{"id":"deadbeef`))
	f.Close()

	s2, err := Open(fs, "t.jsonl", 30*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if !s2.Has(id('a')) || s2.Len() != 1 {
		t.Fatalf("torn line handling failed: len=%d", s2.Len())
	}
}
