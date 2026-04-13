"""Shaker excitation generator using the Actuonix LAC + L12 actuator.

Generates sinusoidal, chirp (sweep), or step oscillation patterns
by commanding the LAC board via USB at high rate.

Usage examples:
    # Sinusoidal oscillation: 1 Hz, 50% amplitude, 30 seconds
    python tools/lac_shaker.py sine --freq 1.0 --amp 50 --duration 30

    # Frequency sweep (chirp): 0.5 → 5 Hz over 60 seconds
    python tools/lac_shaker.py chirp --freq-start 0.5 --freq-end 5.0 --amp 40 --duration 60

    # Move to static position (% of stroke)
    python tools/lac_shaker.py move --position 50

    # Center and stop
    python tools/lac_shaker.py stop

    # Read current position
    python tools/lac_shaker.py status
"""

import argparse
import math
import signal
import sys
import threading
import time

# Allow running from project root: python tools/lac_shaker.py
sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
from lac_controller import LACController


class LACShaker:
    """High-level shaker excitation interface for the LAC + L12."""

    def __init__(self, stroke_mm=50.0, update_hz=50, center_pct=50.0, **lac_kwargs):
        """
        Args:
            stroke_mm:  Actuator stroke length in mm (10, 30, 50, or 100).
            update_hz:  Position command rate in Hz (max ~50 due to LAC latency).
            center_pct: Rest position as % of stroke (0–100).
            **lac_kwargs: Passed to LACController (vid_pid, dll_path, etc.)
        """
        self.stroke_mm = stroke_mm
        self.update_hz = update_hz
        self.center_pct = center_pct
        self.lac = LACController(**lac_kwargs)
        self._running = False

    def open(self):
        self.lac.open()
        self.lac.set_speed(1023)  # max speed for responsive oscillation

    def close(self):
        self.stop()
        # Retract and wait so actuator reaches rest before USB release
        try:
            self.lac.set_position_pct(0.0)
            time.sleep(2.0)
        except Exception:
            pass
        self.lac.close()

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *args):
        self.close()

    # ── Static positioning ──────────────────────────────────────────────
    def move_to(self, position_pct):
        """Move actuator to a static position (0–100%)."""
        self._running = False
        self.lac.set_position_pct(position_pct)

    def center(self):
        """Return to center position."""
        self.move_to(self.center_pct)

    def stop(self):
        """Stop any oscillation and return to center."""
        self._running = False
        try:
            self.lac.set_position_pct(self.center_pct)
        except Exception:
            pass

    # ── Oscillation patterns ────────────────────────────────────────────
    def sine(self, freq_hz, amplitude_pct, duration_s, callback=None):
        """Run sinusoidal oscillation.

        Args:
            freq_hz:       Oscillation frequency in Hz.
            amplitude_pct: Peak-to-peak amplitude as % of stroke (0–100).
            duration_s:    Duration in seconds (0 = infinite).
            callback:      Optional fn(t, position_pct) called each step.
        """
        self._running = True
        dt = 1.0 / self.update_hz
        t0 = time.perf_counter()
        center = self.center_pct
        half_amp = amplitude_pct / 2.0

        print(f"[SHAKER] Sine: {freq_hz:.2f} Hz, amp={amplitude_pct:.1f}%, "
              f"center={center:.1f}%, duration={duration_s:.1f}s")

        try:
            while self._running:
                t = time.perf_counter() - t0
                if duration_s > 0 and t >= duration_s:
                    break

                pos = center + half_amp * math.sin(2.0 * math.pi * freq_hz * t)
                pos = max(0.0, min(100.0, pos))
                self.lac.set_position_pct(pos)

                if callback is not None:
                    callback(t, pos)

                # Maintain update rate
                elapsed = time.perf_counter() - t0 - t
                sleep_time = dt - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)
        finally:
            self.center()
            print("[SHAKER] Stopped — returned to center")

    def chirp(self, freq_start, freq_end, amplitude_pct, duration_s, callback=None):
        """Run linear frequency sweep (chirp).

        Args:
            freq_start:    Start frequency in Hz.
            freq_end:      End frequency in Hz.
            amplitude_pct: Peak-to-peak amplitude as % of stroke.
            duration_s:    Sweep duration in seconds.
            callback:      Optional fn(t, position_pct, freq_hz) called each step.
        """
        self._running = True
        dt = 1.0 / self.update_hz
        t0 = time.perf_counter()
        center = self.center_pct
        half_amp = amplitude_pct / 2.0
        k = (freq_end - freq_start) / duration_s  # chirp rate

        print(f"[SHAKER] Chirp: {freq_start:.2f}→{freq_end:.2f} Hz, "
              f"amp={amplitude_pct:.1f}%, duration={duration_s:.1f}s")

        try:
            while self._running:
                t = time.perf_counter() - t0
                if t >= duration_s:
                    break

                # Instantaneous frequency: f(t) = f0 + k*t
                # Phase: φ(t) = 2π(f0*t + k*t²/2)
                phase = 2.0 * math.pi * (freq_start * t + 0.5 * k * t * t)
                freq_now = freq_start + k * t
                pos = center + half_amp * math.sin(phase)
                pos = max(0.0, min(100.0, pos))
                self.lac.set_position_pct(pos)

                if callback is not None:
                    callback(t, pos, freq_now)

                elapsed = time.perf_counter() - t0 - t
                sleep_time = dt - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)
        finally:
            self.center()
            print("[SHAKER] Chirp complete — returned to center")

    def step_response(self, step_pct, hold_s=5.0):
        """Apply a step input for system identification.

        Args:
            step_pct: Step size as % of stroke from center.
            hold_s:   How long to hold the step position.
        """
        center = self.center_pct
        target = center + step_pct
        target = max(0.0, min(100.0, target))

        print(f"[SHAKER] Step: {center:.1f}% → {target:.1f}%, hold={hold_s:.1f}s")
        self.lac.set_position_pct(target)
        time.sleep(hold_s)
        self.center()
        print("[SHAKER] Step complete — returned to center")


def _signal_handler(shaker):
    """Create a Ctrl+C handler that stops the shaker gracefully."""
    def handler(sig, frame):
        print("\n[SHAKER] Ctrl+C — stopping...")
        shaker._running = False
    return handler


def _stdin_stop_listener(shaker):
    """Background thread: waits for Enter or 'stop' on stdin to stop the shaker."""
    try:
        for line in sys.stdin:
            cmd = line.strip().lower()
            if cmd in ("", "stop", "quit", "exit", "q"):
                print("[SHAKER] Stop requested from console")
                shaker._running = False
                break
    except EOFError:
        pass


def main():
    parser = argparse.ArgumentParser(
        description="LAC + L12 shaker excitation generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--vid", type=lambda x: int(x, 0), default=None,
                        help="USB Vendor ID, e.g. 0x04D8 (default: auto)")
    parser.add_argument("--pid", type=lambda x: int(x, 0), default=None,
                        help="USB Product ID, e.g. 0xFC5A (default: auto)")
    parser.add_argument("--stroke", type=float, default=50.0,
                        help="Actuator stroke in mm (default: 50)")
    parser.add_argument("--rate", type=int, default=50,
                        help="Position update rate in Hz (default: 50)")
    parser.add_argument("--center", type=float, default=50.0,
                        help="Center/rest position %% (default: 50)")

    sub = parser.add_subparsers(dest="mode", required=True)

    # ── sine ──
    p_sine = sub.add_parser("sine", help="Sinusoidal oscillation")
    p_sine.add_argument("--freq", type=float, required=True, help="Frequency in Hz")
    p_sine.add_argument("--amp", type=float, required=True, help="Amplitude %% of stroke")
    p_sine.add_argument("--duration", type=float, default=0, help="Duration (s), 0=infinite")

    # ── chirp ──
    p_chirp = sub.add_parser("chirp", help="Frequency sweep (chirp)")
    p_chirp.add_argument("--freq-start", type=float, required=True, help="Start freq Hz")
    p_chirp.add_argument("--freq-end", type=float, required=True, help="End freq Hz")
    p_chirp.add_argument("--amp", type=float, required=True, help="Amplitude %% of stroke")
    p_chirp.add_argument("--duration", type=float, required=True, help="Sweep duration (s)")

    # ── step ──
    p_step = sub.add_parser("step", help="Step response test")
    p_step.add_argument("--size", type=float, required=True, help="Step size %% from center")
    p_step.add_argument("--hold", type=float, default=5.0, help="Hold time (s)")

    # ── move ──
    p_move = sub.add_parser("move", help="Move to static position")
    p_move.add_argument("--position", type=float, required=True, help="Target position %%")

    # ── stop ──
    sub.add_parser("stop", help="Center and stop")

    # ── status ──
    sub.add_parser("status", help="Read current position")

    args = parser.parse_args()

    lac_kwargs = {}
    if args.vid is not None:
        lac_kwargs["vid"] = args.vid
    if args.pid is not None:
        lac_kwargs["pid"] = args.pid

    shaker = LACShaker(
        stroke_mm=args.stroke,
        update_hz=args.rate,
        center_pct=args.center,
        **lac_kwargs,
    )

    signal.signal(signal.SIGINT, _signal_handler(shaker))

    try:
        shaker.open()
        print(f"[SHAKER] Connected to LAC (stroke={args.stroke}mm, "
              f"update={args.rate}Hz, center={args.center}%)")

        # Start console listener for interactive stop
        if args.mode in ("sine", "chirp", "step"):
            print("[SHAKER] Press Enter or type 'stop' to stop at any time")
            stop_thread = threading.Thread(
                target=_stdin_stop_listener, args=(shaker,), daemon=True)
            stop_thread.start()

        if args.mode == "sine":
            shaker.sine(args.freq, args.amp, args.duration)
        elif args.mode == "chirp":
            shaker.chirp(args.freq_start, args.freq_end, args.amp, args.duration)
        elif args.mode == "step":
            shaker.step_response(args.size, args.hold)
        elif args.mode == "move":
            shaker.move_to(args.position)
            print(f"[SHAKER] Moved to {args.position:.1f}%")
        elif args.mode == "stop":
            shaker.center()
            print("[SHAKER] Centered")
        elif args.mode == "status":
            pos = shaker.lac.get_feedback()
            pct = pos / 1023.0 * 100.0
            mm = pos / 1023.0 * args.stroke
            print(f"[SHAKER] Position: {pos}/1023 ({pct:.1f}%, {mm:.2f}mm)")
    finally:
        shaker.close()


if __name__ == "__main__":
    main()
