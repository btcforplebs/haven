//go:build !cshared

package main

import (
	"runtime"

	"github.com/fiatjaf/eventstore/lmdb"
)

func init() {
	lmdbFactory = func(path string) DBBackend {
		mapSize := config.LmdbMapSize
		if mapSize == 0 {
			switch runtime.GOOS {
			case "ios":
				mapSize = 256 << 20 // 256 MB
			case "darwin":
				mapSize = 1 << 30 // 1 GB
			}
		}
		return &lmdb.LMDBBackend{
			Path:    path,
			MapSize: mapSize,
		}
	}
}
