#+build !windows
package platform

import "core:testing"

// The check of a hidden native window is written for Windows only.
native_hidden_window_checks :: proc(t:^testing.T) {}
native_veiled_window_checks :: proc(t:^testing.T) {}
