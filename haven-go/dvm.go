package main

import (
	"context"
	"fmt"
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

	tally := make(map[string]float64)     // targetNoteID -> score
	seenIDs := make(map[string]struct{})   // dedup engagement events

	fetchCtx, fetchCancel := context.WithTimeout(ctx, 15*time.Second)
	defer fetchCancel()

	events := pool.FetchMany(fetchCtx, relays, engagementFilter)
	for ev := range events {
		if _, seen := seenIDs[ev.ID]; seen {
			continue
		}
		seenIDs[ev.ID] = struct{}{}

		// Extract target note ID from e-tag
		var targetID string
		for _, tag := range ev.Tags {
			if len(tag) >= 2 && tag[0] == "e" {
				targetID = tag[1]
				break
			}
		}
		if targetID == "" {
			continue
		}

		var weight float64
		switch ev.Kind {
		case 7:
			weight = 1.0 // reaction
		case 6:
			weight = 2.0 // repost
		case 9735:
			weight = 3.0 // zap
		}

		tally[targetID] += weight
	}

	if len(tally) == 0 {
		return []PopularNote{}, nil
	}

	// Rank by score, take top 100
	type scored struct {
		id    string
		score float64
	}
	ranked := make([]scored, 0, len(tally))
	for id, s := range tally {
		ranked = append(ranked, scored{id, s})
	}
	sort.Slice(ranked, func(i, j int) bool {
		return ranked[i].score > ranked[j].score
	})
	if len(ranked) > 100 {
		ranked = ranked[:100]
	}

	topIDs := make([]string, len(ranked))
	scoreMap := make(map[string]float64, len(ranked))
	for i, r := range ranked {
		topIDs[i] = r.id
		scoreMap[r.id] = r.score
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

		rawScore := scoreMap[ev.ID]

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

	// Update cache
	popularCacheMu.Lock()
	popularCache = make([]PopularNote, len(results))
	copy(popularCache, results)
	popularCacheTime = time.Now()
	popularCacheMu.Unlock()

	return results, nil
}
