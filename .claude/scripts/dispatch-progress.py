#!/usr/bin/env python3
"""
Progress display for Claude Code stream-json output.

Reads stream-json lines from stdin, shows compact progress on terminal,
writes full raw stream to a log file. Prints a heartbeat every N seconds
(even during silent periods like long builds).

Usage:
    claude -p --output-format stream-json ... | dispatch-progress.py LOG_FILE [HEARTBEAT_SEC]
"""

import json
import sys
import time
import signal
import threading


def shorten(s, max_len=80):
    s = str(s).replace('\n', ' ').strip()
    if len(s) <= max_len:
        return s
    return '...' + s[-(max_len - 3):]


def format_tool(name, inp):
    if name == 'Read':
        return f"Read {shorten(inp.get('file_path', ''), 60)}"
    elif name == 'Edit':
        return f"Edit {shorten(inp.get('file_path', ''), 60)}"
    elif name == 'Write':
        return f"Write {shorten(inp.get('file_path', ''), 60)}"
    elif name == 'Glob':
        return f"Glob {inp.get('pattern', '')}"
    elif name == 'Grep':
        return f"Grep '{shorten(inp.get('pattern', ''), 30)}'"
    elif name == 'Bash':
        return f"$ {shorten(inp.get('command', ''), 70)}"
    elif name == 'Agent':
        desc = inp.get('description', '')
        if not desc:
            desc = shorten(inp.get('prompt', ''), 50)
        return f"Agent: {shorten(desc, 60)}"
    elif name == 'Skill':
        return f"Skill: {inp.get('skill', '?')}"
    else:
        return name


# Shared state for heartbeat thread
_lock = threading.Lock()
_start_time = 0.0
_tool_count = 0
_last_tool = ''
_done = False


def ts(elapsed):
    return f"{int(elapsed // 60)}m{int(elapsed % 60):02d}s"


def emit(elapsed, msg):
    print(f"  [{ts(elapsed):>7s}] {msg}", flush=True)


def heartbeat_loop(interval):
    """Background thread: prints a heartbeat every `interval` seconds."""
    global _done
    while not _done:
        time.sleep(interval)
        if _done:
            break
        with _lock:
            elapsed = time.time() - _start_time
            tc = _tool_count
            lt = _last_tool
        ctx = f", last: {lt}" if lt else ""
        emit(elapsed, f"~ heartbeat — {tc} tool calls{ctx}")


def extract_tool_uses(ev):
    """Extract tool_use blocks from various event formats."""
    results = []
    etype = ev.get('type', '')

    # {"type":"assistant","message":{"content":[{"type":"tool_use",...}]}}
    if etype == 'assistant':
        msg = ev.get('message', {})
        for block in msg.get('content', []):
            if isinstance(block, dict) and block.get('type') == 'tool_use':
                results.append((block.get('name', '?'), block.get('input', {})))

    # {"type":"tool_use","name":"...","input":{...}}
    elif etype == 'tool_use':
        name = ev.get('name', ev.get('tool', {}).get('name', '?'))
        inp = ev.get('input', ev.get('tool', {}).get('input', {}))
        results.append((name, inp))

    # {"type":"content_block_start","content_block":{"type":"tool_use",...}}
    elif etype == 'content_block_start':
        cb = ev.get('content_block', {})
        if cb.get('type') == 'tool_use':
            results.append((cb.get('name', '?'), cb.get('input', {})))

    return results


def main():
    global _start_time, _tool_count, _last_tool, _done

    log_path = sys.argv[1] if len(sys.argv) > 1 else '/dev/null'
    heartbeat_sec = int(sys.argv[2]) if len(sys.argv) > 2 else 30

    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    _start_time = time.time()
    seen_result = False

    # Start background heartbeat thread
    hb_thread = threading.Thread(target=heartbeat_loop, args=(heartbeat_sec,), daemon=True)
    hb_thread.start()

    with open(log_path, 'w') as lf:
        for raw in sys.stdin:
            lf.write(raw)
            lf.flush()

            raw = raw.strip()
            if not raw:
                continue

            try:
                ev = json.loads(raw)
            except (json.JSONDecodeError, ValueError):
                continue

            elapsed = time.time() - _start_time
            etype = ev.get('type', '')

            # Tool use events
            for name, inp in extract_tool_uses(ev):
                with _lock:
                    _tool_count += 1
                    _last_tool = name
                    tc = _tool_count
                desc = format_tool(name, inp)
                emit(elapsed, f"#{tc:<4d} {desc}")

            # Result event
            if etype == 'result':
                seen_result = True
                cost = ev.get('cost_usd', 0)
                dur_s = ev.get('duration_ms', 0) / 1000
                sub = ev.get('subtype', '')
                icon = '+' if sub == 'success' else '!'
                with _lock:
                    tc = _tool_count
                emit(elapsed, f"{icon} Done — ${cost:.2f}, {dur_s:.0f}s, {tc} tool calls")

    # Stop heartbeat thread
    _done = True
    hb_thread.join(timeout=2)

    # Final line if no result event was seen
    if not seen_result:
        elapsed = time.time() - _start_time
        with _lock:
            tc = _tool_count
        emit(elapsed, f"stream ended — {tc} tool calls total")


if __name__ == '__main__':
    main()
