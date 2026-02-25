package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"

	"cybros.ai/nexus/client"
	"cybros.ai/nexus/logstream"
	"cybros.ai/nexus/protocol"
	"cybros.ai/nexus/sandbox"
	"cybros.ai/nexus/version"
)

func (s *Service) handleDirective(ctx context.Context, lease protocol.DirectiveLease) error {
	directiveStart := time.Now()
	spec := lease.Spec
	directiveID := lease.DirectiveID
	token := newTokenHolder(lease.DirectiveToken)

	// Check disk space before committing to this directive.
	avail, err := checkDiskSpace(s.cfg.WorkDir)
	if err != nil {
		slog.Warn("disk space check failed", "directive_id", directiveID, "error", err)
	} else if avail < minDiskBytes {
		slog.Error("insufficient disk space, rejecting directive",
			"directive_id", directiveID,
			"available_bytes", avail,
			"min_bytes", minDiskBytes,
		)
		return s.rejectDirective(ctx, directiveID, token, spec, directiveStart,
			"failed", "insufficient disk space")
	}

	if !isValidFacilityID(spec.Facility.ID) {
		slog.Error("invalid facility ID, rejecting directive",
			"directive_id", directiveID, "facility_id", spec.Facility.ID)
		return s.rejectDirective(ctx, directiveID, token, spec, directiveStart,
			"failed", "invalid facility ID")
	}
	facilityPath := filepath.Join(s.cfg.WorkDir, spec.Facility.ID)
	if err := os.MkdirAll(facilityPath, 0o755); err != nil {
		return err
	}

	// Create an execution context: with timeout if configured, otherwise just
	// cancellable so server-side cancel requests can terminate execution.
	var execCtx context.Context
	var execCancel context.CancelFunc
	if spec.TimeoutSeconds > 0 {
		execCtx, execCancel = context.WithTimeout(ctx, time.Duration(spec.TimeoutSeconds)*time.Second)
	} else {
		execCtx, execCancel = context.WithCancel(ctx)
	}
	defer execCancel()

	// Select driver for this directive based on sandbox profile.
	profile := spec.SandboxProfile
	if profile == "" {
		profile = "host"
	}
	s.recordTape("directive_claimed", directiveID, spec, "", profile, map[string]any{
		"timeout_seconds": spec.TimeoutSeconds,
		"repo_url":        sandbox.RedactRepoURL(spec.Facility.RepoURL),
	})
	drv, err := s.factory.Get(profile)
	if err != nil {
		s.recordTape("driver_select_failed", directiveID, spec, "", profile, map[string]any{"error": err.Error()})
		return fmt.Errorf("select driver for profile %q: %w", profile, err)
	}
	driverName := drv.Name()
	s.recordTape("driver_selected", directiveID, spec, driverName, profile, nil)

	// Pre-assignment health check: verify driver is operational before committing.
	// Use a dedicated context so this doesn't consume the directive's execution timeout.
	healthCtx, healthCancel := context.WithTimeout(ctx, 10*time.Second)
	healthResult := drv.HealthCheck(healthCtx)
	healthCancel()
	if !healthResult.Healthy {
		s.recordTape("driver_unhealthy", directiveID, spec, driverName, profile, map[string]any{
			"health_details": healthResult.Details,
		})
		slog.Error("driver unhealthy, rejecting directive",
			"directive_id", directiveID, "driver", driverName,
			"health_details", healthResult.Details,
		)
		return s.rejectDirective(ctx, directiveID, token, spec, directiveStart,
			"failed", "driver_unhealthy")
	}

	// Report started (must succeed before we upload log_chunks; otherwise the server is still in `leased`)
	eff := map[string]any{
		"driver":  driverName,
		"profile": profile,
		"net":     spec.Capabilities.Net, // echo for audit (actual enforcement depends on profile/driver)
		"fs":      spec.Capabilities.Fs,
	}
	startedReq := protocol.StartedRequest{
		EffectiveCapabilitiesSummary: eff,
		SandboxVersion:               fmt.Sprintf("phase1-%s", drv.Name()),
		NexusVersion:                 version.Version,
		StartedAt:                    time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := postWithRetry(ctx, "started", func() error {
		reqCtx, cancel := client.WithTimeout(ctx)
		defer cancel()
		return s.cli.Started(reqCtx, directiveID, token.Get(), startedReq)
	}); err != nil {
		s.recordTape("started_post_failed", directiveID, spec, driverName, profile, map[string]any{"error": err.Error()})
		return fmt.Errorf("post started: %w", err)
	}
	s.recordTape("started_posted", directiveID, spec, driverName, profile, map[string]any{
		"sandbox_version": startedReq.SandboxVersion,
	})

	// Setup log uploader (server enforces max_output_bytes; this is best-effort client-side)
	maxOutputBytes := s.cfg.Log.MaxOutputBytes
	if spec.Limits.MaxOutputBytes > 0 {
		maxOutputBytes = int64(spec.Limits.MaxOutputBytes)
	}
	uploader := logstream.New(s.cli, directiveID, token.Get, s.cfg.Log.ChunkBytes, maxOutputBytes)
	defer func() { _ = uploader.Close() }()
	if s.cfg.LogOverflow.Enabled {
		uploader.EnableOverflow(filepath.Join(facilityPath, s.cfg.LogOverflow.Dir, directiveID), s.cfg.LogOverflow.MaxBytesPerStream)
	}

	// Start heartbeat goroutine — runs concurrently with prepare+execution.
	// The heartbeat loop refreshes the token in the shared tokenHolder.
	var cancelRequested atomic.Bool
	heartbeatCtx, heartbeatCancel := context.WithCancel(execCtx)
	heartbeatDone := make(chan struct{})

	go func() {
		defer close(heartbeatDone)
		s.runHeartbeatLoop(heartbeatCtx, directiveID, spec.Facility.ID, profile, driverName, token, &cancelRequested, execCancel)
	}()

	// Prepare facility: host-executing drivers clone on the host filesystem.
	// Isolated drivers (bwrap/container/firecracker) handle facility prep inside
	// the sandbox via RepoURL in RunRequest.
	if driverName == "host" || driverName == "darwin-automation" {
		if err := s.prepareFacility(execCtx, directiveID, facilityPath, spec, uploader, driverName, profile); err != nil {
			s.recordTape("prepare_failed", directiveID, spec, driverName, profile, map[string]any{"error": err.Error()})
			uploader.UploadBytes(ctx, "stderr", []byte(fmt.Sprintf("[prepare] failed: %v\n", err)))

			heartbeatCancel()
			<-heartbeatDone

			status := "failed"
			exitCode := 1
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(execCtx.Err(), context.DeadlineExceeded) {
				status = "timed_out"
				exitCode = 124
			} else if errors.Is(err, context.Canceled) || errors.Is(execCtx.Err(), context.Canceled) {
				status = "canceled"
				exitCode = 137
			}

			finishReq := protocol.FinishedRequest{
				ExitCode:          &exitCode,
				Status:            status,
				StdoutTruncated:   uploader.StdoutTruncated(),
				StderrTruncated:   uploader.StderrTruncated(),
				ArtifactsManifest: map[string]any{},
				FinishedAt:        time.Now().UTC().Format(time.RFC3339Nano),
			}
			if manifest := buildLogOverflowManifest(spec, directiveID, s.cfg.LogOverflow, uploader); manifest != nil {
				finishReq.ArtifactsManifest["log_overflow"] = manifest
			}
			if postErr := postWithRetry(ctx, "finished", func() error {
				reqCtx, cancel := client.WithTimeout(ctx)
				defer cancel()
				return s.cli.Finished(reqCtx, directiveID, token.Get(), finishReq)
			}); postErr != nil {
				s.recordTape("finished_post_failed", directiveID, spec, driverName, profile, map[string]any{"error": postErr.Error()})
				if walErr := s.wal.Append(walEntry{
					Timestamp: time.Now().UTC().Format(time.RFC3339Nano), DirectiveID: directiveID,
					Token: token.Get(), Request: finishReq,
				}); walErr != nil {
					slog.Error("WAL append failed", "directive_id", directiveID, "error", walErr)
				}
				return fmt.Errorf("prepare failed (%v); post finished: %w", err, postErr)
			}
			s.recordTape("finished_posted", directiveID, spec, driverName, profile, map[string]any{"status": status, "exit_code": exitCode})
			s.metrics.DirectivesTotal.WithLabelValues(status).Inc()
			s.metrics.DirectiveDuration.WithLabelValues(driverName, profile).Observe(time.Since(directiveStart).Seconds())
			return nil
		}
	}

	// Inject standard environment variables for the directive
	env := buildDirectiveEnv(s.cfg, directiveID, spec)

	req := sandbox.RunRequest{
		DirectiveID:    directiveID,
		Command:        spec.Command,
		Shell:          spec.Shell,
		Cwd:            spec.Cwd,
		Env:            env,
		WorkDir:        facilityPath,
		TimeoutSeconds: spec.TimeoutSeconds,
		MaxOutputBytes: maxOutputBytes,
		ChunkBytes:     s.cfg.Log.ChunkBytes,
		LogSink:        uploader,
		// Capability plumbing for sandbox drivers
		NetCapability: spec.Capabilities.Net,
		FsCapability:  spec.Capabilities.Fs,
		RepoURL:       spec.Facility.RepoURL,
		FacilityPath:  facilityPath,
		Limits:        spec.Limits,
	}

	s.recordTape("run_started", directiveID, spec, driverName, profile, map[string]any{
		"cwd": spec.Cwd,
	})
	res, err := drv.Run(execCtx, req)
	if err != nil {
		slog.Error("driver run failed", "directive_id", directiveID, "driver", driverName, "error", err)
		s.recordTape("driver_error", directiveID, spec, driverName, profile, map[string]any{"error": err.Error()})
	}
	tapeData := map[string]any{
		"status":    res.Status,
		"exit_code": res.ExitCode,
	}
	if len(res.Warnings) > 0 {
		tapeData["warnings"] = res.Warnings
		for _, w := range res.Warnings {
			slog.Warn("driver warning", "directive_id", directiveID, "warning", w)
		}
	}
	s.recordTape("run_finished", directiveID, spec, driverName, profile, tapeData)

	// Stop heartbeat loop
	heartbeatCancel()
	<-heartbeatDone

	status := res.Status
	if status == "" {
		status = "failed"
	}
	if err != nil && status == "succeeded" {
		status = "failed"
	}
	// If cancel was requested and the process didn't succeed, mark as canceled
	if cancelRequested.Load() && status != "succeeded" {
		status = "canceled"
	}

	// Collect diff if this is a repo-type facility (use parent ctx, not execCtx
	// which may already be canceled/timed out)
	diffBase64 := s.collectDiff(ctx, facilityPath, spec)

	// Report finished
	artifacts := map[string]any{}
	if manifest := buildLogOverflowManifest(spec, directiveID, s.cfg.LogOverflow, uploader); manifest != nil {
		artifacts["log_overflow"] = manifest
	}

	// log a local structured summary (helps offline debugging)
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
		"event":            "directive_finished",
		"directive_id":     directiveID,
		"status":           status,
		"exit_code":        res.ExitCode,
		"stdout_truncated": res.StdoutTruncated,
		"stderr_truncated": res.StderrTruncated,
	})

	finishReq := protocol.FinishedRequest{
		ExitCode:          &res.ExitCode,
		Status:            status,
		StdoutTruncated:   res.StdoutTruncated,
		StderrTruncated:   res.StderrTruncated,
		DiffBase64:        diffBase64,
		ArtifactsManifest: artifacts,
		FinishedAt:        time.Now().UTC().Format(time.RFC3339Nano),
	}
	if postErr := postWithRetry(ctx, "finished", func() error {
		reqCtx, cancel := client.WithTimeout(ctx)
		defer cancel()
		return s.cli.Finished(reqCtx, directiveID, token.Get(), finishReq)
	}); postErr != nil {
		s.recordTape("finished_post_failed", directiveID, spec, driverName, profile, map[string]any{"error": postErr.Error()})
		if walErr := s.wal.Append(walEntry{
			Timestamp: time.Now().UTC().Format(time.RFC3339Nano), DirectiveID: directiveID,
			Token: token.Get(), Request: finishReq,
		}); walErr != nil {
			slog.Error("WAL append failed", "directive_id", directiveID, "error", walErr)
		}
		return fmt.Errorf("post finished: %w", postErr)
	}
	s.recordTape("finished_posted", directiveID, spec, driverName, profile, map[string]any{"status": status, "exit_code": res.ExitCode})

	s.metrics.DirectivesTotal.WithLabelValues(status).Inc()
	s.metrics.DirectiveDuration.WithLabelValues(driverName, profile).Observe(time.Since(directiveStart).Seconds())
	return nil
}

func (s *Service) prepareFacility(ctx context.Context, directiveID string, facilityPath string, spec protocol.DirectiveSpec, uploader *logstream.Uploader, driverName string, profile string) error {
	repoURL := spec.Facility.RepoURL
	if repoURL == "" {
		return nil
	}

	if !sandbox.IsAllowedRepoScheme(repoURL) {
		s.recordTape("prepare_clone_rejected", directiveID, spec, driverName, profile, map[string]any{
			"error":    "repo_url uses disallowed scheme",
			"repo_url": sandbox.RedactRepoURL(repoURL),
		})
		return fmt.Errorf("repo_url uses disallowed scheme (only https, http, ssh, git, or scp-like ssh are allowed)")
	}

	// Acquire a file lock to prevent concurrent clone races on the same facility.
	lockPath := facilityPath + ".lock"
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock file: %w", err)
	}
	defer lockFile.Close()
	defer os.Remove(lockPath)
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire lock: %w", err)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)

	entries, err := os.ReadDir(facilityPath)
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		s.recordTape("prepare_clone_skipped", directiveID, spec, driverName, profile, map[string]any{
			"reason":   "workspace_not_empty",
			"entries":  len(entries),
			"repo_url": sandbox.RedactRepoURL(repoURL),
		})
		return nil
	}

	s.recordTape("prepare_clone_started", directiveID, spec, driverName, profile, map[string]any{
		"repo_url": sandbox.RedactRepoURL(repoURL),
	})
	uploader.UploadBytes(ctx, "stderr", []byte(fmt.Sprintf("[prepare] facility empty; cloning %s\n", sandbox.RedactRepoURL(repoURL))))

	cmd := exec.CommandContext(ctx, "git", "clone", "--depth", "1", "--", repoURL, ".")
	cmd.Dir = facilityPath
	cmd.Env = append(minimalExecEnv(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=true",
		"GIT_PROTOCOL_FROM_USER=0",              // disable ext:: and other user-facing protocols
		"GIT_ALLOW_PROTOCOL=http:https:ssh:git", // enforce allowed transports even with gitconfig rewrites
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	// Stream prepare logs through the same uploader (seq continues across prepare+execution).
	errCh := make(chan error, 2)
	go func() { errCh <- uploader.Consume(ctx, "stdout", stdout) }()
	go func() { errCh <- uploader.Consume(ctx, "stderr", stderr) }()

	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	if consume1 != nil {
		return consume1
	}
	if consume2 != nil {
		return consume2
	}
	if waitErr != nil {
		s.recordTape("prepare_clone_failed", directiveID, spec, driverName, profile, map[string]any{
			"repo_url": sandbox.RedactRepoURL(repoURL),
			"error":    waitErr.Error(),
		})
		return fmt.Errorf("git clone: %w", waitErr)
	}

	s.recordTape("prepare_clone_succeeded", directiveID, spec, driverName, profile, map[string]any{
		"repo_url": sandbox.RedactRepoURL(repoURL),
	})
	return nil
}

// collectDiff runs `git diff HEAD` in the facility directory and returns
// the diff as a base64-encoded string. Returns "" if the facility is not
// a git repo or if the diff is empty/too large.
func (s *Service) collectDiff(parentCtx context.Context, facilityPath string, spec protocol.DirectiveSpec) string {
	// Only collect diff for facilities with a repo_url
	if spec.Facility.RepoURL == "" {
		return ""
	}

	// Check if it's a git repo
	gitDir := filepath.Join(facilityPath, ".git")
	if _, err := os.Stat(gitDir); err != nil {
		return ""
	}

	ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", "diff", "HEAD")
	cmd.Dir = facilityPath
	cmd.Env = append(minimalExecEnv(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_PAGER=cat",
	)

	out, err := cmd.Output()
	if err != nil {
		slog.Warn("git diff failed", "path", facilityPath, "error", err)
		return ""
	}

	if len(out) == 0 {
		return ""
	}

	// Enforce max_diff_bytes from spec (default 1 MiB)
	maxDiffBytes := spec.Limits.MaxDiffBytes
	if maxDiffBytes <= 0 {
		maxDiffBytes = 1_048_576
	}
	if len(out) > maxDiffBytes {
		slog.Warn("diff too large, skipping", "bytes", len(out), "max_bytes", maxDiffBytes)
		return ""
	}

	return base64.StdEncoding.EncodeToString(out)
}
