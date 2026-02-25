//go:build !darwin

package darwinautomation

// checkTCCPermissions is a no-op on non-darwin platforms.
func checkTCCPermissions() map[string]string {
	return nil
}
