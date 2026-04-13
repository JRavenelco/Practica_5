"""Quick self-test for lac_controller / lac_shaker.

Run without hardware to verify imports and DLL search work:
    python tools/test_lac_setup.py

With LAC connected via USB:
    python tools/test_lac_setup.py --live
"""

import sys
from pathlib import Path

# Ensure tools/ is on the path
sys.path.insert(0, str(Path(__file__).parent))


def test_imports():
    print("=== Test 1: Import modules ===")
    try:
        import lac_controller
        print(f"  lac_controller imported OK from {lac_controller.__file__}")
    except ImportError as e:
        print(f"  FAIL: {e}")
        return False

    try:
        import lac_shaker
        print(f"  lac_shaker imported OK from {lac_shaker.__file__}")
    except ImportError as e:
        print(f"  FAIL: {e}")
        return False

    return True


def test_usb_backend():
    print("\n=== Test 2: USB backend (pyusb + libusb) ===")
    try:
        import usb.core
        print(f"  pyusb version: {usb.__version__ if hasattr(usb, '__version__') else 'OK'}")
    except ImportError as e:
        print(f"  FAIL: pyusb not installed — run: pip install pyusb libusb-package")
        return False

    try:
        import libusb_package
        backend = libusb_package.get_libusb1_backend()
        if backend:
            print(f"  libusb-package backend: OK")
        else:
            print(f"  libusb-package backend: returned None (will use default)")
    except ImportError:
        print("  libusb-package not installed — run: pip install libusb-package")
        print("  Will try default backend")
    except Exception as e:
        print(f"  libusb-package warning: {e}")

    return True


def test_class_creation():
    print("\n=== Test 3: Create LACController (no connection) ===")
    from lac_controller import LACController
    lac = LACController()
    print(f"  VID       = 0x{lac.vid:04X}")
    print(f"  PID       = 0x{lac.pid:04X}")
    print(f"  timeout   = {lac.timeout_ms} ms")
    print("  OK — object created (not connected)")
    return True


def test_shaker_creation():
    print("\n=== Test 4: Create LACShaker (no connection) ===")
    from lac_shaker import LACShaker
    shaker = LACShaker(stroke_mm=50.0, update_hz=50, center_pct=50.0)
    print(f"  stroke    = {shaker.stroke_mm} mm")
    print(f"  update_hz = {shaker.update_hz}")
    print(f"  center    = {shaker.center_pct}%")
    print("  OK — object created (not connected)")
    return True


def test_live():
    print("\n=== Test 5: LIVE — Connect to LAC ===")
    from lac_controller import LACController

    try:
        lac = LACController()
        lac.open()
        print("  Connected to LAC!")

        pos = lac.get_feedback()
        pct = pos / 1023.0 * 100.0
        print(f"  Current position: {pos}/1023 ({pct:.1f}%)")

        print("  Moving to 50% (center)...")
        lac.set_position_pct(50.0)

        import time
        time.sleep(1.0)

        pos = lac.get_feedback()
        pct = pos / 1023.0 * 100.0
        print(f"  Position after move: {pos}/1023 ({pct:.1f}%)")

        print("  Moving to 30%...")
        lac.set_position_pct(30.0)
        time.sleep(1.0)

        print("  Moving back to 50%...")
        lac.set_position_pct(50.0)
        time.sleep(2.0)

        pos = lac.get_feedback()
        pct = pos / 1023.0 * 100.0
        print(f"  Final position: {pos}/1023 ({pct:.1f}%)")

        # Retract fully before releasing so actuator doesn't keep moving
        print("  Retracting to 0% before disconnect...")
        lac.set_position_pct(0.0)
        time.sleep(2.0)

        lac.close()
        print("  LIVE test PASSED")
        return True

    except FileNotFoundError as e:
        print(f"  SKIP: {e}")
        return False
    except ConnectionError as e:
        print(f"  FAIL: {e}")
        return False
    except Exception as e:
        print(f"  FAIL: {type(e).__name__}: {e}")
        return False


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Test LAC controller setup")
    parser.add_argument("--live", action="store_true",
                        help="Run live hardware test (requires LAC connected)")
    args = parser.parse_args()

    results = []
    results.append(("Imports", test_imports()))
    results.append(("USB backend", test_usb_backend()))
    results.append(("LACController", test_class_creation()))
    results.append(("LACShaker", test_shaker_creation()))

    if args.live:
        results.append(("Live connection", test_live()))

    print("\n" + "=" * 50)
    print("RESULTS:")
    all_ok = True
    for name, ok in results:
        status = "PASS" if ok else "FAIL/SKIP"
        print(f"  {name}: {status}")
        if not ok and name not in ("USB backend",):
            all_ok = False

    if all_ok:
        print("\nAll critical tests passed!")
        if not args.live:
            print("Run with --live to test actual LAC hardware.")
    else:
        print("\nSome tests failed — check messages above.")

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
