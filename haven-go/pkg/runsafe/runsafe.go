// Package runsafe provides panic-isolation for background goroutines.
//
// haven runs embedded inside host apps (macOS/iOS via c-shared dylib,
// Android via JNI). A panic on any bare goroutine terminates the entire
// host process — for the desktop apps that means the whole GUI app
// crashes, typically while idle in the background. Every long-lived or
// event-driven goroutine must therefore be spawned through this package
// so a panic becomes a logged error instead of a process death.
package runsafe

import (
	"log"
	"runtime/debug"
)

// Run executes fn, converting any panic into a logged error. log.Printf
// reaches the host app's log pipe (Swift captureOutput / Android logcat),
// so recovered panics stay visible for diagnosis.
func Run(name string, fn func()) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("🚫 PANIC recovered in %s: %v\n%s", name, r, debug.Stack())
		}
	}()
	fn()
}

// Go spawns fn on a new goroutine with panic recovery.
func Go(name string, fn func()) {
	go Run(name, fn)
}
