package main

import (
	"context"
	"fmt"
	"log"
	"math"
	"sort"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// PopularNote holds a note with its computed popularity score.
type PopularNote struct {
	ID        string     `json:"id"`
	PubKey    string     `json:"pubkey"`
	Content   string     `json:"content"`
	CreatedAt int64      `json:"created_at"`
	Tags      [][]string `json:"tags"`
	Kind      int        `json:"kind"`
	Score     float64    `json:"score"`
}

var (
	popularCache     []PopularNote
	popularCacheTime time.Time
	popularCacheMu   sync.Mutex
	popularCacheTTL  = 5 * time.Minute
)

const (
	// A note must have engagement from this many *different* pubkeys (not
	// counting its own author) before it can appear in the Popular feed.
	minDistinctReactors = 5

	// Most notes any one author may contribute to a single Popular result set.
	maxNotesPerAuthor = 3
)

// reactionTargetID returns the note a kind-7/6/9735 event refers to.
//
// NIP-25: "the last e tag MUST be the id of the note being reacted to". An
// earlier version took the *first* e-tag, which on a reaction to a reply is
// the thread root — so credit landed on the top of the thread instead of the
// note that actually earned it. Reposts and zap receipts normally carry a
// single e-tag, for which first and last are the same.
func reactionTargetID(tags nostr.Tags) string {
	target := ""
	for _, tag := range tags {
		if len(tag) >= 2 && tag[0] == "e" {
			target = tag[1]
		}
	}
	return target
}

// addEngagement records one reaction/repost/zap against the note it refers to.
//
// A reactor contributes a single entry per note, at the strongest thing they
// did — that is what makes the feed cost distinct identities to game rather
// than distinct clicks. Kinds outside the scored set are ignored rather than
// stored at weight zero: a phantom entry would still count towards the
// distinct-reactor floor while adding no score.
func addEngagement(tally map[string]map[string]float64, ev *nostr.Event) {
	if ev == nil {
		return
	}
	var weight float64
	switch ev.Kind {
	case 7:
		weight = 1.0 // reaction
	case 6:
		weight = 2.0 // repost
	case 9735:
		weight = 3.0 // zap
	default:
		return
	}

	targetID := reactionTargetID(ev.Tags)
	if targetID == "" {
		return
	}

	reactors := tally[targetID]
	if reactors == nil {
		reactors = make(map[string]float64)
		tally[targetID] = reactors
	}
	if weight > reactors[ev.PubKey] {
		reactors[ev.PubKey] = weight
	}
}

// scoredTarget is a note id with the summed weight of its distinct reactors.
type scoredTarget struct {
	id    string
	score float64
}

// rankTargets drops targets with fewer than minDistinct reactors and returns
// the rest sorted by score, highest first. Ties break on id so the ordering is
// total — Go map iteration is randomised, and without the tie-break two runs
// over the same data could disagree about which note leads.
func rankTargets(tally map[string]map[string]float64, minDistinct int) []scoredTarget {
	ranked := make([]scoredTarget, 0, len(tally))
	for id, reactors := range tally {
		if len(reactors) < minDistinct {
			continue
		}
		var total float64
		for _, w := range reactors {
			total += w
		}
		ranked = append(ranked, scoredTarget{id, total})
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].score != ranked[j].score {
			return ranked[i].score > ranked[j].score
		}
		return ranked[i].id < ranked[j].id
	})
	return ranked
}

// scoreExcludingAuthor sums a note's reactor weights ignoring the note's own
// author, and reports how many distinct reactors are left. Self-engagement is
// not evidence that anyone else cared.
func scoreExcludingAuthor(reactors map[string]float64, author string) (float64, int) {
	var total float64
	distinct := 0
	for pk, w := range reactors {
		if pk == author {
			continue
		}
		total += w
		distinct++
	}
	return total, distinct
}

// capPerAuthor keeps at most `limit` notes per pubkey, preserving input order
// (callers sort by score first, so each author keeps their highest-scoring
// notes).
func capPerAuthor(notes []PopularNote, limit int) []PopularNote {
	if limit <= 0 {
		return notes
	}
	counts := make(map[string]int, len(notes))
	kept := make([]PopularNote, 0, len(notes))
	for _, n := range notes {
		if counts[n.PubKey] >= limit {
			continue
		}
		counts[n.PubKey]++
		kept = append(kept, n)
	}
	return kept
}

// computePopularNotes queries seed relays for engagement data, scores notes
// by popularity, fetches the top note contents, and returns them ranked.
func computePopularNotes(ctx context.Context) ([]PopularNote, error) {
	// Check cache first
	popularCacheMu.Lock()
	if time.Since(popularCacheTime) < popularCacheTTL && len(popularCache) > 0 {
		cached := make([]PopularNote, len(popularCache))
		copy(cached, popularCache)
		popularCacheMu.Unlock()
		return cached, nil
	}
	popularCacheMu.Unlock()

	if pool == nil {
		return nil, fmt.Errorf("relay pool not initialized")
	}

	relays := config.ImportSeedRelays
	if len(relays) == 0 {
		return nil, fmt.Errorf("no seed relays configured")
	}

	// Phase 1: Fetch engagement events from last 24h
	since := nostr.Timestamp(time.Now().Add(-24 * time.Hour).Unix())

	engagementFilter := nostr.Filter{
		Kinds: []int{7, 6, 9735},
		Since: &since,
		Limit: 5000,
	}

	// targetNoteID -> reactorPubkey -> that reactor's best single weight.
	// Scoring per *reactor* rather than per engagement event is the anti-spam
	// core: an earlier version summed every event, so one account liking the
	// same note five hundred times added five hundred points. A reactor now
	// contributes once, at the strongest thing they did (zap beats repost
	// beats like), so gaming the feed costs distinct identities, not clicks.
	tally := make(map[string]map[string]float64)
	seenIDs := make(map[string]struct{}) // dedup engagement events

	fetchCtx, fetchCancel := context.WithTimeout(ctx, 15*time.Second)
	defer fetchCancel()

	events := pool.FetchMany(fetchCtx, relays, engagementFilter)
	for ev := range events {
		if _, seen := seenIDs[ev.ID]; seen {
			continue
		}
		seenIDs[ev.ID] = struct{}{}

		addEngagement(tally, ev.Event)
	}

	if len(tally) == 0 {
		return []PopularNote{}, nil
	}

	// Rank by score, take top 100. A note needs engagement from at least
	// minDistinctReactors different people to be eligible at all — one
	// account boosting its own note can no longer reach the feed however
	// hard it tries.
	ranked := rankTargets(tally, minDistinctReactors)
	log.Printf("popular: %d candidate notes, %d eligible at %d distinct reactors",
		len(tally), len(ranked), minDistinctReactors)
	if len(ranked) == 0 {
		return []PopularNote{}, nil
	}
	if len(ranked) > 100 {
		ranked = ranked[:100]
	}

	topIDs := make([]string, len(ranked))
	for i, r := range ranked {
		topIDs[i] = r.id
	}

	// Phase 2: Fetch actual note content for top IDs
	noteFilter := nostr.Filter{
		Kinds: []int{1, 30023},
		IDs:   topIDs,
	}

	noteCtx, noteCancel := context.WithTimeout(ctx, 15*time.Second)
	defer noteCancel()

	var results []PopularNote
	seenNotes := make(map[string]struct{})

	noteEvents := pool.FetchMany(noteCtx, relays, noteFilter)
	for ev := range noteEvents {
		if _, seen := seenNotes[ev.ID]; seen {
			continue
		}
		seenNotes[ev.ID] = struct{}{}

		// The author's own engagement with their own note does not count, and
		// dropping it can put the note back under the floor — an author plus
		// four friends is not the same signal as five independent people.
		rawScore, distinct := scoreExcludingAuthor(tally[ev.ID], ev.PubKey)
		if distinct < minDistinctReactors {
			continue
		}

		// Time decay: notes older than 12h start losing score
		ageHours := time.Since(ev.CreatedAt.Time()).Hours()
		decay := math.Max(0.2, 1.0-math.Max(0, ageHours-12)*0.05)

		tags := make([][]string, len(ev.Tags))
		for i, tag := range ev.Tags {
			tags[i] = []string(tag)
		}

		results = append(results, PopularNote{
			ID:        ev.ID,
			PubKey:    ev.PubKey,
			Content:   ev.Content,
			CreatedAt: int64(ev.CreatedAt),
			Tags:      tags,
			Kind:      ev.Kind,
			Score:     rawScore * decay,
		})
	}

	// Sort by final score descending
	sort.Slice(results, func(i, j int) bool {
		return results[i].Score > results[j].Score
	})

	// No single author may own the feed. Even a legitimately viral account
	// posting ten times in a day should not push everyone else off the
	// screen, and it denies a spammer who does clear the floor the ability
	// to fill it. Applied after sorting so each author keeps their best.
	results = capPerAuthor(results, maxNotesPerAuthor)

	// Update cache
	popularCacheMu.Lock()
	popularCache = make([]PopularNote, len(results))
	copy(popularCache, results)
	popularCacheTime = time.Now()
	popularCacheMu.Unlock()

	return results, nil
}
