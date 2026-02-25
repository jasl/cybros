package firecracker

import (
	"testing"
)

func TestCreateImageFromDir_Validation(t *testing.T) {
	tests := []struct {
		name      string
		dir       string
		imagePath string
		sizeMiB   int
		wantErr   string
	}{
		{"empty dir", "", "/tmp/test.ext4", 64, "source directory is required"},
		{"empty image", "/tmp/src", "", 64, "image path is required"},
		{"zero size", "/tmp/src", "/tmp/test.ext4", 0, "size must be > 0 MiB"},
		{"negative size", "/tmp/src", "/tmp/test.ext4", -1, "size must be > 0 MiB"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := CreateImageFromDir(tt.dir, tt.imagePath, tt.sizeMiB)
			if err == nil {
				t.Fatal("expected error")
			}
			if got := err.Error(); got != tt.wantErr {
				t.Errorf("error = %q, want %q", got, tt.wantErr)
			}
		})
	}
}

func TestExtractImageToDir_Validation(t *testing.T) {
	tests := []struct {
		name      string
		imagePath string
		dir       string
		wantErr   string
	}{
		{"empty image", "", "/tmp/dst", "image path is required"},
		{"empty dir", "/tmp/test.ext4", "", "destination directory is required"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ExtractImageToDir(tt.imagePath, tt.dir)
			if err == nil {
				t.Fatal("expected error")
			}
			if got := err.Error(); got != tt.wantErr {
				t.Errorf("error = %q, want %q", got, tt.wantErr)
			}
		})
	}
}

