#+build !windows
package host

// The libraries a library of a project links carry the folder of their
// dependencies in their rpath.
library_dependencies_where :: proc(folder:string) {}
