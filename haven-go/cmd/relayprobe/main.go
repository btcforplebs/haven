// relayprobe queries a (possibly self-signed TLS) Haven relay and prints
// diagnostic counts: the owner's latest kind-3 follow count and event counts
// per kind/window. Used to inspect a device's embedded relay over an iproxy
// USB tunnel, e.g.:
//
//	iproxy 3355 3355 &
//	go run ./cmd/relayprobe wss://127.0.0.1:3355 [ownerHex]
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func dial(ctx context.Context, url string) (*nostr.Relay, error) {
	r := nostr.NewRelay(ctx, url)
	if err := r.ConnectWithTLS(ctx, &tls.Config{InsecureSkipVerify: true}); err != nil {
		return nil, err
	}
	return r, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: relayprobe <wss://host:port> [ownerHex]")
		os.Exit(1)
	}
	base := os.Args[1]
	owner := ""
	if len(os.Args) > 2 {
		owner = os.Args[2]
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	dump := len(os.Args) > 3 && os.Args[3] == "dump"

	// Root (outbox): latest kind-3
	if root, err := dial(ctx, base); err == nil {
		f := nostr.Filter{Kinds: []int{3}, Limit: 1}
		if owner != "" {
			f.Authors = []string{owner}
		}
		evs, _ := root.QuerySync(ctx, f)
		if dump && len(evs) > 0 {
			for tag := range evs[0].Tags.FindAll("p") {
				if len(tag) >= 2 {
					fmt.Println(tag[1])
				}
			}
			return
		}
		if len(evs) > 0 {
			p := 0
			for tag := range evs[0].Tags.FindAll("p") {
				if len(tag) >= 2 {
					p++
				}
			}
			fmt.Printf("outbox kind-3: author=%s created=%s follows=%d\n",
				evs[0].PubKey, evs[0].CreatedAt.Time().Format(time.RFC3339), p)
		} else {
			fmt.Println("outbox kind-3: NONE FOUND")
		}
		since := nostr.Timestamp(time.Now().Add(-7 * 24 * time.Hour).Unix())
		notes, _ := root.QuerySync(ctx, nostr.Filter{Kinds: []int{1}, Since: &since, Limit: 500})
		fmt.Printf("outbox kind-1 (7d): %d\n", len(notes))
		root.Close()
	} else {
		fmt.Println("outbox dial failed:", err)
	}

	// /feed: cache contents
	if feed, err := dial(ctx, base+"/feed"); err == nil {
		since := nostr.Timestamp(time.Now().Add(-7 * 24 * time.Hour).Unix())
		evs, _ := feed.QuerySync(ctx, nostr.Filter{Kinds: []int{1, 6, 30023}, Since: &since, Limit: 500})
		newest, oldest := "n/a", "n/a"
		authors := map[string]struct{}{}
		if len(evs) > 0 {
			newest = evs[0].CreatedAt.Time().Format(time.RFC3339)
			oldest = evs[len(evs)-1].CreatedAt.Time().Format(time.RFC3339)
			for _, ev := range evs {
				authors[ev.PubKey] = struct{}{}
			}
		}
		fmt.Printf("feed cache (7d, cap 500): %d events, %d authors, newest=%s oldest=%s\n",
			len(evs), len(authors), newest, oldest)
		feed.Close()
	} else {
		fmt.Println("/feed dial failed:", err)
	}

	// /inbox: recent tagged events
	if inbox, err := dial(ctx, base+"/inbox"); err == nil {
		since := nostr.Timestamp(time.Now().Add(-7 * 24 * time.Hour).Unix())
		f := nostr.Filter{Since: &since, Limit: 500}
		if owner != "" {
			f.Tags = nostr.TagMap{"p": []string{owner}}
		}
		evs, _ := inbox.QuerySync(ctx, f)
		fmt.Printf("inbox (7d, cap 500): %d events\n", len(evs))
		inbox.Close()
	} else {
		fmt.Println("/inbox dial failed:", err)
	}
}
