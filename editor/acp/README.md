# Mirai ACP client

`acp` is the native Odin client of the [Agent Client Protocol v1](https://agentclientprotocol.com/protocol/v1/initialization). The provider adapter is still an external process: for Codex it runs the [official `codex-acp` adapter](https://github.com/agentclientprotocol/codex-acp), which controls its Codex binary, and for Claude `claude-agent-acp`, which runs Claude Code. This package does not implement the harness nor manage installations or credentials; the client keeps what `initialize` announced (`load_session`, `resume_session`, `close_session`, `http_mcp`, `image`, `embedded_context`, `session_rename`) for its consumer.

## Cycle

`create(&client, allocator)` initializes the state in place and reserves the buffers once with the allocator it receives. `start` opens the process through `platform`, separates stdout and stderr and sends `initialize`; `poll` writes what is pending and consumes JSON-RPC lines without blocking. A frame without data does not allocate. Parsing uses the temporary allocator only when complete messages arrive. The values of `Event` are borrowed during the callback.

On receiving `Initialized`, the consumer can call `authenticate` or `open_session`. The latter creates a session, or resumes the one given with `session/resume` when it is announced, and otherwise with `session/load`. Resuming with `load` marks its updates as `replay` so that the project store does not duplicate messages. An agent with neither of those capabilities returns `Unsupported` when asked to resume.

If a session is already ready and the agent announces `sessionCapabilities.close`, `open_session` first sends `session/close` for the previous session and waits for its answer before creating or resuming the requested one. The process is kept. Closing frees the active state of the agent and keeps the native history; resuming the same conversation sets up the MCP servers and their headers again for the new turn. This avoids keeping an MCP connection of an earlier turn in a reused process. The pending descriptor lives in preallocated buffers separate from the active ID. If closing fails, `Error` is emitted and the next session does not start. An agent that does not announce closing does not receive that method.

`Session_Desc` carries the absolute project folder, an ACP JSON array of MCP servers, the chosen model and effort, and an optional JSON object sent as `_meta` of `session/new`, `session/load` and `session/resume` (Claude reads the settings of its session there); one that is not an object returns `Invalid_Message`, and one longer than its buffer `Capacity`. The selectors are found by the `model` and `thought_level` categories of `configOptions`. The options must include the exact value asked for; if it is missing, `Error` is emitted and no other model or effort is substituted. Each configuration answer emits `Config_Options`; once the session is configured, `Session_Ready` arrives.

`start(..., session_titles=true)` announces only `sessionIndex` of the documented [AIR extension of `codex-acp`](https://github.com/agentclientprotocol/codex-acp/blob/main/docs/air-extensions.md), with version 1. The answer must announce `sessionRename` before a non-empty `Session_Desc.title` is accepted; without that negotiation, `open_session` returns `Unsupported` without creating a session. The explicit name is sent with `_session/rename` after the model and effort and before `Session_Ready`. A rename error emits `Error` and does not start the turn. The configuration results arrive in `Config_Options`; the `Session_Ready` after the rename carries its empty answer. The other providers keep the common ACP negotiation and receive no title request.

Codex ACP delivers names through `session_info_update.title`; they are history metadata, not an answer of the agent. In version 2.2.2, its automatic generation of a summarized name uses a fixed auxiliary model (`gpt-5.6-luna`). Confirming an explicit name before the first prompt turns that generation off without changing the adapter or starting another model call. Claude Agent ACP 0.89.1 announces `sessionRename` too, but carries it out through the `rename_session` request of Claude Code, which the Claude Code 2.1 a user may have answers as unsupported; the editor does not ask it. The editor uses the start of the first message as the initial name. An adapter that does not announce renaming cannot guarantee that the auxiliary call does not happen; a consumer that requires an explicit name must treat `Unsupported` as an error.

`prompt` accepts several blocks: editor instructions and the user message in `Text` blocks, base64 images when they are announced, embedded resources when they are announced, and resource links. `Update` delivers the complete agent events, messages and tools included. `Prompt_Done` leaves the client in `Ready`, keeping the process and the session ID. The consumer decides when to shut it down for inactivity and saves the ID in the project history.

`initialize` announces `session.compaction`, so the adapters report compaction through `Update`.
`steer` adds blocks to the turn in flight with `_session/steering`, and only if `initialize`
announced `_meta.steering.supported` in `steering`. It leaves the phase and the pending prompt
alone. Each accepted steer gets exactly one `Steer_Done`, whose `steer_id` is the `Client.steer_id`
read right after that `steer`, whose `text` is the outcome and that never ends the turn nor emits
`Error`. `promptRequired` means no turn took the input and it was not consumed; `failed` covers an
RPC error, an unknown answer and an agent that exits before answering.

`compact_command` says whether the latest `available_commands_update` of the session listed
`compact`; asking for a session clears it. `Update` still delivers that message.

## Permissions and errors

`Permission` delivers the official options and the request ID as JSON. The consumer shows the options to the user, keeps that ID and answers with `permission`; the package never picks one by itself. `cancel` sends the ACP notification and waits for the answer of the generation to end the turn; as the protocol asks, the consumer answers what is still pending with `permission(..., cancelled=true)`.

No filesystem or terminal capabilities are announced: the agent uses its own tools and the MCP servers of the session. A request for a client method that is not implemented receives `-32601`. RPC errors keep their code and detail, and are shown even if the connection stays configured. The stderr output is delivered separately and never read as ACP.

The default buffers accept an incoming line of 2 MiB and 4 MiB of outgoing data. A prompt that does not fit returns `Capacity` before changing the queue. An incoming line that is too long or an incompatible protocol fails explicitly. Startup and configuration requests have a deadline of 120 seconds; the turn has no generation limit imposed by the transport.

`stop` closes stdin and gives the adapter up to three seconds to close its agent; the following `poll` calls collect the output and the end of the process. If it does not end, the adapter process is forced to close. `destroy` frees the handle and the buffers; use the cooperative close before destroying so that the provider cleans up its children.

## Verification

The tests of `editor/acp` cover fragmented framing and UTF-8, negotiation, MCP, exact model and effort, resuming, sequential closing of ready sessions and renewal of MCP headers, close errors without opening another session, explicit titles negotiated before the prompt, refusal of titles without the capability and rename errors without starting a turn, prompt blocks, explicit permissions, cancellation, limits, authentication errors and no allocations with the client idle. On macOS and Linux they also run a real process through `platform`, negotiate and check its output when stdin closes. The tests do not download packages nor use an account. The optional smoke test with the real account configures `gpt-6-luna`/`low` and an explicit name before its two turns.
