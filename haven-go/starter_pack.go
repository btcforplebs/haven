package main

import (
	"encoding/json"
	"log"
	"os"
	"strings"
)

// starterPackPath is read relative to the relay data root (the process chdirs
// there at startup, same as wot_cache.json). Drop a JSON array of npubs or hex
// pubkeys there to override the built-in list without rebuilding.
const starterPackPath = "starter_pack.json"

// defaultStarterPack seeds the Web of Trust for an account that follows nobody.
//
// Without it a new user's trust graph contains exactly one pubkey — their own —
// which is not a graph, and every feed that leans on it either shows nothing or
// gives up and shows the open firehose. Two thirds of the engagement traffic on
// the default seed relays over 24h was measured to be a single spam campaign, so
// "show everything" is not a safe default for someone with nobody to trust yet.
//
// PROVISIONAL. Derived 2026-09-07 from accounts that were engaged with on the
// default seed relays over 48h, keeping only those with a real follow list and
// more than 200 followers, with the measured spam campaign excluded. It is a
// bootstrap, not an editorial selection — replace it with people you would
// actually introduce a stranger to.
var defaultStarterPack = []string{
	"8fb140b4e8ddef97ce4b821d247278a1a4353362623f64021484b372f948000c",
	"3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24",
	"6a359852238dc902aed19fbbf6a055f9abf21c1ca8915d1c4e27f50df2f290d9",
	"f8e6c64342f1e052480630e27e1016dce35fc3a614e60434fef4aa2503328ca9",
	"1afe0c74e3d7784eba93a5e3fa554a6eeb01928d12739ae8ba4832786808e36d",
	"4d7842051782e0d3feb034d150adc2b6bae4ee3b49786793bffa468b6f5b96b3",
	"0461fcbecc4c3374439932d6b8f11269ccdb7cc973ad7a50ae362db135a474dd",
	"e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb",
	"3d2e51508699f98f0f2bdbe7a45b673c687fe6420f466dc296d90b908d51d594",
	"2774d83c8f9789c583414292b1192c4345db7ff0d551ea32efa2958f4192f6e5",
	"b7ed68b062de6b4a12e51fd5285c1e1e0ed0e5128cda93ab11b4150b55ed32fc",
	"50d94fc2d8580c682b071a542f8b1e31a200b0508bab95a33bef0855df281d63",
	"460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c",
	"4eb88310d6b4ed95c6d66a395b3d3cf559b85faec8f7691dafd405a92e055d6d",
	"a60e79e0edad5100d7543b669e513dbc1c2170e8e9b74fdb8e971afd1e0e6813",
	"ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74",
	"675b84fe75e216ab947c7438ee519ca7775376ddf05dadfba6278bd012e1d728",
	"fd208ee8c8f283780a9552896e4823cc9dc6bfd442063889577106940fd927c1",
	"cf9b2a1369a4cd9132639b13ae39200d703043179a814e8648e9e5340937eec1",
	"de75eb1d7a6627807a8dff0fb337cfcf189e7e9af8ab6229f688f664710c3014",
	"1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139",
	"ba18b6545357cff8e531accfe1d609a41ef3023fba071db1cbf5a67448c19046",
	"c1e6505c02da8d1b0a5b3d6db6e19b2eb22dcd54f0e86306ec8a213902b3157e",
	"fcf70a45cfa817eaa813b9ba8a375d713d3169f4a27f3dcac3d49112df67d37e",
	"8867bed93e89c93d0d8ac98b2443c5554799edb9190346946b12e03f13664450",
	"e096a89eeb90820895a6dfd7f369ec313654e5762e042d59ad06937659351479",
	"604e96e099936a104883958b040b47672e0f048c98ac793f37ffe4c720279eb2",
	"26d6a946675e603f8de4bf6f9cef442037b70c7eee170ff06ed7673fc34c98f1",
	"6e75f7972397ca3295e0f4ca0fbc6eb9cc79be85bafdd56bd378220ca8eee74e",
	"dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319",
}

// normalizeSeedPubkey accepts either a bech32 npub or a 64-character hex
// pubkey and returns lowercase hex. A human edits this list by pasting keys
// from a client, and clients show npubs — refusing them would turn an easy
// edit into a silent empty starter pack.
func normalizeSeedPubkey(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if strings.HasPrefix(s, "npub1") {
		return nPubToPubkey(s)
	}
	if len(s) != 64 {
		return ""
	}
	s = strings.ToLower(s)
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return ""
		}
	}
	return s
}

// loadStarterPack returns the seed pubkeys used to bootstrap the Web of Trust
// for an account with no follows. A `starter_pack.json` in the relay data root
// replaces the built-in list entirely; a missing file is the normal case and a
// malformed or empty one falls back to the built-in list rather than leaving a
// new user with no graph at all.
func loadStarterPack() []string {
	raw := defaultStarterPack
	if data, err := os.ReadFile(starterPackPath); err == nil {
		var custom []string
		if err := json.Unmarshal(data, &custom); err != nil {
			log.Printf("⚠️ starter pack %s is not a JSON array of pubkeys, using built-in list: %s", starterPackPath, err)
		} else if len(custom) == 0 {
			log.Printf("⚠️ starter pack %s is empty, using built-in list", starterPackPath)
		} else {
			raw = custom
		}
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(raw))
	for _, s := range raw {
		pk := normalizeSeedPubkey(s)
		if pk == "" {
			log.Printf("⚠️ skipping unusable starter pack entry %q", s)
			continue
		}
		if _, dup := seen[pk]; dup {
			continue
		}
		seen[pk] = struct{}{}
		out = append(out, pk)
	}
	return out
}
