package protocol

import (
	"encoding/json"
	"testing"
)

// --- JSON round-trip ---

func TestPollRequest_JSONRoundTrip(t *testing.T) {
	t.Parallel()

	orig := PollRequest{
		SupportedSandboxProfiles: []string{"host", "darwin-automation"},
		MaxDirectivesToClaim:     5,
	}
	b, err := json.Marshal(orig)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got PollRequest
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.SupportedSandboxProfiles) != 2 {
		t.Fatalf("expected 2 profiles, got %d", len(got.SupportedSandboxProfiles))
	}
	if got.MaxDirectivesToClaim != 5 {
		t.Fatalf("expected MaxDirectivesToClaim=5, got %d", got.MaxDirectivesToClaim)
	}
}

func TestPollResponse_JSONRoundTrip(t *testing.T) {
	t.Parallel()

	orig := PollResponse{
		Directives: []DirectiveLease{
			{DirectiveID: "d-1", DirectiveToken: "tok-1"},
		},
		LeaseTTLSeconds:   300,
		RetryAfterSeconds: 10,
	}
	b, _ := json.Marshal(orig)

	var got PollResponse
	json.Unmarshal(b, &got)

	if len(got.Directives) != 1 || got.Directives[0].DirectiveID != "d-1" {
		t.Fatalf("expected directive d-1, got %+v", got.Directives)
	}
	if got.LeaseTTLSeconds != 300 {
		t.Fatalf("expected LeaseTTLSeconds=300, got %d", got.LeaseTTLSeconds)
	}
}

func TestEnrollRequest_JSONFieldNames(t *testing.T) {
	t.Parallel()

	req := EnrollRequest{
		EnrollToken: "tok",
		Name:        "node-1",
		CSRPEM:      "-----BEGIN CERTIFICATE REQUEST-----\n...",
	}
	b, _ := json.Marshal(req)

	var raw map[string]any
	json.Unmarshal(b, &raw)

	// Verify JSON field names match the spec.
	if _, ok := raw["enroll_token"]; !ok {
		t.Error("expected enroll_token key in JSON")
	}
	if _, ok := raw["csr_pem"]; !ok {
		t.Error("expected csr_pem key in JSON")
	}
	// omitempty: labels should be absent.
	if _, ok := raw["labels"]; ok {
		t.Error("expected labels to be omitted")
	}
}

// --- Pointer field (ExitCode *int) ---

func TestFinishedRequest_ExitCodeZero(t *testing.T) {
	t.Parallel()

	exitCode := 0
	req := FinishedRequest{ExitCode: &exitCode, Status: "succeeded"}
	b, _ := json.Marshal(req)

	var raw map[string]any
	json.Unmarshal(b, &raw)

	// ExitCode=0 must be present (not omitted), since it's a pointer field.
	ec, ok := raw["exit_code"]
	if !ok {
		t.Fatal("exit_code should be present when pointer is non-nil with value 0")
	}
	if ec.(float64) != 0 {
		t.Fatalf("expected exit_code=0, got %v", ec)
	}
}

func TestFinishedRequest_ExitCodeNil(t *testing.T) {
	t.Parallel()

	req := FinishedRequest{ExitCode: nil, Status: "canceled"}
	b, _ := json.Marshal(req)

	var raw map[string]any
	json.Unmarshal(b, &raw)

	// ExitCode=nil: the "exit_code" key is still present because there's no omitempty.
	_, ok := raw["exit_code"]
	if !ok {
		t.Fatal("exit_code should be present even when nil (no omitempty on pointer)")
	}
}

func TestFinishedRequest_JSONRoundTrip(t *testing.T) {
	t.Parallel()

	exitCode := 42
	orig := FinishedRequest{
		ExitCode:        &exitCode,
		Status:          "failed",
		StdoutTruncated: true,
		DiffBase64:      "ZGlmZg==",
	}
	b, _ := json.Marshal(orig)

	var got FinishedRequest
	json.Unmarshal(b, &got)

	if got.ExitCode == nil || *got.ExitCode != 42 {
		t.Fatalf("expected ExitCode=42, got %v", got.ExitCode)
	}
	if got.Status != "failed" {
		t.Fatalf("expected status=failed, got %s", got.Status)
	}
	if !got.StdoutTruncated {
		t.Error("expected StdoutTruncated=true")
	}
}

// --- omitempty behavior ---

func TestHeartbeatResponse_OmitEmpty(t *testing.T) {
	t.Parallel()

	resp := HeartbeatResponse{CancelRequested: false, LeaseRenewed: false}
	b, _ := json.Marshal(resp)

	var raw map[string]any
	json.Unmarshal(b, &raw)

	// Both fields have omitempty and are false/zero — should be absent.
	if _, ok := raw["cancel_requested"]; ok {
		t.Error("expected cancel_requested to be omitted when false")
	}
	if _, ok := raw["directive_token"]; ok {
		t.Error("expected directive_token to be omitted when empty")
	}
}

func TestDirectiveSpec_NestedJSON(t *testing.T) {
	t.Parallel()

	spec := DirectiveSpec{
		DirectiveID:    "d-99",
		SandboxProfile: "darwin-automation",
		Command:        "echo hello",
		Facility:       FacilitySpec{ID: "f-1", Mount: "/workspace"},
		Capabilities: Capabilities{
			Net: &NetCapabilityV1{Mode: "none"},
		},
	}
	b, _ := json.Marshal(spec)

	var got DirectiveSpec
	json.Unmarshal(b, &got)

	if got.DirectiveID != "d-99" {
		t.Fatalf("expected d-99, got %s", got.DirectiveID)
	}
	if got.Facility.Mount != "/workspace" {
		t.Fatalf("expected /workspace, got %s", got.Facility.Mount)
	}
	if got.Capabilities.Net == nil || got.Capabilities.Net.Mode != "none" {
		t.Fatalf("expected net mode=none, got %+v", got.Capabilities.Net)
	}
	if got.Capabilities.Fs != nil {
		t.Error("expected Fs to be nil")
	}
}

func TestLogChunkRequest_JSONRoundTrip(t *testing.T) {
	t.Parallel()

	orig := LogChunkRequest{Stream: "stdout", Seq: 7, BytesBase64: "aGVsbG8=", Truncated: true}
	b, _ := json.Marshal(orig)

	var got LogChunkRequest
	json.Unmarshal(b, &got)

	if got.Stream != "stdout" || got.Seq != 7 || got.BytesBase64 != "aGVsbG8=" || !got.Truncated {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}
