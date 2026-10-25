"""Exercise the same empty USB CD and QMP insertion used by Windows exchange."""
import json
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

qemu = shutil.which("qemu-system-aarch64")
assert qemu, "QEMU is required"
with tempfile.TemporaryDirectory(prefix="og-cd-", dir="/tmp") as temporary:
    root = pathlib.Path(temporary)
    image = root / "exchange.iso"
    other = root / "other.iso"
    image.write_bytes(bytes(4096))
    other.write_bytes(bytes(8192))
    endpoint = root / "qmp.sock"
    args = [qemu, "-machine", "virt", "-cpu", "cortex-a57", "-accel", "tcg", "-m", "128", "-S", "-display", "none", "-nodefaults",
            "-qmp", "unix:"+str(endpoint)+",server=on,wait=off", "-device", "qemu-xhci,id=usb",
            "-drive", "if=none,id=stratovo-exchange,media=cdrom,readonly=on",
            "-device", "usb-bot,id=stratovo-exchange-usb,bus=usb.0",
            "-device", "scsi-cd,id=stratovo-exchange-cd,drive=stratovo-exchange,bus=stratovo-exchange-usb.0,scsi-id=0,lun=0",
            "-drive", "if=none,id=drivers,media=cdrom,readonly=on,file="+str(other),
            "-device", "usb-bot,id=drivers-usb,bus=usb.0", "-device", "scsi-cd,id=drivers-cd,drive=drivers,bus=drivers-usb.0,scsi-id=0,lun=0"]
    with (root / "qemu.log").open("w+") as log:
        process = subprocess.Popen(args, stdout=log, stderr=log)
        try:
            for _ in range(200):
                if endpoint.exists(): break
                if process.poll() is not None:
                    log.seek(0); raise AssertionError(log.read())
                time.sleep(.025)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(endpoint))
                channel = connection.makefile("rwb", buffering=0)
                json.loads(channel.readline())
                def command(name, arguments=None):
                    request={"execute":name,"id":1}
                    if arguments is not None: request["arguments"]=arguments
                    channel.write(json.dumps(request).encode()+b"\n")
                    while True:
                        response=json.loads(channel.readline())
                        if response.get("id")==1:
                            assert "error" not in response,response
                            return response["return"]
                command("qmp_capabilities")
                command("blockdev-change-medium", {"id":"stratovo-exchange-cd","filename":str(image),"format":"raw","read-only-mode":"read-only"})
                blocks=command("query-block")
                inserted={pathlib.Path(entry["inserted"]["file"]).name:entry["inserted"] for entry in blocks if "inserted" in entry}
                assert inserted["exchange.iso"]["ro"] is True,blocks
                assert inserted["other.iso"]["ro"] is True,blocks
                command("quit")
                process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
print("Read-only exchange CD inserted successfully; existing driver CD preserved.")
