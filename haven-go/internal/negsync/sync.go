// Package negsync implements client-side NIP-77 negentropy reconciliation
// against a remote relay, adapted from the vendored nip77.NegentropySync.
//
// Differences from the vendored implementation:
//   - the websocket connection is closed on return (the vendored version only
//     sends NEG-CLOSE and leaks the connection — fatal when called hourly per
//     relay on mobile);
//   - a relay that never answers the NEG-OPEN (it sends only a NOTICE, which
//     go-nostr swallows) is reported as ErrUnsupported so callers can cache
//     the capability and fall back to plain REQ catch-up;
//   - transfer statistics are returned for logging and notification batching;
//   - direction workers exit on context cancellation instead of leaking when
//     the sync aborts early.
package negsync

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip77"
	"github.com/nbd-wtf/go-nostr/nip77/negentropy"
	"github.com/nbd-wtf/go-nostr/nip77/negentropy/storage/vector"
)

// ErrUnsupported means the relay did not respond to the NEG-OPEN within the
// handshake window — it (almost certainly) does not speak NIP-77. Callers may
// cache this per relay. A NEG-ERR response is NOT this error: a relay that
// answers with NEG-ERR does speak the protocol.
var ErrUnsupported = errors.New("relay does not support NIP-77 negentropy")

type Direction int

const (
	Up   Direction = iota // push local-only events to the relay
	Down                  // fetch relay-only events into the local store
	Both
)

// Stats reports what a Sync transferred.
type Stats struct {
	LocalHave  int // events (incl. tombstones) in the local vector
	Downloaded int // events fetched from the relay and published locally
	Uploaded   int // events pushed from the local store to the relay
}

// openTimeout is how long to wait for the relay's first NEG-MSG/NEG-ERR after
// NEG-OPEN. Supporting relays (khatru, strfry) answer in one round-trip;
// non-supporting ones reply only with a NOTICE that go-nostr swallows, so
// silence is the "unsupported" signal.
const openTimeout = 15 * time.Second

const batchSize = 50

type direction struct {
	label  string
	items  chan string
	source nostr.RelayStore
	target nostr.RelayStore
	count  *atomic.Int64
}

// Sync reconciles the events matching filter between store and the relay at
// url. store.QuerySync builds the local ID vector; in the Down direction
// missing events are fetched in ID batches and handed to store.Publish (which
// is expected to do its own accept/reject filtering); in the Up direction
// events the relay lacks are read via store.QueryEvents and published to it.
func Sync(ctx context.Context, store nostr.RelayStore, url string, filter nostr.Filter, dir Direction) (Stats, error) {
	stats := Stats{}
	id := "haven-negsync"

	data, err := store.QuerySync(ctx, filter)
	if err != nil {
		return stats, fmt.Errorf("failed to query our local store: %w", err)
	}

	vec := vector.New()
	neg := negentropy.New(vec, 1024*1024)
	for _, evt := range data {
		vec.Insert(evt.CreatedAt, evt.ID)
	}
	vec.Seal()
	stats.LocalHave = len(data)

	// Everything below runs under sctx so any return path (unsupported,
	// NEG-ERR, ctx timeout) unblocks the direction workers instead of leaking
	// them on open channels.
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()

	result := make(chan error, 8)
	firstRespOnce := sync.Once{}
	firstResp := make(chan struct{})

	var r *nostr.Relay
	r, err = nostr.RelayConnect(ctx, url, nostr.WithCustomHandler(func(data string) {
		envelope := nip77.ParseNegMessage(data)
		if envelope == nil {
			return
		}
		firstRespOnce.Do(func() { close(firstResp) })
		switch env := envelope.(type) {
		case *nip77.OpenEnvelope, *nip77.CloseEnvelope:
			result <- fmt.Errorf("unexpected %s received from relay", env.Label())
			return
		case *nip77.ErrorEnvelope:
			result <- fmt.Errorf("relay returned a %s: %s", env.Label(), env.Reason)
			return
		case *nip77.MessageEnvelope:
			nextmsg, err := neg.Reconcile(env.Message)
			if err != nil {
				result <- fmt.Errorf("failed to reconcile: %w", err)
				return
			}
			if nextmsg != "" {
				msgb, _ := nip77.MessageEnvelope{SubscriptionID: id, Message: nextmsg}.MarshalJSON()
				r.Write(msgb)
			}
		}
	}))
	if err != nil {
		return stats, err
	}
	defer r.Close()

	var downloaded, uploaded atomic.Int64

	directions := make([]direction, 0, 2)
	if dir == Up || dir == Both {
		directions = append(directions, direction{"up", neg.Haves, store, r, &uploaded})
	}
	if dir == Down || dir == Both {
		directions = append(directions, direction{"down", neg.HaveNots, r, store, &downloaded})
	}
	// The unused side of the reconciliation still fills its channel; drain it
	// so Reconcile can't block the read loop.
	if dir == Up {
		go func() {
			for range neg.HaveNots {
			}
		}()
	}
	if dir == Down {
		go func() {
			for range neg.Haves {
			}
		}()
	}

	wg := sync.WaitGroup{}
	for _, d := range directions {
		wg.Add(1)
		go func(d direction) {
			defer wg.Done()

			seen := make(map[string]struct{})
			var innerWg sync.WaitGroup

			doSync := func(ids []string) {
				defer innerWg.Done()
				if len(ids) == 0 {
					return
				}
				evtch, err := d.source.QueryEvents(sctx, nostr.Filter{IDs: ids})
				if err != nil {
					result <- fmt.Errorf("error querying source on %s: %w", d.label, err)
					return
				}
				for evt := range evtch {
					if err := d.target.Publish(sctx, *evt); err == nil {
						d.count.Add(1)
					}
				}
			}

			ids := make([]string, 0, batchSize)
			flush := func() {
				batch := ids
				ids = make([]string, 0, batchSize)
				innerWg.Add(1)
				go doSync(batch)
			}

		loop:
			for {
				select {
				case item, ok := <-d.items:
					if !ok {
						break loop
					}
					if _, dup := seen[item]; dup {
						continue
					}
					seen[item] = struct{}{}
					ids = append(ids, item)
					if len(ids) == batchSize {
						flush()
					}
				case <-sctx.Done():
					break loop
				}
			}
			flush()
			innerWg.Wait()
		}(d)
	}

	msg := neg.Start()
	open, _ := nip77.OpenEnvelope{SubscriptionID: id, Filter: filter, Message: msg}.MarshalJSON()
	if err := <-r.Write(open); err != nil {
		return stats, fmt.Errorf("failed to write to relay: %w", err)
	}
	defer func() {
		clse, _ := nip77.CloseEnvelope{SubscriptionID: id}.MarshalJSON()
		r.Write(clse)
	}()

	// Handshake: wait for the relay's first NEG response.
	select {
	case <-ctx.Done():
		return stats, ctx.Err()
	case err := <-result:
		stats.Downloaded = int(downloaded.Load())
		stats.Uploaded = int(uploaded.Load())
		return stats, err
	case <-firstResp:
	case <-time.After(openTimeout):
		return stats, ErrUnsupported
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-ctx.Done():
		err = ctx.Err()
	case err = <-result:
	case <-done:
		err = nil
	}
	stats.Downloaded = int(downloaded.Load())
	stats.Uploaded = int(uploaded.Load())
	return stats, err
}
