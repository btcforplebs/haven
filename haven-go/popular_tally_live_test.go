//go:build integration

package main

// Live gate for the passive tally. Unit tests prove the bookkeeping; this
// proves the thing actually collects: real seed relays, the real
// ingestPopularEngagement loop, the real snapshot file.
//
//	go test ./ -tags integration -run TestLiveEngagementIngest -v -timeout 5m

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func TestLiveEngagementIngest(t *testing.T) {
	const window = 90 * time.Second

	ctx, cancel := context.WithTimeout(context.Background(), window)
	defer cancel()

	pool = nostr.NewSimplePool(ctx, nostr.WithPenaltyBox())
	config.PopularTallyEnabled = true
	config.ImportSeedRelays = []string{
		"wss://relay.primal.net",
		"wss://nos.lol",
		"wss://nostr.mom",
		"wss://nostr-pub.wellorder.net",
	}
	config.PopularTallyCachePath = filepath.Join(t.TempDir(), "popular_tally.json")
	popularTally = newEngagementTally()

	start := time.Now()
	ingestPopularEngagement(ctx) // returns when the context expires
	t.Logf("ran for %s", time.Since(start).Round(time.Second))

	now := time.Now()
	targets, buckets := popularTally.stats(now)
	coverage := popularTally.coverage(now)
	snapshot := popularTally.snapshot(now)

	var engagements int
	for _, reactors := range snapshot {
		engagements += len(reactors)
	}
	t.Logf("targets=%d buckets=%d engagements=%d coverage=%.4f (%.0fs of 24h)",
		targets, buckets, engagements, coverage, coverage*popularWindow.Seconds())

	if targets == 0 {
		t.Fatal("no engagement collected from live relays in 90s — the ingest loop is not collecting")
	}
	if coverage <= 0 {
		t.Fatal("coverage stayed at zero while the subscription was up")
	}
	// The point of the whole exercise: after a short cold start the tally can
	// already answer Popular by itself, because the subscription's own history
	// replay fills the window. If this drops below the floor, the read path
	// falls back to the network and the redesign is buying nothing.
	if coverage < popularTallyMinCoverage {
		t.Errorf("after %s the tally covers only %.2f of the window, under the %.2f floor — Popular would still hit the network",
			window, coverage, popularTallyMinCoverage)
	}

	// And it must produce actual eligible notes, not just raw counters.
	eligible := rankTargets(snapshot, minDistinctReactors)
	t.Logf("eligible notes at %d distinct reactors: %d", minDistinctReactors, len(eligible))
	if len(eligible) == 0 {
		t.Error("no note cleared the distinct-reactor floor — Popular would render empty")
	}

	if _, err := os.Stat(config.PopularTallyCachePath); err != nil {
		t.Fatalf("no snapshot written on shutdown: %v", err)
	}
	restored := newEngagementTally()
	restored.load(config.PopularTallyCachePath, now)
	rt, _ := restored.stats(now)
	t.Logf("snapshot restored %d targets (singletons are deliberately not written)", rt)
}
