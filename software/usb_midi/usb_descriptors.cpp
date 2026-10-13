#include "usb_descriptors.h"

const uint8_t midi_device_descriptor[18] = {
    18, 1, 0x00, 0x02, 0, 0, 0, 64,
    0xFE, 0xCA, 0x14, 0x40, 0x00, 0x01, 1, 2, 3, 1
};

const uint8_t midi_config_descriptor[101] = {
    9, 2, 101, 0, 2, 1, 0, 0xC0, 0,
    9, 4, 0, 0, 0, 1, 1, 0, 0,                 // AudioControl
    9, 0x24, 1, 0x00, 0x01, 9, 0, 1, 1,
    9, 4, 1, 0, 2, 1, 3, 0, 2,                 // MIDIStreaming
    7, 0x24, 1, 0x00, 0x01, 65, 0,
    6, 0x24, 2, 1, 1, 0,                       // Embedded IN jack 1
    6, 0x24, 2, 2, 2, 0,                       // External IN jack 2
    9, 0x24, 3, 1, 3, 1, 2, 1, 0,              // Embedded OUT jack 3
    9, 0x24, 3, 2, 4, 1, 1, 1, 0,              // External OUT jack 4
    9, 5, 0x01, 2, 64, 0, 0, 0, 0,
    5, 0x25, 1, 1, 1,
    9, 5, 0x81, 2, 64, 0, 0, 0, 0,
    5, 0x25, 1, 1, 3
};

size_t midi_string_descriptor(uint8_t index, uint8_t *output) {
    if (index == 0) {
        output[0] = 4; output[1] = 3; output[2] = 9; output[3] = 4;
        return 4;
    }
    static const char *strings[] = {"", "Ryujou", "Zybo OPNA MIDI", "ZOPNAMIDI0001"};
    if (index >= 4) return 0;
    size_t n = 2;
    for (const char *p = strings[index]; *p; ++p) {
        output[n++] = static_cast<uint8_t>(*p);
        output[n++] = 0;
    }
    output[0] = static_cast<uint8_t>(n);
    output[1] = 3;
    return n;
}
