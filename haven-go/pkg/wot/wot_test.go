package wot

import (
	"context"
	"sync"
	"testing"
	"time"
)

// stubModel is the single concrete type stored in wotInstance during
// tests — atomic.Value requires a consistent concrete type, mirroring
// production where it is always *SimpleInMemory.
type stubModel struct {
	delay time.Duration
}

func (*stubModel) Has(_ context.Context, _ string) bool { return true }

func (m *stubModel) Init(ctx context.Context) {
	if m.delay > 0 {
		select {
		case <-time.After(m.delay):
		case <-ctx.Done():
		}
	}
}

// TestReadyGateRestartCycles simulates relay stop/start cycles where a
// stale Initialize goroutine from a cancelled cycle finishes after the
// next cycle has already marked ready. With the old global readyCh this
// double-closed the channel and panicked.
func TestReadyGateRestartCycles(t *testing.T) {
	for i := 0; i < 200; i++ {
		oldCtx, oldCancel := context.WithCancel(context.Background())
		oldGate := NewCycle()

		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			Initialize(oldCtx, &stubModel{delay: time.Millisecond}, oldGate)
		}()

		// Restart mid-initialize: cancel the old cycle and start a new one.
		oldCancel()
		gate := NewCycle()
		MarkReady(gate, &stubModel{})

		// A second Initialize on the same (new) gate must also be safe —
		// this is the cache-miss-after-restart path.
		wg.Add(1)
		go func() {
			defer wg.Done()
			Initialize(context.Background(), &stubModel{}, gate)
		}()

		waitCtx, waitCancel := context.WithTimeout(context.Background(), time.Second)
		WaitReady(waitCtx)
		if waitCtx.Err() != nil {
			t.Fatal("WaitReady timed out: current gate never became ready")
		}
		waitCancel()
		wg.Wait()
	}
}

// TestReadyGateConcurrent hammers NewCycle/MarkReady/Initialize/WaitReady
// from many goroutines; run with -race.
func TestReadyGateConcurrent(t *testing.T) {
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()

	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				g := NewCycle()
				go Initialize(cancelled, &stubModel{}, g) // cancelled: must not mark ready
				MarkReady(g, &stubModel{})
				MarkReady(g, &stubModel{}) // idempotent
				ctx, c := context.WithTimeout(context.Background(), 100*time.Millisecond)
				WaitReady(ctx)
				c()
			}
		}()
	}
	wg.Wait()
}

// TestInitializeCancelledDoesNotMarkReady checks that a cancelled cycle
// never signals readiness for a half-built graph.
func TestInitializeCancelledDoesNotMarkReady(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	g := NewCycle()
	Initialize(ctx, &stubModel{}, g)
	select {
	case <-g.Done():
		t.Fatal("cancelled Initialize must not mark the gate ready")
	default:
	}
}

func TestApplyFallbackSeedsOnlyWhenOwnerFollowsNobody(t *testing.T) {
	seeds := []string{"seed1", "seed2", "seed3"}

	t.Run("owner follows nobody: seeds become the one-hop network", func(t *testing.T) {
		wt := &SimpleInMemory{FallbackSeedPubKeys: seeds}
		oneHop := map[string]bool{}
		newWot := map[string]bool{"owner": true}

		if !wt.applyFallbackSeeds(oneHop, newWot) {
			t.Fatal("seeds were not applied to an empty one-hop network")
		}
		for _, s := range seeds {
			if !oneHop[s] {
				t.Errorf("%s missing from the one-hop network", s)
			}
			if !newWot[s] {
				t.Errorf("%s missing from the trust graph", s)
			}
		}
		if !newWot["owner"] {
			t.Error("seeding dropped the owner from their own graph")
		}
	})

	// An established account must never be diluted by strangers: one real
	// follow is enough to keep the starter pack out entirely.
	t.Run("owner follows one person: seeds are not applied", func(t *testing.T) {
		wt := &SimpleInMemory{FallbackSeedPubKeys: seeds}
		oneHop := map[string]bool{"a-real-follow": true}
		newWot := map[string]bool{"owner": true, "a-real-follow": true}

		if wt.applyFallbackSeeds(oneHop, newWot) {
			t.Fatal("seeds were applied despite the owner having a follow")
		}
		if len(oneHop) != 1 || len(newWot) != 2 {
			t.Errorf("seeding mutated an established graph: oneHop=%v newWot=%v", oneHop, newWot)
		}
	})

	t.Run("no seeds configured: nothing happens", func(t *testing.T) {
		wt := &SimpleInMemory{}
		oneHop := map[string]bool{}
		newWot := map[string]bool{}

		if wt.applyFallbackSeeds(oneHop, newWot) {
			t.Fatal("reported applying seeds when none are configured")
		}
		if len(oneHop) != 0 || len(newWot) != 0 {
			t.Errorf("mutated maps with no seeds: oneHop=%v newWot=%v", oneHop, newWot)
		}
	})
}
