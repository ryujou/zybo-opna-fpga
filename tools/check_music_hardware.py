"""Play a complete PMD/VGM and capture actual SSG, PCM and I2S windows over JTAG."""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import time
import play_pc98 as player

ROOT = Path(__file__).resolve().parents[1]
USB_DLL = Path('J:/lumia/FPGA/OPL3/opl3_host/.venv/Lib/site-packages/libusb/_platform/windows/x86_64/libusb-1.0.dll')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('song', type=Path)
    parser.add_argument('out', type=Path)
    parser.add_argument('--seconds', type=float)
    parser.add_argument('--windows', type=int, nargs='+', default=[5, 15, 30, 45, 60, 70])
    parser.add_argument('--clip-trigger', action='store_true')
    parser.add_argument('--bus-trace', action='store_true')
    parser.add_argument('--ltx', type=Path, default=ROOT / 'firmware/usb_dual/zybo_opna.ltx')
    parser.add_argument('--mix-via-jtag', action='store_true', help='diagnostic gain setup before validating USB SET_MIX')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for marker in ('ready', 'start'):
        (out / marker).unlink(missing_ok=True)
    music, gains = player.load_music_with_mix(args.song, args.seconds)
    events, memory, duration, counts, clock = music
    if min(args.windows) < 0 or max(args.windows) + 2 >= duration:
        raise ValueError('Capture windows must end before playback finishes')
    (out / 'events.bin').write_bytes(events)
    (out / 'memory.bin').write_bytes(memory)
    backend = player.usb.usb.backend.libusb1.get_backend(find_library=lambda _: str(USB_DLL))
    device = player.usb.usb.core.find(idVendor=0xcafe, idProduct=0x4012, backend=backend)
    if device is None or device.serial_number != 'ZOPNAUSB0001':
        raise RuntimeError('Expected Zybo OPNA bulk device')
    incoming = bytearray()
    request = lambda kind, data=b'': player.usb.request(device, incoming, kind, data)
    with (out / 'capture-console.log').open('w', encoding='utf-8') as log:
        capture = subprocess.Popen([
            'J:/FPGA/2025.2/Vivado/bin/vivado.bat', '-mode', 'batch', '-source',
            str(ROOT / 'scripts/music_capture.tcl'), '-log', str(out / 'capture.log'),
            '-journal', str(out / 'capture.jou'), '-tclargs',
            str(args.ltx.resolve()), str(out),
            'clip' if args.clip_trigger else 'bus' if args.bus_trace else 'windows',
            *map(str, args.windows)], stdout=log, stderr=subprocess.STDOUT)
        try:
            player.usb.usb.util.claim_interface(device, 0)
            hello = request(1)
            if len(hello) != 24 or hello[:2] != player.vgm_mix.PROTOCOL:
                raise RuntimeError('Expected OPNA protocol 2.2')
            request(2)
            request(5)
            if args.mix_via_jtag:
                with (out/'jtag-mix.log').open('w',encoding='utf-8') as mix_log:
                    subprocess.run(['J:/FPGA/2025.2/Vitis/bin/xsct.bat',str(ROOT/'scripts/mix_jtag.tcl'),
                                    *map(str,gains)],check=True,stdout=mix_log,stderr=subprocess.STDOUT)
                if 'JTAG_MIX_COMPLETE' not in (out/'jtag-mix.log').read_text(encoding='utf-8'):
                    raise RuntimeError('JTAG gain setup failed')
            else:
                player.vgm_mix.set_mix(player.usb,device,incoming,gains)
            if memory:
                player.usb.upload_samples(device, incoming, memory, 0, 1024)
                if player.usb.read_samples(device, incoming, len(memory), 1024) != memory:
                    raise RuntimeError('Uploaded ADPCM sample RAM differs from source')
            request(8, struct.pack('<I', len(events)))
            for offset in range(0, len(events), 1024):
                request(9, events[offset:offset + 1024])
            request(10)
            deadline = time.monotonic() + 90
            while not (out / 'ready').exists():
                if capture.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('ILA setup failed; inspect capture.log')
                time.sleep(.1)
            started = time.time()
            player.usb.play_with_pending_in(device, incoming)
            (out / 'start').write_text(str(round(started * 1000)), encoding='utf-8')
            print(f'PLAYING {args.song} ({duration:.3f}s)', flush=True)
            while time.time() - started < duration + .2:
                if capture.poll() is not None and capture.returncode:
                    raise RuntimeError('ILA capture failed')
                time.sleep(.2)
            state = player.usb.status(device, incoming)
            player.stop_device(device, incoming)
            if capture.wait(timeout=30) or 'MUSIC_CAPTURE_COMPLETE' not in (out / 'capture.log').read_text(encoding='utf-8'):
                raise RuntimeError('ILA capture incomplete')
            result = dict(song=str(args.song.resolve()), duration=duration, source_clock=clock,
                          board_clock=8000000, writes=counts, playback_status=state,
                          windows_seconds=[] if args.clip_trigger else args.windows,
                          clip_trigger=args.clip_trigger, analog_recording=False)
            result['gains_q16'] = list(gains)
            result['mix_transport'] = 'JTAG' if args.mix_via_jtag else 'USB'
            result['passed'] = not (state['flags'] or state['queued_writes'] or state['clip_left'] or state['clip_right'] or state['hardware_status'] & 8)
            result['bus_trace'] = args.bus_trace
            result['sample_verified_bytes'] = len(memory)
            (out / 'playback.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
            print(json.dumps(result), flush=True)
        finally:
            player.stop_device(device, incoming)
            player.usb.usb.util.dispose_resources(device)
            if capture.poll() is None:
                capture.terminate()


if __name__ == '__main__':
    main()
