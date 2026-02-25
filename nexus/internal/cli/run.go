// Package cli provides shared CLI entry-point logic for the nexusd binary
// across platforms (Linux, macOS). Platform-specific main.go files call
// Run with their default configuration path and optional config hooks.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/daemon"
	"cybros.ai/nexus/enroll"
	"cybros.ai/nexus/version"
)

// ConfigHook is called after the config is loaded but before the daemon starts.
// Platform-specific main.go files can use it to apply defaults (e.g., macOS
// default sandbox profiles).
type ConfigHook func(cfg *config.Config)

// Run is the shared entry point for nexusd.
func Run(defaultConfigPath string, hooks ...ConfigHook) {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	var configPath string
	var showVersion bool
	var showDoctor bool
	var enrollToken string
	var enrollOutDir string
	var enrollWithCSR bool
	var enrollName string

	flag.StringVar(&configPath, "config", defaultConfigPath, "Path to nexus config YAML")
	flag.BoolVar(&showVersion, "version", false, "Print version and exit")
	flag.BoolVar(&showDoctor, "doctor", false, "Run self-check and exit")
	flag.StringVar(&enrollToken, "enroll-token", "", "Enrollment token (if set, enroll and exit)")
	flag.StringVar(&enrollOutDir, "enroll-out-dir", "./nexus-credentials", "Output dir for issued mTLS credentials (only used with -enroll-with-csr)")
	flag.BoolVar(&enrollWithCSR, "enroll-with-csr", true, "Generate CSR and request mTLS client cert during enrollment")
	flag.StringVar(&enrollName, "enroll-name", "", "Territory name override (defaults to config name)")
	flag.Parse()

	if showVersion {
		println(version.Full())
		return
	}

	if showDoctor {
		var cfgPtr *config.Config
		if cfg, err := config.LoadFile(configPath); err == nil {
			cfgPtr = &cfg
		}

		checks := RunDoctor(cfgPtr)
		PrintDoctorResults(checks)
		return
	}

	cfg, err := config.LoadFile(configPath)
	if err != nil {
		slog.Error("load config failed", "error", err)
		os.Exit(1)
	}

	for _, hook := range hooks {
		hook(&cfg)
	}

	if enrollToken != "" {
		ctx, cancel := signalContext()
		defer cancel()

		name := cfg.Name
		if enrollName != "" {
			name = enrollName
		}

		res, err := enroll.Run(ctx, cfg, enroll.Options{
			EnrollToken: enrollToken,
			Name:        name,
			Labels:      cfg.Labels,
			OutDir:      enrollOutDir,
			WithCSR:     enrollWithCSR,
		})
		if err != nil {
			slog.Error("enroll failed", "error", err)
			os.Exit(1)
		}

		_ = json.NewEncoder(os.Stdout).Encode(res)
		return
	}

	svc, err := daemon.New(cfg)
	if err != nil {
		slog.Error("init nexusd failed", "error", err)
		os.Exit(1)
	}

	ctx, cancel := signalContext()
	defer cancel()

	if err := svc.Serve(ctx); err != nil && !errors.Is(err, context.Canceled) {
		slog.Info("nexusd stopped", "error", err)
	}
}

func signalContext() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		cancel()
		<-ch
		os.Exit(1)
	}()
	return ctx, cancel
}
