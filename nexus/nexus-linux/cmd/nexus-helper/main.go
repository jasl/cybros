package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	var mode string
	flag.StringVar(&mode, "mode", "noop", "helper mode (noop|doctor)")
	flag.Parse()

	switch mode {
	case "noop":
		fmt.Println("nexus-helper: noop (privileged helper skeleton).")
		fmt.Println("TODO: implement minimal privileged operations (netns/tap/nft/cgroup/jailer) behind a strict RPC API.")
	case "doctor":
		fmt.Println("nexus-helper: doctor (skeleton)")
		fmt.Println("TODO: check nftables/iptables availability, CAP_NET_ADMIN, cgroups v2, etc.")
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", mode)
		os.Exit(2)
	}
}
