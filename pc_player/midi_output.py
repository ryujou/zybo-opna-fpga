"""WinMM MIDI output; SysEx storage stays alive until MHDR_DONE."""
import ctypes as C


GM_NAMES = (
    "Acoustic Grand Piano|Bright Acoustic Piano|Electric Grand Piano|Honky-tonk Piano|Electric Piano 1|Electric Piano 2|Harpsichord|Clavinet|"
    "Celesta|Glockenspiel|Music Box|Vibraphone|Marimba|Xylophone|Tubular Bells|Dulcimer|"
    "Drawbar Organ|Percussive Organ|Rock Organ|Church Organ|Reed Organ|Accordion|Harmonica|Tango Accordion|"
    "Acoustic Guitar (nylon)|Acoustic Guitar (steel)|Electric Guitar (jazz)|Electric Guitar (clean)|Electric Guitar (muted)|Overdriven Guitar|Distortion Guitar|Guitar Harmonics|"
    "Acoustic Bass|Electric Bass (finger)|Electric Bass (pick)|Fretless Bass|Slap Bass 1|Slap Bass 2|Synth Bass 1|Synth Bass 2|"
    "Violin|Viola|Cello|Contrabass|Tremolo Strings|Pizzicato Strings|Orchestral Harp|Timpani|"
    "String Ensemble 1|String Ensemble 2|Synth Strings 1|Synth Strings 2|Choir Aahs|Voice Oohs|Synth Voice|Orchestra Hit|"
    "Trumpet|Trombone|Tuba|Muted Trumpet|French Horn|Brass Section|Synth Brass 1|Synth Brass 2|"
    "Soprano Sax|Alto Sax|Tenor Sax|Baritone Sax|Oboe|English Horn|Bassoon|Clarinet|"
    "Piccolo|Flute|Recorder|Pan Flute|Blown Bottle|Shakuhachi|Whistle|Ocarina|"
    "Lead 1 (square)|Lead 2 (sawtooth)|Lead 3 (calliope)|Lead 4 (chiff)|Lead 5 (charang)|Lead 6 (voice)|Lead 7 (fifths)|Lead 8 (bass + lead)|"
    "Pad 1 (new age)|Pad 2 (warm)|Pad 3 (polysynth)|Pad 4 (choir)|Pad 5 (bowed)|Pad 6 (metallic)|Pad 7 (halo)|Pad 8 (sweep)|"
    "FX 1 (rain)|FX 2 (soundtrack)|FX 3 (crystal)|FX 4 (atmosphere)|FX 5 (brightness)|FX 6 (goblins)|FX 7 (echoes)|FX 8 (sci-fi)|"
    "Sitar|Banjo|Shamisen|Koto|Kalimba|Bag Pipe|Fiddle|Shanai|"
    "Tinkle Bell|Agogo|Steel Drums|Woodblock|Taiko Drum|Melodic Tom|Synth Drum|Reverse Cymbal|"
    "Guitar Fret Noise|Breath Noise|Seashore|Bird Tweet|Telephone Ring|Helicopter|Applause|Gunshot"
).split("|")


class Caps(C.Structure):
    _fields_ = [("manufacturer", C.c_ushort), ("product", C.c_ushort),
                ("version", C.c_uint32), ("name", C.c_wchar * 32),
                ("technology", C.c_ushort), ("voices", C.c_ushort),
                ("notes", C.c_ushort), ("channels", C.c_ushort), ("support", C.c_uint32)]


class Header(C.Structure):
    _pack_ = 1
    _fields_ = [("data", C.c_void_p), ("length", C.c_uint32), ("recorded", C.c_uint32),
                ("user", C.c_size_t), ("flags", C.c_uint32), ("next", C.c_void_p),
                ("reserved", C.c_size_t), ("offset", C.c_uint32), ("reserved8", C.c_size_t * 8)]


api = C.WinDLL("winmm")
for name, args in {
    "midiOutGetNumDevs": [],
    "midiOutGetDevCapsW": [C.c_size_t, C.POINTER(Caps), C.c_uint],
    "midiOutOpen": [C.POINTER(C.c_void_p), C.c_uint, C.c_size_t, C.c_size_t, C.c_uint32],
    "midiOutShortMsg": [C.c_void_p, C.c_uint32],
    "midiOutReset": [C.c_void_p], "midiOutClose": [C.c_void_p],
    "midiOutPrepareHeader": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutLongMsg": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutUnprepareHeader": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutGetErrorTextW": [C.c_uint, C.c_wchar_p, C.c_uint],
}.items():
    getattr(api, name).argtypes = args
    getattr(api, name).restype = C.c_uint


def check(result):
    if result:
        text = C.create_unicode_buffer(256)
        api.midiOutGetErrorTextW(result, text, len(text))
        raise OSError(f"MIDI: {text.value} ({result})")


def outputs():
    result = []
    for index in range(api.midiOutGetNumDevs()):
        caps = Caps()
        check(api.midiOutGetDevCapsW(index, C.byref(caps), C.sizeof(caps)))
        if caps.name.startswith("Zybo OPL3 MIDI"):
            result.append({"id": str(index), "name": caps.name, "mode": "midi"})
    return result


class MidiOutput:
    def __init__(self, index):
        self.handle = C.c_void_p()
        self.pending = []
        check(api.midiOutOpen(C.byref(self.handle), int(index), 0, 0, 0))

    def reap(self):
        remaining = []
        for buffer, header in self.pending:
            if header.flags & 1:
                check(api.midiOutUnprepareHeader(self.handle, C.byref(header), C.sizeof(header)))
            else:
                remaining.append((buffer, header))
        self.pending = remaining

    def send(self, data):
        self.reap()
        if data[0] == 0xf0:
            buffer = C.create_string_buffer(bytes(data))
            header = Header(data=C.addressof(buffer), length=len(data))
            check(api.midiOutPrepareHeader(self.handle, C.byref(header), C.sizeof(header)))
            self.pending.append((buffer, header))
            check(api.midiOutLongMsg(self.handle, C.byref(header), C.sizeof(header)))
        else:
            check(api.midiOutShortMsg(self.handle, sum(byte << (8 * i) for i, byte in enumerate(data))))

    def silence(self):
        check(api.midiOutReset(self.handle))
        self.reap()

    def close(self):
        if self.handle:
            self.silence()
            check(api.midiOutClose(self.handle))
            self.handle = None
