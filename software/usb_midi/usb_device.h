#pragma once
#include <cstdint>

struct MidiUsbEvent {
    uint8_t data[4];
    uint32_t received_us;
};

struct MidiUsbStats {
    uint32_t received;
    uint32_t overflow;
    uint32_t malformed;
    uint32_t resets;
    uint32_t control_errors;
};

int midi_usb_init();
void midi_usb_close();
bool midi_usb_pop(MidiUsbEvent &event);
bool midi_usb_take_reset();
MidiUsbStats midi_usb_stats();
