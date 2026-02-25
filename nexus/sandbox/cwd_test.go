package sandbox

import (
	"path/filepath"
	"testing"
)

func TestResolveWorkspaceCwd(t *testing.T) {
	t.Parallel()

	base := t.TempDir()

	tests := []struct {
		name      string
		requested string
		want      string
		wantErr   bool
	}{
		{name: "empty", requested: "", want: base},
		{name: "dot", requested: ".", want: base},
		{name: "workspace", requested: "/workspace", want: base},
		{name: "workspace-sub", requested: "/workspace/sub/dir", want: filepath.Join(base, "sub/dir")},
		{name: "relative", requested: "sub/dir", want: filepath.Join(base, "sub/dir")},
		{name: "abs-outside", requested: "/etc", wantErr: true},
		{name: "relative-escape", requested: "../escape", wantErr: true},
		{name: "workspace-escape", requested: "/workspace/../escape", wantErr: true},
		{name: "empty-workdir", requested: "sub", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			workDir := base
			if tt.name == "empty-workdir" {
				workDir = ""
			}

			got, err := ResolveWorkspaceCwd(workDir, tt.requested)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil (cwd=%q)", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("unexpected cwd: got %q want %q", got, tt.want)
			}
		})
	}
}

func TestSafeJoin(t *testing.T) {
	t.Parallel()

	base := t.TempDir()

	tests := []struct {
		name    string
		rel     string
		want    string
		wantErr bool
	}{
		{name: "simple", rel: "sub", want: filepath.Join(base, "sub")},
		{name: "nested", rel: "a/b/c", want: filepath.Join(base, "a/b/c")},
		{name: "dot", rel: ".", want: base},
		{name: "escape-parent", rel: "..", wantErr: true},
		{name: "escape-nested", rel: "../../etc", wantErr: true},
		{name: "escape-tricky", rel: "sub/../../etc", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := SafeJoin(base, tt.rel)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil (path=%q)", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("unexpected path: got %q want %q", got, tt.want)
			}
		})
	}
}
