import argparse
import queue
import sys
import threading
import time
from pathlib import Path

from pydwf import DwfLibrary


def list_devices() -> int:
    dwf = DwfLibrary()
    device_enum = dwf.deviceEnum
    count = device_enum.enumerateDevices()
    if count == 0:
        print("No Digilent WaveForms devices found.")
        return 1
    print(f"Found {count} Digilent device(s):")
    for index in range(count):
        name = device_enum.deviceName(index)
        serial = device_enum.serialNumber(index)
        user_name = device_enum.userName(index)
        print(f"[{index}] name={name} serial={serial} user={user_name}")
    return 0


def _call_variants(method, variants, method_name: str):
    errors = []
    for args, kwargs in variants:
        try:
            return method(*args, **kwargs)
        except TypeError as exc:
            errors.append(f"TypeError with args={args}, kwargs={kwargs}: {exc}")
        except Exception as exc:
            errors.append(f"{type(exc).__name__} with args={args}, kwargs={kwargs}: {exc}")
    raise RuntimeError(f"Unable to call {method_name}. Tried variants:\n" + "\n".join(errors))


def configure_uart(uart, tx_pin: int, rx_pin: int, baudrate: int, bits: int, parity: str, stop_bits: int):
    parity_map = {
        "none": 0,
        "odd": 1,
        "even": 2,
    }
    uart.reset()
    uart.txSet(tx_pin)
    uart.rxSet(rx_pin)
    uart.rateSet(float(baudrate))
    uart.bitsSet(bits)
    uart.paritySet(parity_map[parity])
    uart.stopSet(float(stop_bits))


def uart_read(uart, chunk_size: int) -> bytes:
    result = uart.rx(chunk_size)
    if result is None:
        return b""
    if isinstance(result, tuple):
        if len(result) >= 1:
            result = result[0]
        else:
            return b""
    if isinstance(result, bytes):
        return result
    if isinstance(result, bytearray):
        return bytes(result)
    if isinstance(result, str):
        return result.encode("utf-8", errors="replace")
    if isinstance(result, (list, tuple)):
        try:
            return bytes(result)
        except Exception:
            return ("".join(str(item) for item in result)).encode("utf-8", errors="replace")
    return str(result).encode("utf-8", errors="replace")


def uart_write(uart, payload: bytes):
    uart.tx(payload)


def uart_close(uart):
    uart.reset()


def stdin_worker(outgoing: "queue.Queue[bytes]", line_ending: str, stop_event: threading.Event):
    suffix = {
        "none": b"",
        "lf": b"\n",
        "cr": b"\r",
        "crlf": b"\r\n",
    }[line_ending]
    while not stop_event.is_set():
        line = sys.stdin.readline()
        if line == "":
            stop_event.set()
            break
        text = line.rstrip("\r\n")
        outgoing.put(text.encode("utf-8", errors="replace") + suffix)


def monitor(args) -> int:
    log_path = Path(args.log_file).resolve() if args.log_file else None
    outgoing: "queue.Queue[bytes]" = queue.Queue()
    stop_event = threading.Event()
    input_thread = None

    if args.interactive:
        input_thread = threading.Thread(
            target=stdin_worker,
            args=(outgoing, args.line_ending, stop_event),
            daemon=True,
        )
        input_thread.start()

    dwf = DwfLibrary()
    device_enum = dwf.deviceEnum
    count = device_enum.enumerateDevices()
    if count == 0:
        print("No Digilent WaveForms devices found.")
        return 1
    if args.device_index < 0 or args.device_index >= count:
        print(f"Requested device index {args.device_index} is out of range. Available indices: 0..{count - 1}")
        return 1

    with dwf.deviceControl.open(args.device_index) as device:
        uart = device.protocol.uart
        print(f"Opened Digilent device index {args.device_index}")
        print(f"Configuring UART: AD1 TX=DIO{args.tx_pin}, AD1 RX=DIO{args.rx_pin}, baud={args.baudrate}")
        configure_uart(uart, args.tx_pin, args.rx_pin, args.baudrate, args.bits, args.parity, args.stop_bits)
        print("UART ready. Press Ctrl+C to stop.")
        if args.interactive:
            print("Interactive mode enabled. Type lines and press Enter to send them to Pico RX.")

        log_handle = None
        try:
            if log_path is not None:
                log_path.parent.mkdir(parents=True, exist_ok=True)
                log_handle = log_path.open("ab")

            last_rx = time.monotonic()
            while not stop_event.is_set():
                while True:
                    try:
                        payload = outgoing.get_nowait()
                    except queue.Empty:
                        break
                    uart_write(uart, payload)
                    print(f"[TX] {payload!r}")

                incoming = uart_read(uart, args.chunk_size)
                if incoming:
                    last_rx = time.monotonic()
                    sys.stdout.write(incoming.decode("utf-8", errors="replace"))
                    sys.stdout.flush()
                    if log_handle is not None:
                        log_handle.write(incoming)
                        log_handle.flush()
                else:
                    time.sleep(args.poll_interval)
                    if args.timeout > 0 and (time.monotonic() - last_rx) >= args.timeout:
                        print("\nNo UART data received within timeout.")
                        return 2
        except KeyboardInterrupt:
            print("\nStopping UART monitor.")
        finally:
            stop_event.set()
            uart_close(uart)
            if log_handle is not None:
                log_handle.close()
            if input_thread is not None:
                input_thread.join(timeout=0.5)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Monitor Raspberry Pi Pico W UART using a Digilent Analog Discovery device.")
    parser.add_argument("--list", action="store_true", help="List available Digilent devices and exit.")
    parser.add_argument("--device-index", type=int, default=0, help="Digilent device index to open.")
    parser.add_argument("--tx-pin", type=int, default=0, help="Digilent DIO pin used as UART TX toward Pico RX.")
    parser.add_argument("--rx-pin", type=int, default=1, help="Digilent DIO pin used as UART RX from Pico TX.")
    parser.add_argument("--baudrate", type=int, default=115200, help="UART baud rate.")
    parser.add_argument("--bits", type=int, default=8, help="UART data bits.")
    parser.add_argument("--parity", default="none", choices=["none", "even", "odd"], help="UART parity.")
    parser.add_argument("--stop-bits", type=int, default=1, help="UART stop bits.")
    parser.add_argument("--chunk-size", type=int, default=256, help="Read chunk size.")
    parser.add_argument("--poll-interval", type=float, default=0.02, help="Seconds between read polls when idle.")
    parser.add_argument("--timeout", type=float, default=0.0, help="Optional timeout in seconds without RX data. 0 disables timeout.")
    parser.add_argument("--interactive", action="store_true", help="Read stdin and forward typed lines to Pico RX.")
    parser.add_argument("--line-ending", choices=["none", "lf", "cr", "crlf"], default="lf", help="Line ending appended in interactive mode.")
    parser.add_argument("--log-file", help="Optional path to save all received UART data.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.list:
        return list_devices()
    return monitor(args)


if __name__ == "__main__":
    raise SystemExit(main())
