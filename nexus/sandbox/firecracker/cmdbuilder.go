package firecracker

import "encoding/json"

// VMConfig is the Firecracker --config-file JSON structure.
type VMConfig struct {
	BootSource    BootSource    `json:"boot-source"`
	Drives        []Drive       `json:"drives"`
	MachineConfig MachineConfig `json:"machine-config"`
	Vsock         *VsockConfig  `json:"vsock,omitempty"`
}

// BootSource configures the guest kernel.
type BootSource struct {
	KernelImagePath string `json:"kernel_image_path"`
	BootArgs        string `json:"boot_args"`
}

// Drive configures a block device.
type Drive struct {
	DriveID      string `json:"drive_id"`
	PathOnHost   string `json:"path_on_host"`
	IsRootDevice bool   `json:"is_root_device"`
	IsReadOnly   bool   `json:"is_read_only"`
}

// MachineConfig configures VM resources.
type MachineConfig struct {
	VCPUCount  int  `json:"vcpu_count"`
	MemSizeMiB int  `json:"mem_size_mib"`
	SMT        bool `json:"smt"`
}

// VsockConfig configures the virtio-vsock device.
type VsockConfig struct {
	VsockID  string `json:"vsock_id"`
	GuestCID int    `json:"guest_cid"`
	UDSPath  string `json:"uds_path"`
}

// VMConfigInput holds the inputs for building a VM config.
type VMConfigInput struct {
	KernelPath    string
	RootfsPath    string
	CmdImagePath  string
	WsImagePath   string
	VCPUs         int
	MemSizeMiB    int
	VsockUDSPath  string // empty = no vsock
}

// Default boot args for the microVM.
const defaultBootArgs = "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/nexus-init"

// BuildVMConfig constructs a Firecracker VM configuration.
func BuildVMConfig(input VMConfigInput) VMConfig {
	cfg := VMConfig{
		BootSource: BootSource{
			KernelImagePath: input.KernelPath,
			BootArgs:        defaultBootArgs,
		},
		Drives: []Drive{
			{
				DriveID:      "rootfs",
				PathOnHost:   input.RootfsPath,
				IsRootDevice: true,
				IsReadOnly:   true,
			},
			{
				DriveID:      "cmd",
				PathOnHost:   input.CmdImagePath,
				IsRootDevice: false,
				IsReadOnly:   true,
			},
			{
				DriveID:      "workspace",
				PathOnHost:   input.WsImagePath,
				IsRootDevice: false,
				IsReadOnly:   false,
			},
		},
		MachineConfig: MachineConfig{
			VCPUCount:  input.VCPUs,
			MemSizeMiB: input.MemSizeMiB,
			SMT:        false,
		},
	}

	if input.VsockUDSPath != "" {
		cfg.Vsock = &VsockConfig{
			VsockID:  "vsock0",
			GuestCID: 3,
			UDSPath:  input.VsockUDSPath,
		}
	}

	return cfg
}

// MarshalVMConfig serializes a VM config to JSON.
func MarshalVMConfig(cfg VMConfig) ([]byte, error) {
	return json.MarshalIndent(cfg, "", "  ")
}
