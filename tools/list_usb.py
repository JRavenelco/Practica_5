"""List all USB devices visible to libusb."""
import usb.core
import usb.util
try:
    import libusb_package
    backend = libusb_package.get_libusb1_backend()
except Exception:
    backend = None

devs = list(usb.core.find(find_all=True, backend=backend))
print(f"{len(devs)} USB device(s) found:")
for d in devs:
    try:
        prod = usb.util.get_string(d, d.iProduct) if d.iProduct else ""
    except Exception:
        prod = ""
    try:
        mfr = usb.util.get_string(d, d.iManufacturer) if d.iManufacturer else ""
    except Exception:
        mfr = ""
    print(f"  VID=0x{d.idVendor:04X}  PID=0x{d.idProduct:04X}  {mfr} / {prod}")
