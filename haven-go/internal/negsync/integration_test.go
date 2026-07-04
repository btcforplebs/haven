//go:build integration

// Live-network checks for the NIP-77 handshake paths. Not part of the normal
// suite; run with:
//
//	go test -tags integration -v -run TestLive ./internal/negsync/
package negsync

import (
	"context"
	"errors"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// countingStore is an empty local store that counts what a Down sync fetches.
type countingStore struct{ published atomic.Int64 }

func (s *countingStore) QuerySync(context.Context, nostr.Filter) ([]*nostr.Event, error) {
	return nil, nil
}

func (s *countingStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)
	close(ch)
	return ch, nil
}

func (s *countingStore) Publish(ctx context.Context, ev nostr.Event) error {
	s.published.Add(1)
	return nil
}

// A #p filter on a nonexistent pubkey keeps the remote set (near) empty so the
// reconciliation completes in one round-trip.
func emptyishFilter() nostr.Filter {
	since := nostr.Timestamp(time.Now().Add(-1 * time.Hour).Unix())
	return nostr.Filter{
		Kinds: []int{nostr.KindTextNote},
		Tags:  nostr.TagMap{"p": []string{"1111111111111111111111111111111111111111111111111111111111111111"}},
		Since: &since,
	}
}

func TestLiveSupportedRelay(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	store := &countingStore{}
	stats, err := Sync(ctx, store, "wss://relay.damus.io", emptyishFilter(), Down)
	if err != nil {
		t.Fatalf("expected clean sync against strfry relay, got: %v", err)
	}
	t.Logf("damus: downloaded=%d localHave=%d", stats.Downloaded, stats.LocalHave)
}

// TestLiveLocalRelay reconciles against a locally running Haven instance
// (e.g. its /feed route) to prove the khatru NIP-77 serving path end to end.
// Set HAVEN_LOCAL_URL, e.g. ws://127.0.0.1:3391/feed.
func TestLiveLocalRelay(t *testing.T) {
	url := os.Getenv("HAVEN_LOCAL_URL")
	if url == "" {
		t.Skip("HAVEN_LOCAL_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	store := &countingStore{}
	stats, err := Sync(ctx, store, url, emptyishFilter(), Down)
	if err != nil {
		t.Fatalf("expected clean sync against local Haven relay, got: %v", err)
	}
	t.Logf("local: downloaded=%d localHave=%d", stats.Downloaded, stats.LocalHave)
}

func TestLiveUnsupportedRelay(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	store := &countingStore{}
	_, err := Sync(ctx, store, "wss://relay.primal.net", emptyishFilter(), Down)
	if !errors.Is(err, ErrUnsupported) {
		t.Fatalf("expected ErrUnsupported from primal cache relay, got: %v", err)
	}
}
