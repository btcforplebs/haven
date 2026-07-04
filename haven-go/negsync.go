package main

import (
	"context"
	"log"
	"log/slog"
	"sync"
	"time"

	"github.com/barrydeen/haven/internal/tombstones"
	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip11"
	"github.com/nbd-wtf/go-nostr/nip70"
)

// ─── Per-relay NIP-77 capability cache ──────────────────────────────────────
//
// NIP-11 documents are only trusted positively (they're often stale or
// missing); ground truth is attempt-based: a sync that times out on the
// NEG-OPEN handshake marks the relay unsupported for negCapRetryTTL, a
// successful sync marks it supported for the process lifetime. Transient
// errors (connect failures, mid-session timeouts) are never cached.

type negCap struct {
	supported bool
	checkedAt time.Time
}

var negCaps sync.Map // normalized relay URL → negCap

const negCapRetryTTL = 24 * time.Hour

// relaySupportsNegentropy reports whether a NIP-77 sync attempt against url
// is worthwhile. Unknown relays return true — the attempt itself is the
// probe. A NIP-11 document advertising NIP 77 short-circuits to a cached yes.
func relaySupportsNegentropy(ctx context.Context, url string) bool {
	key := nostr.NormalizeURL(url)
	if v, ok := negCaps.Load(key); ok {
		c := v.(negCap)
		if c.supported {
			return true
		}
		if time.Since(c.checkedAt) < negCapRetryTTL {
			return false
		}
		negCaps.Delete(key) // TTL expired — re-probe
	}

	// Positive fast-path hint only.
	ictx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if info, err := nip11.Fetch(ictx, url); err == nil {
		for _, n := range info.SupportedNIPs {
			// JSON numbers decode as float64; tolerate ints from odd relays.
			if f, ok := n.(float64); ok && int(f) == 77 {
				markNegentropySupported(url)
				return true
			}
			if i, ok := n.(int); ok && i == 77 {
				markNegentropySupported(url)
				return true
			}
		}
	}
	return true // unknown: attempt the sync, its outcome decides
}

func markNegentropySupported(url string) {
	negCaps.Store(nostr.NormalizeURL(url), negCap{supported: true, checkedAt: time.Now()})
}

func markNegentropyUnsupported(url string) {
	negCaps.Store(nostr.NormalizeURL(url), negCap{supported: false, checkedAt: time.Now()})
}

// ─── Catch-up notification batching ─────────────────────────────────────────

// batchNotifier throttles 🔔NOTIFY markers during catch-up sync so a backlog
// import (first sync after being offline) doesn't fire hundreds of system
// notifications. Events older than NOTIFY_MAX_AGE_HOURS never notify; the
// first NOTIFY_BATCH_LIMIT qualifying events notify normally; the remainder
// collapse into one type=summary marker emitted by flush(). The live
// subscription path bypasses this entirely — real-time events always notify.
type batchNotifier struct {
	mu         sync.Mutex
	emitted    int
	suppressed int
}

func (n *batchNotifier) maybeNotify(ev *nostr.Event) {
	if ev == nil {
		return
	}
	if maxAge := time.Duration(config.NotifyMaxAgeHours) * time.Hour; maxAge > 0 &&
		time.Since(ev.CreatedAt.Time()) > maxAge {
		return // old backlog, not news
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.emitted < config.NotifyBatchLimit {
		n.emitted++
		emitInboxNotify(ev)
		return
	}
	n.suppressed++
}

// flush emits a single summary marker for anything suppressed this batch and
// resets the counters for the next catch-up round. Clients that don't know
// type=summary ignore the line.
func (n *batchNotifier) flush() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.suppressed > 0 {
		log.Printf("🔔NOTIFY|type=summary|kind=0|author=|id=|preview=%d more new items while you were away", n.suppressed)
	}
	n.emitted = 0
	n.suppressed = 0
}

// ─── Tombstone-aware RelayStore adapters ────────────────────────────────────
//
// negsync.Sync sees the local side through nostr.RelayStore. These adapters
// (a) widen QuerySync with eventstore.SetNegentropy so the backends don't
// truncate the ID vector at MaxLimit, (b) fold the tombstone set into the
// local vector as haves so intentionally-rejected events are never
// re-downloaded, and (c) route Publish through the same accept/reject rules
// as the live subscription, recording rejects as new tombstones.

// inboxNegStore adapts the inbox+chat DBs for Down-direction tagged-event sync.
type inboxNegStore struct {
	inbox    eventstore.RelayWrapper
	chat     eventstore.RelayWrapper
	tombs    *tombstones.Set
	notifier *batchNotifier
	advance  func(nostr.Timestamp)
}

func (s *inboxNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	ctx = eventstore.SetNegentropy(ctx)
	evs, err := s.inbox.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	chatEvs, err := s.chat.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	evs = append(evs, chatEvs...)
	evs = appendTombstoneStubs(evs, s.tombs, f)
	return evs, nil
}

func (s *inboxNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	// Only exercised by the up direction (unused for Down sync). Tombstone
	// IDs resolve to nothing here, so vector stubs can never be published.
	return fanInQueryEvents(ctx, f, s.inbox, s.chat)
}

func (s *inboxNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	c := classifyInboxEvent(ctx, &ev)
	if !c.accept {
		// Only rejections based on immutable event content are tombstoned.
		// WoT/blacklist rejections stay re-fetchable: a half-built WoT on a
		// fresh instance must not permanently hide replies and mentions.
		if c.reason.permanent() {
			return s.tombs.Add(ev.ID, ev.CreatedAt)
		}
		return nil
	}
	dst := s.inbox
	if c.chat {
		dst = s.chat
	}
	if isDuplicate(ctx, dst, &ev) {
		return nil
	}
	if err := dst.Publish(ctx, ev); err != nil {
		log.Println("🚫 error importing synced note", ev.ID, ":", err)
		return err
	}
	logInboxImport(&ev)
	if s.advance != nil {
		s.advance(ev.CreatedAt)
	}
	if c.notify && s.notifier != nil {
		s.notifier.maybeNotify(&ev)
	}
	return nil
}

// outboxNegStore adapts the outbox DB for Both-direction owner-event sync.
type outboxNegStore struct {
	outbox  eventstore.RelayWrapper
	tombs   *tombstones.Set
	advance func(nostr.Timestamp)
}

func (s *outboxNegStore) QuerySync(ctx context.Context, f nostr.Filter) ([]*nostr.Event, error) {
	ctx = eventstore.SetNegentropy(ctx)
	evs, err := s.outbox.QuerySync(ctx, f)
	if err != nil {
		return nil, err
	}
	evs = appendTombstoneStubs(evs, s.tombs, f)
	return evs, nil
}

// QueryEvents is the up-direction source: only broadcastable events may leave
// the device. Gift wraps, ephemeral kinds, and NIP-70 protected events are
// dropped — they may be listed as haves in the vector, but they are never
// yielded for upload.
func (s *outboxNegStore) QueryEvents(ctx context.Context, f nostr.Filter) (chan *nostr.Event, error) {
	ch, err := s.outbox.QueryEvents(ctx, f)
	if err != nil {
		return nil, err
	}
	out := make(chan *nostr.Event)
	go func() {
		defer close(out)
		for ev := range ch {
			if ev.Kind == nostr.KindGiftWrap || nostr.IsEphemeralKind(ev.Kind) || nip70.IsProtected(*ev) {
				continue
			}
			select {
			case out <- ev:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, nil
}

func (s *outboxNegStore) Publish(ctx context.Context, ev nostr.Event) error {
	// No tombstones here: the sync filter is authors=owner, so rejects are
	// either relay misbehavior or whitelist/blacklist state that can change —
	// both must stay re-fetchable rather than be permanently suppressed.
	if _, ok := config.WhitelistedPubKeys[ev.PubKey]; !ok {
		return nil // relay returned a non-owner event
	}
	if _, ok := config.BlacklistedPubKeys[ev.PubKey]; ok {
		return nil
	}
	if isDuplicate(ctx, s.outbox, &ev) {
		return nil
	}
	if err := s.outbox.Publish(ctx, ev); err != nil {
		log.Println("🚫 error importing synced owner event", ev.ID, ":", err)
		return err
	}
	slog.Debug("📤 imported owner event (negentropy)", "kind", ev.Kind, "id", ev.ID)
	if s.advance != nil {
		s.advance(ev.CreatedAt)
	}
	return nil
}

// appendTombstoneStubs adds a minimal {ID, CreatedAt} stub per tombstone
// within the filter's time bounds — the only fields the negentropy vector
// reads. Stubs never leave the vector: QueryEvents can't find them.
func appendTombstoneStubs(evs []*nostr.Event, tombs *tombstones.Set, f nostr.Filter) []*nostr.Event {
	if tombs == nil {
		return evs
	}
	var since, until nostr.Timestamp
	if f.Since != nil {
		since = *f.Since
	}
	if f.Until != nil {
		until = *f.Until
	}
	tombs.Range(since, until, func(id string, ts nostr.Timestamp) bool {
		evs = append(evs, &nostr.Event{ID: id, CreatedAt: ts})
		return true
	})
	return evs
}

// fanInQueryEvents merges QueryEvents streams from multiple stores.
func fanInQueryEvents(ctx context.Context, f nostr.Filter, stores ...eventstore.RelayWrapper) (chan *nostr.Event, error) {
	out := make(chan *nostr.Event)
	var wg sync.WaitGroup
	for _, st := range stores {
		ch, err := st.QueryEvents(ctx, f)
		if err != nil {
			continue
		}
		wg.Add(1)
		go func(ch chan *nostr.Event) {
			defer wg.Done()
			for ev := range ch {
				select {
				case out <- ev:
				case <-ctx.Done():
					return
				}
			}
		}(ch)
	}
	go func() {
		wg.Wait()
		close(out)
	}()
	return out, nil
}
