package firecracker

import (
	"encoding/json"
	"testing"
)

func TestBuildVMConfig_Basic(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/opt/nexus/vmlinux",
		RootfsPath:   "/opt/nexus/rootfs.ext4",
		CmdImagePath: "/tmp/cmd.ext4",
		WsImagePath:  "/tmp/ws.ext4",
		VCPUs:        2,
		MemSizeMiB:   512,
	})

	if cfg.BootSource.KernelImagePath != "/opt/nexus/vmlinux" {
		t.Errorf("kernel path = %q, want /opt/nexus/vmlinux", cfg.BootSource.KernelImagePath)
	}
	if cfg.BootSource.BootArgs != defaultBootArgs {
		t.Errorf("boot args = %q, want %q", cfg.BootSource.BootArgs, defaultBootArgs)
	}
	if len(cfg.Drives) != 3 {
		t.Fatalf("drives count = %d, want 3", len(cfg.Drives))
	}
	if cfg.Drives[0].DriveID != "rootfs" || !cfg.Drives[0].IsRootDevice || !cfg.Drives[0].IsReadOnly {
		t.Error("rootfs drive misconfigured")
	}
	if cfg.Drives[1].DriveID != "cmd" || cfg.Drives[1].IsRootDevice || !cfg.Drives[1].IsReadOnly {
		t.Error("cmd drive misconfigured")
	}
	if cfg.Drives[2].DriveID != "workspace" || cfg.Drives[2].IsRootDevice || cfg.Drives[2].IsReadOnly {
		t.Error("workspace drive misconfigured")
	}
	if cfg.MachineConfig.VCPUCount != 2 || cfg.MachineConfig.MemSizeMiB != 512 {
		t.Error("machine config mismatch")
	}
	if cfg.Vsock != nil {
		t.Error("vsock should be nil when UDSPath is empty")
	}
}

func TestBuildVMConfig_WithVsock(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/opt/nexus/vmlinux",
		RootfsPath:   "/opt/nexus/rootfs.ext4",
		CmdImagePath: "/tmp/cmd.ext4",
		WsImagePath:  "/tmp/ws.ext4",
		VCPUs:        4,
		MemSizeMiB:   1024,
		VsockUDSPath: "/tmp/vsock.sock",
	})

	if cfg.Vsock == nil {
		t.Fatal("vsock should not be nil")
	}
	if cfg.Vsock.GuestCID != 3 {
		t.Errorf("guest CID = %d, want 3", cfg.Vsock.GuestCID)
	}
	if cfg.Vsock.UDSPath != "/tmp/vsock.sock" {
		t.Errorf("vsock UDS path = %q, want /tmp/vsock.sock", cfg.Vsock.UDSPath)
	}
	if cfg.MachineConfig.VCPUCount != 4 || cfg.MachineConfig.MemSizeMiB != 1024 {
		t.Error("machine config mismatch")
	}
}

func TestMarshalVMConfig_ValidJSON(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
		VsockUDSPath: "/vsock.sock",
	})

	data, err := MarshalVMConfig(cfg)
	if err != nil {
		t.Fatalf("MarshalVMConfig error: %v", err)
	}

	// Verify it's valid JSON by round-tripping
	var parsed VMConfig
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("JSON round-trip failed: %v", err)
	}
	if parsed.BootSource.KernelImagePath != "/vmlinux" {
		t.Error("round-trip lost kernel path")
	}
	if parsed.Vsock == nil || parsed.Vsock.UDSPath != "/vsock.sock" {
		t.Error("round-trip lost vsock config")
	}
}

func TestBuildVMConfig_DriveOrder(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/k",
		RootfsPath:   "/r",
		CmdImagePath: "/c",
		WsImagePath:  "/w",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	// Verify drive order: rootfs (vda), cmd (vdb), workspace (vdc)
	expected := []struct {
		id   string
		path string
	}{
		{"rootfs", "/r"},
		{"cmd", "/c"},
		{"workspace", "/w"},
	}

	for i, exp := range expected {
		if cfg.Drives[i].DriveID != exp.id {
			t.Errorf("drive[%d].id = %q, want %q", i, cfg.Drives[i].DriveID, exp.id)
		}
		if cfg.Drives[i].PathOnHost != exp.path {
			t.Errorf("drive[%d].path = %q, want %q", i, cfg.Drives[i].PathOnHost, exp.path)
		}
	}
}
