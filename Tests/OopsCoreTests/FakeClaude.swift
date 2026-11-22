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
            /usr/bin/perl -e '
              setpgrp(0,0);
              sub record { open(my $f, ">>", $ARGV[0]) or die; print $f "$$\n"; close $f; }
              record();
              if (fork() == 0) { record(); exec "/bin/sleep", "301"; }
              exec "/bin/sleep", "302";' "$record.pids" &
            while [ "$(wc -l < "$record.pids")" -lt 3 ]; do sleep 0.01; done

            """#
        }
        source += #"""
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"system","subtype":"thinking_tokens"}'
        echo '{"type":"assistant","message":{"content":[{"type":"thinking"},{"type":"tool_use","name":"WebSearch","input":{"query":"iana example domain"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://www.example.com/page"}}]}}'
        echo '{"type":"system","subtype":"permission_denied","tool_name":"Write"}'

        """#
        switch mode {
        case .answer:
            source += #"echo '{"type":"result","subtype":"success","structured_output":{"text":"answer"},"permission_denials":[{"tool_name":"Write"}]}'"# + "\nexec sleep 5"
        case .orphan:
            source += #"""
            trap '' TERM
            /bin/sleep 300 </dev/null >/dev/null 2>&1 &
            echo "$!" >> "$record.pids"
            exit 0
            """#
        case .slow, .child: source += "exec sleep 300"
        case .noSandbox: source += "echo 'Error: sandbox is required but not available' >&2\nexit 1"
        case .error: source += #"echo '{"type":"result","is_error":true,"api_error_status":429}'"#
        }
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
