import Foundation

enum FakeClaude {
    enum Mode { case answer, slow, child, orphan, noSandbox, error }

    static func script(_ mode: Mode, in folder: URL, record: URL) throws -> URL {
        let script = folder.appendingPathComponent("claude")
        let quoted = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var source = #"""
        #!/bin/sh
        record=\#(quoted)
        pwd -P >> "$record"
        printf '%s\n' "$@" >> "$record"
        test ! -L .claude/skills || echo staged >> "$record"
        printf '%s\n' "${UNRELATED_SECRET_KEY+present}" "${CLAUDE_TEST_VALUE:-}" "${ANTHROPIC_TEST_VALUE:-}" > "$record.env"
        input=$(cat)
        case " $* " in
          *" --input-format=stream-json "*)
            printf '%s\n' "$input" >> "$record"
            echo '{"type":"control_response","response":{"response":{"commands":[{"name":"review"}]}}}'
            exit 0 ;;
        esac
        echo "$$" >> "$record.pids"
        printf '%s' "$input" > "$record.input"

        """#
        if mode == .child {
            source += #"""
            trap '' TERM
            mkfifo "$record.pids.ready" || exit 1
            /usr/bin/perl -e '
              setpgrp(0,0);
              sub record { open(my $f, ">>", $ARGV[0]) or die; print $f "$$\n"; close $f; }
              record();
              if (fork() == 0) {
                alarm 600;
                record();
                open(my $ready, ">", "$ARGV[0].ready") or die;
                print $ready "ready\n";
                close $ready;
              }
              sleep 600;' "$record.pids" &
            read -r ready < "$record.pids.ready"

            """#
        }
        source += #"""
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"system","subtype":"thinking_tokens"}'
        echo '{"type":"assistant","message":{"content":[{"type":"thinking"},{"type":"tool_use","id":"s1","name":"WebSearch","input":{"query":"iana example domain"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"results"}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://www.example.com/page"}}]}}'
        echo '{"type":"system","subtype":"permission_denied","tool_name":"Write"}'

        """#
        switch mode {
        case .answer:
            source += #"echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"StructuredOutput","input":{}}}}'"# + "\n"
            source += #"echo '{"type":"system","subtype":"post_turn_summary","status_detail":"answered from the page"}'"# + "\n"
            source += #"echo '{"type":"result","subtype":"success","structured_output":{"text":"answer"},"permission_denials":[{"tool_name":"Write"}]}'"# + "\nexec /usr/bin/perl -e 'sleep 600'"
        case .orphan:
            source += #"""
            trap '' TERM
            /usr/bin/perl -e 'sleep 600' </dev/null >/dev/null 2>&1 &
            echo "$!" >> "$record.pids"
            exit 0
            """#
        case .slow, .child: source += "exec /usr/bin/perl -e 'sleep 600'"
        case .noSandbox: source += "echo 'Error: sandbox is required but not available' >&2\nexit 1"
        case .error: source += #"echo '{"type":"result","is_error":true,"api_error_status":429}'"#
        }
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

extension FakeClaude {
    static func directoryChanges(in folder: URL) throws -> AsyncStream<Void> {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global())
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { events in
            source.setRegistrationHandler { events.yield(()) }
            source.setEventHandler { events.yield(()) }
            source.setCancelHandler { close(fd) }
            events.onTermination = { _ in source.cancel() }
            source.activate()
        }
    }
}
