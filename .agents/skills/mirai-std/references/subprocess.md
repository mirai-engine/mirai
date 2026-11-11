# std/subprocess

Package `subprocess` (`import "mirai:std/subprocess"`), the one implementation of child processes:
`tools/mirai`, `cook/*` and the editor (players, AI agents, git, builds) use it. It depends on no
other package.

## API

- `start` launches a child and returns a `Process`; `wait`, `terminate` and `release` take it by
  pointer, and `wait` keeps its exit in it. `exec` runs a child to the end and captures stdout and
  stderr; `detached` launches one that outlives the caller (`mirai session start`, the editor that
  restarts). `subprocess.odin` documents each one.
- With `pipes`, stdout and stderr (separate or merged) and stdin come back as pipes. `read` returns
  what arrived, `write` what the pipe took and `wait` with timeout 0 whether it ended: none of them
  waits or allocates, so the editor drains its children every frame. A child that fills a pipe
  nobody reads stops.
- `env` replaces the environment; whoever adds variables passes `os.environ` followed by them: of a
  name given twice, the last one wins on every platform.
- An invalid input (empty command, a NUL byte, an `env` entry without a name) gives
  `.Invalid_Command` and a program that is not there `.Not_Exist`, without launching anything.
- `Limits.memory` bounds what each process of the child and its children may commit: Windows applies
  it with the job of the child and Linux with `RLIMIT_DATA`, both before it runs; macOS does not
  limit the memory of another process.

## Tree

- A child and everything it starts end together: when this process ends, however it ends; on
  `terminate` and `release`; and when `wait` sees the child exit, which ends what it left running.
  Only `detached` leaves the tree.
- Windows: a job object per child with kill-on-close, the child joined before it runs. Its handle is
  held only by this process, so the system ends the tree when this process ends. The job allows
  breakaway, so a `detached` grandchild still leaves it.
- POSIX: a process group per child and a watcher process in that group, forked from this one, that
  waits for this process to end (`pidfd` on Linux, `kqueue` on macOS) and then kills the group. The
  watcher ignores SIGTERM; `release` and `wait` reap it.
- On POSIX the group of a child is not the terminal's: Ctrl+C reaches only this process, whose end
  ends the child, and a child that reads the terminal stops. Writing to the stdin pipe of a child
  that ended returns an error: this process ignores SIGPIPE once it starts a child with pipes.

## Windows

- A console program launched by a process without a console receives a console of its own, and
  Windows shows it unless asked otherwise: `start` and `exec` ask for it to have no window only if
  the process has no console; if it has one, the child shares it and receives Ctrl+C and the
  terminal.
- `detached` gives the child a windowless console of its own and takes it out of the caller's job if
  the job allows it: closing the terminal, Ctrl+C in it or ending the job does not terminate it.
- The child inherits only stdin, stdout and stderr: the pipes of other children launched at the same
  time do not stay open in it. The command line follows the rules of the C runtime, without
  `cmd.exe`.
- The stdin pipe does not block, and a write larger than the free space delivers nothing: `write`
  passes 4 KB at a time.
- Why not `core:os`: [compiler workarounds](../../../../docs/ODIN_WORKAROUNDS.md).

## Verification

- `mirai test std/subprocess`. The test program also acts as the child: with
  `mirai-subprocess-probe` as the first argument it executes an action and ends before the tests.
- `a_child_ends_with_its_tree` covers the tree: a child that starts a grandchild, ended by
  `terminate` and killed alone as a crash ends it, leaves no grandchild.
- On Windows, the tests launch from a process without a console a child that reports whether it has
  a visible window, and require that it does not; the same with `detached`.
- It has no `hostile_test.odin`: launching random programs is not safe. Invalid inputs have their
  own test.
