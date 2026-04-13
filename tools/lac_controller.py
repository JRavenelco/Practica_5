"""Actuonix LAC (Linear Actuator Control Board) USB controller.

Communicates with the LAC board using pyusb (libusb backend), which works
natively on 64-bit Python.  Sends/receives 3-byte USB packets:
    [Control, DataLow, DataHigh]

Requirements:
    pip install pyusb libusb-package

Usage:
    from lac_controller import LACController

    lac = LACController()
    lac.open()
    lac.set_position(512)       # 50% stroke
    pos = lac.get_feedback()    # read actual position
    lac.set_speed(1023)         # max speed
    lac.close()

Note on Windows drivers:
    The LAC ships with the Microchip WinUSB driver (mchpwinusb).  If pyusb
    cannot claim the device, use Zadig (https://zadig.akeo.ie/) to switch
    the driver to "WinUSB" or "libusb-win32" for VID 0x04D8 / PID 0xFC5A.
"""

import sys
import time

import usb.core
import usb.util

# Try to use the bundled libusb from libusb-package if available
try:
    import libusb_package
    libusb_package.get_libusb1_backend()   # registers the backend
except ImportError:
    pass

# ── LAC command codes (from datasheet) ──────────────────────────────────
SET_ACCURACY             = 0x01
SET_RETRACT_LIMIT        = 0x02
SET_EXTEND_LIMIT         = 0x03
SET_MOVEMENT_THRESHOLD   = 0x04
SET_STALL_TIME           = 0x05
SET_PWM_THRESHOLD        = 0x06
SET_DERIVATIVE_THRESHOLD = 0x07
SET_DERIVATIVE_MAXIMUM   = 0x08
SET_DERIVATIVE_MINIMUM   = 0x09
SET_PWM_MAXIMUM          = 0x0A
SET_PWM_MINIMUM          = 0x0B
SET_PROPORTIONAL_GAIN    = 0x0C
SET_DERIVATIVE_GAIN      = 0x0D
SET_AVERAGE_RC           = 0x0E
SET_AVERAGE_ADC          = 0x0F
GET_FEEDBACK             = 0x10
SET_POSITION             = 0x20
SET_SPEED                = 0x21
DISABLE_MANUAL           = 0x30
SET_SERIAL_NUM           = 0x50
GET_SERIAL_NUM           = 0x51
RESET_CMD                = 0xFF

# Default Microchip VID and Actuonix LAC PID
DEFAULT_VID = 0x04D8
DEFAULT_PID = 0xFC5F  # LAC board (also seen as 0xFC5A on older firmware)
DEFAULT_TIMEOUT = 1000  # ms


class LACController:
    """Low-level interface to the Actuonix LAC board via USB (pyusb)."""

    def __init__(self, vid=DEFAULT_VID, pid=DEFAULT_PID,
                 timeout_ms=DEFAULT_TIMEOUT):
        self.vid = vid
        self.pid = pid
        self.timeout_ms = timeout_ms
        self._dev = None
        self._ep_out = None
        self._ep_in = None

    # ── Connection ──────────────────────────────────────────────────────
    def open(self):
        """Open USB connection to the LAC."""
        # Try libusb-package backend first, then default
        backend = None
        try:
            import libusb_package
            backend = libusb_package.get_libusb1_backend()
        except (ImportError, Exception):
            pass

        self._dev = usb.core.find(idVendor=self.vid, idProduct=self.pid,
                                  backend=backend)
        if self._dev is None:
            raise ConnectionError(
                f"No LAC device found (VID=0x{self.vid:04X}, PID=0x{self.pid:04X}).\n"
                "Check: USB cable, power, and driver installation.\n"
                "If pyusb cannot claim the device, use Zadig to set the driver\n"
                "to 'WinUSB' for this device."
            )

        # Detach kernel driver if active (Linux)
        try:
            if self._dev.is_kernel_driver_active(0):
                self._dev.detach_kernel_driver(0)
        except (usb.core.USBError, NotImplementedError):
            pass

        # Set default configuration
        try:
            self._dev.set_configuration()
        except usb.core.USBError:
            pass  # May already be configured

        cfg = self._dev.get_active_configuration()
        intf = cfg[(0, 0)]

        # Find bulk or interrupt OUT and IN endpoints
        self._ep_out = usb.util.find_descriptor(
            intf,
            custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)
                                   == usb.util.ENDPOINT_OUT
        )
        self._ep_in = usb.util.find_descriptor(
            intf,
            custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)
                                   == usb.util.ENDPOINT_IN
        )

        if self._ep_out is None or self._ep_in is None:
            raise ConnectionError(
                "LAC device found but could not locate USB endpoints.\n"
                "Try using Zadig to switch the driver to 'WinUSB'."
            )

    def close(self):
        """Release USB device."""
        if self._dev is not None:
            try:
                usb.util.dispose_resources(self._dev)
            except Exception:
                pass
            self._dev = None
            self._ep_out = None
            self._ep_in = None

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *args):
        self.close()

    # ── Raw I/O ─────────────────────────────────────────────────────────
    def _write(self, control, data):
        """Send a 3-byte packet [control, data_low, data_high]."""
        data = int(data) & 0xFFFF
        buf = bytes([control, data & 0xFF, (data >> 8) & 0xFF])
        written = self._ep_out.write(buf, timeout=self.timeout_ms)
        if written != 3:
            raise IOError(f"USB write incomplete: {written}/3 bytes "
                          f"(control=0x{control:02X}, data={data})")

    def _read(self):
        """Read a 3-byte response and return (control, data_uint16)."""
        raw = self._ep_in.read(64, timeout=self.timeout_ms)
        if len(raw) < 3:
            raise IOError(f"USB read incomplete: {len(raw)} bytes")
        control = raw[0]
        data = raw[1] | (raw[2] << 8)
        return control, data

    def _command(self, control, data=0):
        """Send command and read echo.  Returns data from response."""
        self._write(control, data)
        _, resp_data = self._read()
        return resp_data

    # ── High-level API ──────────────────────────────────────────────────
    def set_position(self, value):
        """Set target position (0–1023).  Returns current position."""
        return self._command(SET_POSITION, value)

    def set_position_pct(self, pct):
        """Set target position as percentage (0.0–100.0)."""
        value = int(round(pct / 100.0 * 1023))
        value = max(0, min(1023, value))
        return self.set_position(value)

    def get_feedback(self):
        """Read current actuator position (0–1023)."""
        return self._command(GET_FEEDBACK)

    def get_feedback_pct(self):
        """Read current position as percentage."""
        return self.get_feedback() / 1023.0 * 100.0

    def set_speed(self, value):
        """Set max speed (0–1023)."""
        return self._command(SET_SPEED, value)

    def set_accuracy(self, value):
        """Set accuracy / dead-band (0–1023, default 4)."""
        return self._command(SET_ACCURACY, value)

    def set_retract_limit(self, value):
        """Set retract limit (0–1023, default 0)."""
        return self._command(SET_RETRACT_LIMIT, value)

    def set_extend_limit(self, value):
        """Set extend limit (0–1023, default 1023)."""
        return self._command(SET_EXTEND_LIMIT, value)

    def set_proportional_gain(self, value):
        """Set Kp (0–1023)."""
        return self._command(SET_PROPORTIONAL_GAIN, value)

    def set_derivative_gain(self, value):
        """Set Kd (0–1023)."""
        return self._command(SET_DERIVATIVE_GAIN, value)

    def set_stall_time(self, ms):
        """Set stall timeout in ms (0–65535)."""
        return self._command(SET_STALL_TIME, ms)

    def disable_manual(self):
        """Save settings to EEPROM and disable potentiometers."""
        return self._command(DISABLE_MANUAL)

    def reset(self):
        """Reset to factory defaults and re-enable potentiometers."""
        return self._command(RESET_CMD)

    def position_mm(self, pos_raw, stroke_mm):
        """Convert raw position (0–1023) to mm."""
        return pos_raw / 1023.0 * stroke_mm

    @staticmethod
    def mm_to_raw(mm, stroke_mm):
        """Convert mm to raw position value (0–1023)."""
        return int(round(mm / stroke_mm * 1023))
