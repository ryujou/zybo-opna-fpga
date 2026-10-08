#include "midi_parser.h"

void MidiParser::reset() {
    sysex_size = 0;
    in_sysex = false;
    discard_sysex = false;
    raw_size = raw_length = 0;
}

void MidiParser::accept_byte(uint8_t value) {
    if (value >= 0xF8) {
        if (value == 0xFF) reset();
        midi_message_received(&value, 1);
        return;
    }
    if (in_sysex) {
        if (discard_sysex) {
            if (value == 0xF7) reset();
            return;
        }
        if (value < 0x80 || value == 0xF7) {
            if (sysex_size == sizeof(sysex)) {
                ++oversized_sysex;
                discard_sysex = true;
            } else sysex[sysex_size++] = value;
            if (value == 0xF7) {
                if (!discard_sysex) midi_sysex_received(sysex, sysex_size);
                reset();
            }
            return;
        }
        ++invalid_packets;
        reset();
    }
    if (value >= 0x80) {
        reset();
        if (value == 0xF0) {
            in_sysex = true;
            sysex[sysex_size++] = value;
        } else if (value == 0xF6) midi_message_received(&value, 1);
        else if (value < 0xF0 || value == 0xF1 || value == 0xF2 || value == 0xF3) {
            raw[0] = value;
            raw_size = 1;
            raw_length = ((value & 0xE0) == 0xC0 || value == 0xF1 || value == 0xF3) ? 2 : 3;
        } else ++invalid_packets;
        return;
    }
    if (!raw_length) { ++invalid_packets; return; }
    raw[raw_size++] = value;
    if (raw_size == raw_length) {
        midi_message_received(raw, raw_length);
        if (raw[0] < 0xF0) raw_size = 1; // MIDI running status in CIN 0xF streams.
        else raw_size = raw_length = 0;
    }
}

void MidiParser::accept(const uint8_t packet[4]) {
    const uint8_t cin = packet[0] & 15;
    const uint8_t *data = packet + 1;
    if ((packet[0] >> 4) != 0) { ++invalid_packets; return; }

    if (cin == 0xF) {
        accept_byte(data[0]);
        return;
    }
    if (cin >= 4 && cin <= 7 && !(cin == 5 && data[0] == 0xF6)) {
        const size_t size = cin == 4 ? 3 : cin - 4;
        const bool ends = cin != 4;
        if (data[0] == 0xF0 && !discard_sysex) {
            reset();
            in_sysex = true;
        }
        if (!in_sysex || (ends && data[size - 1] != 0xF7)) {
            ++invalid_packets;
            reset();
            return;
        }
        for (size_t i = 0; i < size; ++i) {
            const bool boundary = (i == 0 && data[i] == 0xF0) ||
                                  (ends && i == size - 1 && data[i] == 0xF7);
            if (data[i] >= 0x80 && !boundary) {
                ++invalid_packets;
                reset();
                return;
            }
        }
        if (!discard_sysex && sysex_size + size > sizeof(sysex)) {
            discard_sysex = true;
            ++oversized_sysex;
        }
        if (!discard_sysex) {
            for (size_t i = 0; i < size; ++i) sysex[sysex_size++] = data[i];
        }
        if (ends) {
            if (!discard_sysex) midi_sysex_received(sysex, sysex_size);
            reset();
        }
        return;
    }

    static const uint8_t sizes[16] = {0, 0, 2, 3, 3, 1, 2, 3, 3, 3, 3, 3, 2, 2, 3, 1};
    const size_t size = sizes[cin];
    bool valid = cin >= 8 && cin <= 14 && (data[0] >> 4) == cin;
    valid |= cin == 2 && (data[0] == 0xF1 || data[0] == 0xF3);
    valid |= cin == 3 && data[0] == 0xF2;
    valid |= cin == 5 && data[0] == 0xF6;
    for (size_t i = 1; i < size; ++i) valid &= data[i] < 0x80;
    if (!valid) { ++invalid_packets; return; }
    reset(); // A non-realtime message terminates an incomplete SysEx.
    midi_message_received(data, size);
    if (cin >= 8 && cin <= 14) {
        raw[0] = data[0]; raw_size = 1; raw_length = size;
    }
}
