// Package tombstones persists the IDs of events that were fetched and
// intentionally rejected (blacklist / Web-of-Trust / whitelist filtering).
//
// Negentropy reconciliation compares ID sets: the local inbox is a filtered
// subset of what remote relays hold for the same filter, so without a record
// of "seen and rejected" IDs every sync would re-download the entire rejected
// backlog forever. Rejected IDs are added to the local ID vector as haves.
//
// Storage is an in-memory map backed by an append-only JSONL file (one
// {"id","ts"} object per line), compacted on load. The timestamp is the
// event's created_at — required because negentropy vectors are keyed by
// (created_at, id) — and is also used to prune entries that have aged out of
// the sync window.
package tombstones

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

type entry struct {
	ID string          `json:"id"`
	Ts nostr.Timestamp `json:"ts"`
}

// Set is a persistent set of rejected event IDs. Safe for concurrent use.
type Set struct {
	mu   sync.RWMutex
	m    map[string]nostr.Timestamp
	fs   afero.Fs
	path string
	w    afero.File // append handle; nil after Close
}

// Open loads the tombstone file at path (creating it if absent), drops
// entries whose created_at is older than retention, and rewrites the
// compacted file. The returned Set keeps an append handle open until Close.
func Open(appfs afero.Fs, path string, retention time.Duration) (*Set, error) {
	s := &Set{
		m:    make(map[string]nostr.Timestamp),
		fs:   appfs,
		path: path,
	}
	cutoff := nostr.Timestamp(time.Now().Add(-retention).Unix())

	if err := s.load(cutoff); err != nil {
		return nil, err
	}
	if err := s.compact(); err != nil {
		return nil, err
	}

	w, err := appfs.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return nil, fmt.Errorf("tombstones: open append handle: %w", err)
	}
	s.w = w
	return s, nil
}

// load reads the JSONL file into memory, skipping malformed lines and entries
// older than cutoff. A missing file is not an error.
func (s *Set) load(cutoff nostr.Timestamp) error {
	f, err := s.fs.Open(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("tombstones: open %s: %w", s.path, err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 1<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var e entry
		if err := json.Unmarshal(line, &e); err != nil || len(e.ID) != 64 {
			continue // tolerate a torn final line from a crash mid-append
		}
		if e.Ts < cutoff {
			continue
		}
		s.m[e.ID] = e.Ts
	}
	return sc.Err()
}

// compact rewrites the file with only the surviving in-memory entries.
// Written to a temp file then renamed so a crash can't lose the whole set.
func (s *Set) compact() error {
	if err := s.fs.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("tombstones: mkdir: %w", err)
	}
	tmp := s.path + ".tmp"
	f, err := s.fs.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("tombstones: create %s: %w", tmp, err)
	}
	bw := bufio.NewWriter(f)
	for id, ts := range s.m {
		b, _ := json.Marshal(entry{ID: id, Ts: ts})
		bw.Write(b)
		bw.WriteByte('\n')
	}
	if err := bw.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return s.fs.Rename(tmp, s.path)
}

// Add records a rejected event ID. No-op if already present. The entry is
// appended to the backing file immediately (no fsync — losing a tombstone to
// a crash only costs one redundant download on the next sync).
// All Set methods are nil-receiver-safe so callers can treat a failed Open as
// "no tombstones" without guarding every call.
func (s *Set) Add(id string, ts nostr.Timestamp) error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.m[id]; ok {
		return nil
	}
	s.m[id] = ts
	if s.w == nil {
		return nil // closed; keep the in-memory entry for this process
	}
	b, _ := json.Marshal(entry{ID: id, Ts: ts})
	if _, err := s.w.Write(append(b, '\n')); err != nil {
		return fmt.Errorf("tombstones: append: %w", err)
	}
	return nil
}

// Has reports whether id is tombstoned.
func (s *Set) Has(id string) bool {
	if s == nil {
		return false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.m[id]
	return ok
}

// Len returns the number of tombstoned IDs.
func (s *Set) Len() int {
	if s == nil {
		return 0
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.m)
}

// Range calls yield for every entry with since <= ts <= until (zero values
// mean unbounded). Iteration stops if yield returns false. The set's lock is
// held for the duration — yield must not call back into the Set.
func (s *Set) Range(since, until nostr.Timestamp, yield func(id string, ts nostr.Timestamp) bool) {
	if s == nil {
		return
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for id, ts := range s.m {
		if since != 0 && ts < since {
			continue
		}
		if until != 0 && ts > until {
			continue
		}
		if !yield(id, ts) {
			return
		}
	}
}

// Close flushes and closes the append handle. Add still updates the
// in-memory set afterwards but no longer persists.
func (s *Set) Close() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.w == nil {
		return nil
	}
	err := s.w.Close()
	s.w = nil
	return err
}
