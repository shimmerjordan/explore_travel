// Package frpmobile is a thin, gomobile-bindable wrapper around the frp
// client (frpc). It is compiled to an Android AAR and an iOS XCFramework via
// `gomobile bind` (see docs/frp_embed.md) and driven from Dart over a
// platform channel (lib/services/group/frp_engine_io.dart).
//
// Why a wrapper: gomobile can only bind a small surface — exported structs
// whose methods take/return strings, ints, bools, byte slices, or other
// bound types. So we expose exactly: New / Start / Reload / Stop / Running,
// plus a LogSink reverse-interface the native side implements to receive
// frpc log lines (forwarded to Dart's EventChannel).
//
// IMPORTANT (build-time): pin frp in go.mod to the version you test against —
// frp's embedding API (pkg/config, client.NewService) has changed across
// minor releases. This file targets the v0.5x service API; adjust imports if
// you pin a different line. None of this compiles in the Flutter analyzer —
// it is built in CI / on a machine with the Go toolchain + gomobile.
package frpmobile

import (
	"context"
	"fmt"
	"sync"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/config/v1/validation"
)

// LogSink is implemented on the native side (Kotlin/Swift). Keep it tiny —
// gomobile reverse interfaces must use only bound-friendly types.
type LogSink interface {
	Log(line string)
}

// Engine owns a single frpc service instance.
type Engine struct {
	mu     sync.Mutex
	svc    *client.Service
	cancel context.CancelFunc
	sink   LogSink
}

func New() *Engine { return &Engine{} }

// SetLogSink wires frpc's logs back to the native side. Optional.
func (e *Engine) SetLogSink(sink LogSink) {
	e.mu.Lock()
	e.sink = sink
	e.mu.Unlock()
}

func (e *Engine) log(format string, a ...interface{}) {
	e.mu.Lock()
	s := e.sink
	e.mu.Unlock()
	if s != nil {
		s.Log(fmt.Sprintf(format, a...))
	}
}

// Start parses the TOML client config and runs frpc. If a service is already
// running it is stopped first (so Start doubles as a hard reset).
func (e *Engine) Start(configToml string) error {
	e.Stop()

	cfg, proxies, visitors, err := parse(configToml)
	if err != nil {
		return err
	}

	svc, err := client.NewService(client.ServiceOptions{
		Common:         cfg,
		ProxyCfgs:      proxies,
		VisitorCfgs:    visitors,
	})
	if err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	e.mu.Lock()
	e.svc = svc
	e.cancel = cancel
	e.mu.Unlock()

	go func() {
		e.log("frpc starting")
		if rerr := svc.Run(ctx); rerr != nil {
			e.log("frpc exited: %v", rerr)
		}
	}()
	return nil
}

// Reload hot-applies a new config (added/removed visitors as the roster
// changes) WITHOUT tearing down established tunnels.
func (e *Engine) Reload(configToml string) error {
	e.mu.Lock()
	svc := e.svc
	e.mu.Unlock()
	if svc == nil {
		return e.Start(configToml)
	}
	_, proxies, visitors, err := parse(configToml)
	if err != nil {
		return err
	}
	// frp >= v0.52 exposes runtime reconfiguration of proxies + visitors.
	if rerr := svc.UpdateAllConfigurer(proxies, visitors); rerr != nil {
		// Fall back to a full restart if the live update path errors.
		e.log("reload via update failed (%v); restarting", rerr)
		return e.Start(configToml)
	}
	e.log("frpc reloaded")
	return nil
}

func (e *Engine) Stop() {
	e.mu.Lock()
	cancel := e.cancel
	svc := e.svc
	e.svc = nil
	e.cancel = nil
	e.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if svc != nil {
		svc.Close()
	}
}

func (e *Engine) Running() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.svc != nil
}

// parse loads the TOML into frp's typed config + validates it.
func parse(toml string) (*v1.ClientCommonConfig, []v1.ProxyConfigurer, []v1.VisitorConfigurer, error) {
	common, proxies, visitors, err := config.LoadClientConfig([]byte(toml), false)
	if err != nil {
		return nil, nil, nil, err
	}
	if _, err := validation.ValidateAllClientConfig(common, proxies, visitors); err != nil {
		return nil, nil, nil, err
	}
	return common, proxies, visitors, nil
}
