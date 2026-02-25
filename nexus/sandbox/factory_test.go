package sandbox

import (
	"context"
	"testing"
)

// stubDriver implements Driver for testing.
type stubDriver struct {
	name    string
	healthy bool
}

func (s *stubDriver) Name() string { return s.name }
func (s *stubDriver) Run(_ context.Context, _ RunRequest) (RunResult, error) {
	return RunResult{}, nil
}
func (s *stubDriver) HealthCheck(_ context.Context) HealthResult {
	if s.healthy {
		return HealthResult{Healthy: true, Details: map[string]string{"driver": s.name}}
	}
	return HealthResult{Healthy: false, Details: map[string]string{"driver": s.name, "error": "test unhealthy"}}
}

func TestFactory_Get(t *testing.T) {
	host := &stubDriver{name: "host", healthy: true}
	bwrap := &stubDriver{name: "bwrap", healthy: true}
	container := &stubDriver{name: "container", healthy: true}

	tests := []struct {
		name       string
		drivers    []Driver
		profile    string
		wantDriver string
		wantErr    bool
	}{
		{
			name:       "host profile returns host driver",
			drivers:    []Driver{host},
			profile:    "host",
			wantDriver: "host",
		},
		{
			name:       "untrusted profile returns bwrap driver",
			drivers:    []Driver{host, bwrap},
			profile:    "untrusted",
			wantDriver: "bwrap",
		},
		{
			name:       "trusted profile returns container driver",
			drivers:    []Driver{host, container},
			profile:    "trusted",
			wantDriver: "container",
		},
		{
			name:       "trusted falls back to host when no container",
			drivers:    []Driver{host},
			profile:    "trusted",
			wantDriver: "host",
		},
		{
			name:    "untrusted fails when no bwrap",
			drivers: []Driver{host},
			profile: "untrusted",
			wantErr: true,
		},
		{
			name:    "unknown profile fails",
			drivers: []Driver{host},
			profile: "unknown",
			wantErr: true,
		},
		{
			name:       "darwin-automation profile returns darwin-automation driver",
			drivers:    []Driver{host, &stubDriver{name: "darwin-automation", healthy: true}},
			profile:    "darwin-automation",
			wantDriver: "darwin-automation",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			factory := NewFactory(tt.drivers...)
			d, err := factory.Get(tt.profile)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if d.Name() != tt.wantDriver {
				t.Errorf("got driver %q, want %q", d.Name(), tt.wantDriver)
			}
		})
	}
}

func TestFactory_HealthCheckAll(t *testing.T) {
	host := &stubDriver{name: "host", healthy: true}
	bwrap := &stubDriver{name: "bwrap", healthy: true}
	unhealthy := &stubDriver{name: "container", healthy: false}

	t.Run("all healthy", func(t *testing.T) {
		factory := NewFactory(host, bwrap)
		results := factory.HealthCheckAll(context.Background())
		if len(results) != 2 {
			t.Fatalf("expected 2 results, got %d", len(results))
		}
		for name, r := range results {
			if !r.Healthy {
				t.Errorf("driver %q should be healthy", name)
			}
		}
	})

	t.Run("mixed healthy and unhealthy", func(t *testing.T) {
		factory := NewFactory(host, unhealthy)
		results := factory.HealthCheckAll(context.Background())
		if len(results) != 2 {
			t.Fatalf("expected 2 results, got %d", len(results))
		}
		if !results["host"].Healthy {
			t.Error("host should be healthy")
		}
		if results["container"].Healthy {
			t.Error("container should be unhealthy")
		}
		if results["container"].Details["error"] != "test unhealthy" {
			t.Errorf("expected error detail, got %v", results["container"].Details)
		}
	})

	t.Run("empty factory", func(t *testing.T) {
		factory := NewFactory()
		results := factory.HealthCheckAll(context.Background())
		if len(results) != 0 {
			t.Fatalf("expected 0 results, got %d", len(results))
		}
	})
}

func TestFactory_SupportedProfiles(t *testing.T) {
	host := &stubDriver{name: "host", healthy: true}
	bwrap := &stubDriver{name: "bwrap", healthy: true}
	container := &stubDriver{name: "container", healthy: true}

	tests := []struct {
		name     string
		drivers  []Driver
		expected []string
	}{
		{
			name:     "host only",
			drivers:  []Driver{host},
			expected: []string{"host", "trusted"},
		},
		{
			name:     "host + bwrap",
			drivers:  []Driver{host, bwrap},
			expected: []string{"host", "untrusted", "trusted"},
		},
		{
			name:     "all drivers",
			drivers:  []Driver{host, bwrap, container},
			expected: []string{"host", "untrusted", "trusted"},
		},
		{
			name:     "host + darwin-automation",
			drivers:  []Driver{host, &stubDriver{name: "darwin-automation", healthy: true}},
			expected: []string{"host", "trusted", "darwin-automation"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			factory := NewFactory(tt.drivers...)
			got := factory.SupportedProfiles()
			if len(got) != len(tt.expected) {
				t.Fatalf("got %v, want %v", got, tt.expected)
			}
			for i, p := range got {
				if p != tt.expected[i] {
					t.Errorf("profiles[%d] = %q, want %q", i, p, tt.expected[i])
				}
			}
		})
	}
}
