#+build !windows
package platform

// Lets the process pid bring its window to the front. Only Windows keeps the
// front for the process the user last gave input to; elsewhere the window
// raises itself.
window_foreground_allow :: proc(pid:int) {}
