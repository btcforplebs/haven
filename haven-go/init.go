package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"runtime"
	"text/template"
	"time"

	badgerdb "github.com/dgraph-io/badger/v4"
	"github.com/fiatjaf/eventstore/badger"
	"github.com/fiatjaf/eventstore/lmdb"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/blossom"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
	"github.com/spf13/afero"
)

// Global variables used by both desktop (main.go) and iOS (cshared.go)
var (
	pool   *nostr.SimplePool
	config Config
	fs     afero.Fs
)

// Relay instances — re-created on each initRelays() call so HTTP muxes are fresh.
var (
	privateRelay *khatru.Relay
	privateDB    DBBackend
)

var (
	chatRelay *khatru.Relay
	chatDB    DBBackend
)

var (
	outboxRelay *khatru.Relay
	outboxDB    DBBackend
)

var (
	inboxRelay *khatru.Relay
	inboxDB    DBBackend
)

var (
	blossomDB     DBBackend
	blossomServer *blossom.BlossomServer
	dbs           map[string]DBBackend
)

type DBBackend interface {
	Init() error
	Close()
	CountEvents(ctx context.Context, filter nostr.Filter) (int64, error)
	DeleteEvent(ctx context.Context, evt *nostr.Event) error
	QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error)
	SaveEvent(ctx context.Context, evt *nostr.Event) error
	ReplaceEvent(ctx context.Context, evt *nostr.Event) error
	Serial() []byte
}

func newDBBackend(path string) DBBackend {
	switch config.DBEngine {
	case "lmdb":
		return newLMDBBackend(path)
	case "badger":
		return &badger.BadgerBackend{
			Path: path,
			// Limit vlog file size to 64 MB so iOS can mmap them.
			// BadgerDB's default is ~2 GB which exceeds the virtual
			// address space available to sandboxed iOS processes.
			BadgerOptionsModifier: func(opts badgerdb.Options) badgerdb.Options {
				return opts.WithValueLogFileSize(1 << 26) // 64 MiB
			},
		}
	default:
		return newLMDBBackend(path)
	}
}

func newLMDBBackend(path string) *lmdb.LMDBBackend {
	mapSize := config.LmdbMapSize
	if mapSize == 0 {
		switch runtime.GOOS {
		case "ios":
			// iOS has strict memory mapping limits per process
			mapSize = 256 << 20 // 256 MB
		case "darwin":
			// macOS App Sandbox can reject very large mmap regions;
			// default to 1 GB which is safe and sufficient for most relays.
			mapSize = 1 << 30 // 1 GB
		}
	}
	return &lmdb.LMDBBackend{
		Path:    path,
		MapSize: mapSize,
	}
}

func initDBs() error {
	return GranularInitDBs([]string{"private", "chat", "outbox", "inbox", "blossom"})
}

func GranularInitDBs(names []string) error {
	if dbs == nil {
		dbs = make(map[string]DBBackend)
	}

	for i, name := range names {
		path := "db/" + name
		slog.Info(fmt.Sprintf("Initializing %s database (%d/%d)", name, i+1, len(names)))
		db := newDBBackend(path)
		if err := db.Init(); err != nil {
			return fmt.Errorf("%sDB init failed: %w", name, err)
		}
		dbs[name] = db
		slog.Info(fmt.Sprintf("✓ %s database ready", name))

		// Assign to global variables for backward compatibility
		switch name {
		case "private":
			privateDB = db
		case "chat":
			chatDB = db
		case "outbox":
			outboxDB = db
		case "inbox":
			inboxDB = db
		case "blossom":
			blossomDB = db
		}
	}

	return nil
}

func CloseDBs() {
	if dbs != nil {
		for name, db := range dbs {
			if db != nil {
				slog.Info("Closing database", "name", name)
				db.Close()
				dbs[name] = nil
			}
		}
	}
}

func initRelays(ctx context.Context) error {
	// Re-create relay instances on each call so their internal HTTP muxes are fresh.
	// This prevents "pattern already registered" panics when the relay is restarted
	// in C-shared mode (e.g. after import completes).
	privateRelay = khatru.NewRelay()
	chatRelay = khatru.NewRelay()
	outboxRelay = khatru.NewRelay()
	inboxRelay = khatru.NewRelay()

	if err := initDBs(); err != nil {
		return err
	}

	initRelayLimits()

	privateRelay.Info.Name = config.PrivateRelayName
	privateRelay.Info.PubKey = nPubToPubkey(config.PrivateRelayNpub)
	privateRelay.Info.Description = config.PrivateRelayDescription
	privateRelay.Info.Icon = config.PrivateRelayIcon
	privateRelay.Info.Version = config.RelayVersion
	privateRelay.Info.Software = config.RelaySoftware
	privateRelay.ServiceURL = "https://" + config.RelayURL + "/private"

	if !privateRelayLimits.AllowEmptyFilters {
		privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !privateRelayLimits.AllowComplexFilters {
		privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.NoComplexFilters)
	}
	privateRelay.RejectFilter = append(privateRelay.RejectFilter, policies.MustAuth, MustBeWhitelistedToQuery)

	privateRelay.RejectEvent = append(privateRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		whitelistBypassEventRateLimiter(
			privateRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(privateRelayLimits.EventIPLimiterInterval),
			privateRelayLimits.EventIPLimiterMaxTokens,
		),
		MustBeWhitelistedToPost,
	)

	privateRelay.RejectConnection = append(privateRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			privateRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(privateRelayLimits.ConnectionRateLimiterInterval),
			privateRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	privateRelay.OnConnect = append(privateRelay.OnConnect, khatru.RequestAuth)

	privateRelay.StoreEvent = append(privateRelay.StoreEvent, privateDB.SaveEvent, func(ctx context.Context, event *nostr.Event) error {
		slog.Info("event stored")
		return nil
	})
	privateRelay.QueryEvents = append(privateRelay.QueryEvents, privateDB.QueryEvents)
	privateRelay.DeleteEvent = append(privateRelay.DeleteEvent, privateDB.DeleteEvent)
	privateRelay.CountEvents = append(privateRelay.CountEvents, privateDB.CountEvents)
	privateRelay.ReplaceEvent = append(privateRelay.ReplaceEvent, privateDB.ReplaceEvent)

	mux := privateRelay.Router()

	mux.HandleFunc("GET /private", func(w http.ResponseWriter, r *http.Request) {
		tmpl, err := template.ParseFiles("templates/index.html")
		if err != nil {
			renderFallbackPage(w, config.PrivateRelayName, config.PrivateRelayDescription, "wss://"+config.RelayURL+"/private")
			return
		}
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.PrivateRelayName,
			RelayPubkey:      nPubToPubkey(config.PrivateRelayNpub),
			RelayDescription: config.PrivateRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/private",
		}
		if err := tmpl.Execute(w, data); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	chatRelay.Info.Name = config.ChatRelayName
	chatRelay.Info.PubKey = nPubToPubkey(config.ChatRelayNpub)
	chatRelay.Info.Description = config.ChatRelayDescription
	chatRelay.Info.Icon = config.ChatRelayIcon
	chatRelay.Info.Version = config.RelayVersion
	chatRelay.Info.Software = config.RelaySoftware
	chatRelay.ServiceURL = "https://" + config.RelayURL + "/chat"

	if !chatRelayLimits.AllowEmptyFilters {
		chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !chatRelayLimits.AllowComplexFilters {
		chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.NoComplexFilters)
	}
	chatRelay.RejectFilter = append(chatRelay.RejectFilter, policies.MustAuth, MustBeInWotToQuery)

	chatRelay.RejectEvent = append(chatRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		whitelistBypassEventRateLimiter(
			chatRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(chatRelayLimits.EventIPLimiterInterval),
			chatRelayLimits.EventIPLimiterMaxTokens,
		),
		MustNotBeBlacklistedToPost,
		MustBeInWotToPost,
		EventMustBeChatRelated,
	)

	chatRelay.RejectConnection = append(chatRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			chatRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(chatRelayLimits.ConnectionRateLimiterInterval),
			chatRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	chatRelay.OnConnect = append(chatRelay.OnConnect, khatru.RequestAuth)

	chatRelay.StoreEvent = append(chatRelay.StoreEvent, chatDB.SaveEvent, func(ctx context.Context, event *nostr.Event) error {
		slog.Info("event stored")
		return nil
	})
	chatRelay.QueryEvents = append(chatRelay.QueryEvents, chatDB.QueryEvents)
	chatRelay.DeleteEvent = append(chatRelay.DeleteEvent, chatDB.DeleteEvent)
	chatRelay.CountEvents = append(chatRelay.CountEvents, chatDB.CountEvents)
	chatRelay.ReplaceEvent = append(chatRelay.ReplaceEvent, chatDB.ReplaceEvent)

	mux = chatRelay.Router()

	mux.HandleFunc("GET /chat", func(w http.ResponseWriter, r *http.Request) {
		tmpl, err := template.ParseFiles("templates/index.html")
		if err != nil {
			renderFallbackPage(w, config.ChatRelayName, config.ChatRelayDescription, "wss://"+config.RelayURL+"/chat")
			return
		}
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.ChatRelayName,
			RelayPubkey:      nPubToPubkey(config.ChatRelayNpub),
			RelayDescription: config.ChatRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/chat",
		}
		err = tmpl.Execute(w, data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	outboxRelay.Info.Name = config.OutboxRelayName
	outboxRelay.Info.PubKey = nPubToPubkey(config.OutboxRelayNpub)
	outboxRelay.Info.Description = config.OutboxRelayDescription
	outboxRelay.Info.Icon = config.OutboxRelayIcon
	outboxRelay.Info.Version = config.RelayVersion
	outboxRelay.Info.Software = config.RelaySoftware
	outboxRelay.ServiceURL = "https://" + config.RelayURL

	if !outboxRelayLimits.AllowEmptyFilters {
		outboxRelay.RejectFilter = append(outboxRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !outboxRelayLimits.AllowComplexFilters {
		outboxRelay.RejectFilter = append(outboxRelay.RejectFilter, policies.NoComplexFilters)
	}

	outboxRelay.RejectEvent = append(outboxRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		whitelistBypassEventRateLimiter(
			outboxRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(outboxRelayLimits.EventIPLimiterInterval),
			outboxRelayLimits.EventIPLimiterMaxTokens,
		),
		MustBeWhitelistedToPost,
	)

	outboxRelay.RejectConnection = append(outboxRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			outboxRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(outboxRelayLimits.ConnectionRateLimiterInterval),
			outboxRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	outboxRelay.StoreEvent = append(outboxRelay.StoreEvent, outboxDB.SaveEvent, func(ctx context.Context, event *nostr.Event) error {
		slog.Info("event stored")
		go blast(ctx, event)
		return nil
	})
	outboxRelay.QueryEvents = append(outboxRelay.QueryEvents, outboxDB.QueryEvents)
	outboxRelay.DeleteEvent = append(outboxRelay.DeleteEvent, outboxDB.DeleteEvent)
	outboxRelay.CountEvents = append(outboxRelay.CountEvents, outboxDB.CountEvents)
	outboxRelay.ReplaceEvent = append(outboxRelay.ReplaceEvent, outboxDB.ReplaceEvent)

	mux = outboxRelay.Router()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")

		tmpl, err := template.ParseFiles("templates/feed.html")
		if err != nil {
			renderFallbackPage(w, config.OutboxRelayName, config.OutboxRelayDescription, "wss://"+config.RelayURL)
			return
		}

		notes := fetchRecentNotes(r.Context(), 20)

		data := FeedPageData{
			RelayName:        config.OutboxRelayName,
			RelayPubkey:      nPubToPubkey(config.OutboxRelayNpub),
			RelayDescription: config.OutboxRelayDescription,
			RelayURL:         "wss://" + config.RelayURL,
			Notes:            notes,
		}

		if err := tmpl.Execute(w, data); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	blossomServer = blossom.New(outboxRelay, "https://"+config.RelayURL)
	blossomServer.Store = blossom.EventStoreBlobIndexWrapper{Store: blossomDB, ServiceURL: blossomServer.ServiceURL}
	blossomServer.StoreBlob = append(blossomServer.StoreBlob, func(ctx context.Context, sha256 string, ext string, body []byte) error {
		slog.Debug("storing blob", "sha256", sha256, "ext", ext)
		file, err := fs.Create(config.BlossomPath + sha256)
		if err != nil {
			return err
		}
		if _, err := io.Copy(file, bytes.NewReader(body)); err != nil {
			return err
		}
		return nil
	})
	blossomServer.LoadBlob = append(blossomServer.LoadBlob, loadBlob)
	blossomServer.DeleteBlob = append(blossomServer.DeleteBlob, func(ctx context.Context, sha256 string, ext string) error {
		slog.Debug("deleting blob", "sha256", sha256, "ext", ext)
		return fs.Remove(config.BlossomPath + sha256)
	})
	blossomServer.RejectUpload = append(blossomServer.RejectUpload, func(ctx context.Context, event *nostr.Event, size int, ext string) (bool, string, int) {
		if _, ok := config.WhitelistedPubKeys[event.PubKey]; ok {
			return false, ext, size
		}

		return true, "only media signed by whitelisted pubkeys are allowed", 403
	})
	migrateBlossomMetadata(ctx, blossomServer)

	inboxRelay.Info.Name = config.InboxRelayName
	inboxRelay.Info.PubKey = nPubToPubkey(config.InboxRelayNpub)
	inboxRelay.Info.Description = config.InboxRelayDescription
	inboxRelay.Info.Icon = config.InboxRelayIcon
	inboxRelay.Info.Version = config.RelayVersion
	inboxRelay.Info.Software = config.RelaySoftware
	inboxRelay.ServiceURL = "https://" + config.RelayURL + "/inbox"

	if !inboxRelayLimits.AllowEmptyFilters {
		inboxRelay.RejectFilter = append(inboxRelay.RejectFilter, policies.NoEmptyFilters)
	}
	if !inboxRelayLimits.AllowComplexFilters {
		inboxRelay.RejectFilter = append(inboxRelay.RejectFilter, policies.NoComplexFilters)
	}

	inboxRelay.RejectEvent = append(inboxRelay.RejectEvent,
		policies.RejectEventsWithBase64Media,
		whitelistBypassEventRateLimiter(
			inboxRelayLimits.EventIPLimiterTokensPerInterval,
			time.Minute*time.Duration(inboxRelayLimits.EventIPLimiterInterval),
			inboxRelayLimits.EventIPLimiterMaxTokens,
		),
		OnlyGiftWrappedDMs,
		MustNotBeBlacklistedToPost,
		MustBeInWotToPost,
		MustTagWhitelistedPubKey,
	)

	inboxRelay.RejectConnection = append(inboxRelay.RejectConnection,
		policies.ConnectionRateLimiter(
			inboxRelayLimits.ConnectionRateLimiterTokensPerInterval,
			time.Minute*time.Duration(inboxRelayLimits.ConnectionRateLimiterInterval),
			inboxRelayLimits.ConnectionRateLimiterMaxTokens,
		),
	)

	inboxRelay.StoreEvent = append(inboxRelay.StoreEvent, inboxDB.SaveEvent, func(ctx context.Context, event *nostr.Event) error {
		slog.Info("event stored")
		return nil
	})
	inboxRelay.QueryEvents = append(inboxRelay.QueryEvents, inboxDB.QueryEvents)
	inboxRelay.DeleteEvent = append(inboxRelay.DeleteEvent, inboxDB.DeleteEvent)
	inboxRelay.CountEvents = append(inboxRelay.CountEvents, inboxDB.CountEvents)
	inboxRelay.ReplaceEvent = append(inboxRelay.ReplaceEvent, inboxDB.ReplaceEvent)

	mux = inboxRelay.Router()

	mux.HandleFunc("GET /inbox", func(w http.ResponseWriter, r *http.Request) {
		tmpl, err := template.ParseFiles("templates/index.html")
		if err != nil {
			renderFallbackPage(w, config.InboxRelayName, config.InboxRelayDescription, "wss://"+config.RelayURL+"/inbox")
			return
		}
		data := struct {
			RelayName        string
			RelayPubkey      string
			RelayDescription string
			RelayURL         string
		}{
			RelayName:        config.InboxRelayName,
			RelayPubkey:      nPubToPubkey(config.InboxRelayNpub),
			RelayDescription: config.InboxRelayDescription,
			RelayURL:         "wss://" + config.RelayURL + "/inbox",
		}
		if err := tmpl.Execute(w, data); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})

	return nil
}

// Shared helper functions used by both main.go and cshared.go

func dynamicRelayHandler(w http.ResponseWriter, r *http.Request) {
	var relay *khatru.Relay
	relayType := r.URL.Path

	switch relayType {
	case "/private":
		relay = privateRelay
	case "/chat":
		relay = chatRelay
	case "/inbox":
		relay = inboxRelay
	case "":
		relay = outboxRelay
	default:
		relay = outboxRelay
	}

	relay.ServeHTTP(w, r)
}

func getLogLevelFromConfig() slog.Level {
	switch config.LogLevel {
	case "DEBUG":
		return slog.LevelDebug
	case "INFO":
		return slog.LevelInfo
	case "WARN":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo // Default level
	}
}

// Branded fallback page rendered when template files are missing from disk.
// Self-contained HTML with inline styles — no external CDN dependencies.
const fallbackPageHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{.RelayName}}</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;min-height:100vh;display:flex;flex-direction:column;background:#111114;color:#e5e7eb}
.hero{flex:1;display:flex;align-items:center;justify-content:center;padding:2rem}
.card{text-align:center;max-width:560px;width:100%}
.shield{width:80px;height:80px;margin:0 auto 1.5rem;border-radius:20px;background:linear-gradient(135deg,#7c3aed,#a855f7);display:flex;align-items:center;justify-content:center;box-shadow:0 0 40px rgba(139,92,246,.3)}
.shield svg{width:40px;height:40px;fill:none;stroke:#fff;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.brand{font-size:.75rem;letter-spacing:.15em;text-transform:uppercase;color:#a78bfa;margin-bottom:.75rem;font-weight:600}
h1{font-size:2.25rem;font-weight:700;color:#c4b5fd;line-height:1.2;margin-bottom:.5rem}
.desc{font-size:1.1rem;color:#9ca3af;margin-bottom:1.5rem;line-height:1.6}
.ws-url{display:inline-block;font-family:"SF Mono",SFMono-Regular,Consolas,monospace;font-size:.85rem;color:#a78bfa;background:#1e1b2e;padding:.5rem 1.25rem;border-radius:999px;border:1px solid #312e81;margin-bottom:2rem;word-break:break-all}
.buttons{display:flex;flex-wrap:wrap;gap:.75rem;justify-content:center}
.btn{display:inline-block;font-size:.875rem;font-weight:600;padding:.65rem 1.5rem;border-radius:999px;text-decoration:none;transition:background .2s,transform .15s}
.btn:hover{transform:translateY(-1px)}
.btn-ios{background:#2563eb;color:#fff}
.btn-ios:hover{background:#1d4ed8}
.btn-mac{background:#7c3aed;color:#fff}
.btn-mac:hover{background:#6d28d9}
.features{display:flex;flex-wrap:wrap;gap:1rem;justify-content:center;margin-top:2.5rem}
.feat{background:#1a1a2e;border:1px solid #2d2b55;border-radius:12px;padding:.85rem 1.1rem;font-size:.8rem;color:#a78bfa;display:flex;align-items:center;gap:.5rem}
.feat svg{width:16px;height:16px;fill:none;stroke:#7c3aed;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}
footer{text-align:center;padding:1.25rem;border-top:1px solid #1f1f2e;font-size:.8rem;color:#6b7280}
footer a{color:#7c3aed;text-decoration:none}
footer a:hover{text-decoration:underline}
</style>
</head>
<body>
<div class="hero"><div class="card">
<div class="shield"><svg viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg></div>
<div class="brand">Nostr Vault</div>
<h1>{{.RelayName}}</h1>
<p class="desc">{{.RelayDescription}}</p>
<div class="ws-url">{{.RelayURL}}</div>
<div class="buttons">
<a href="https://testflight.apple.com/join/kN3zE1H1" class="btn btn-ios">iOS TestFlight</a>
<a href="https://github.com/btcforplebs/haven-mac/releases" class="btn btn-mac">Get Haven for Mac</a>
</div>
<div class="features">
<div class="feat"><svg viewBox="0 0 24 24"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>Private Relay</div>
<div class="feat"><svg viewBox="0 0 24 24"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>Chat Relay</div>
<div class="feat"><svg viewBox="0 0 24 24"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/></svg>Inbox Relay</div>
<div class="feat"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>Blossom Drive</div>
</div>
</div></div>
<footer>Powered by <a href="https://github.com/bitvora/haven" target="_blank">Haven Relay</a> &middot; Built with <a href="https://khatru.nostr.technology/" target="_blank">Khatru</a></footer>
</body>
</html>`

var fallbackTemplate = template.Must(template.New("fallback").Parse(fallbackPageHTML))

func renderFallbackPage(w http.ResponseWriter, relayName, relayDescription, relayURL string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	data := struct {
		RelayName        string
		RelayDescription string
		RelayURL         string
	}{
		RelayName:        relayName,
		RelayDescription: relayDescription,
		RelayURL:         relayURL,
	}
	if err := fallbackTemplate.Execute(w, data); err != nil {
		// Last resort: plain text
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "%s — %s\n%s\n", relayName, relayDescription, relayURL)
	}
}
