#pragma once
#include <cstddef>
#include <cstdint>

struct MidiParser {
    uint8_t sysex[1024] = {};
    size_t sysex_size = 0;
    bool in_sysex = false;
    bool discard_sysex = false;
    uint32_t invalid_packets = 0;
    uint32_t oversized_sysex = 0;
    void reset();
    void accept(const uint8_t packet[4]);
private:
    uint8_t raw[3] = {};
    uint8_t raw_size = 0, raw_length = 0;
    void accept_byte(uint8_t value);
};

// These two sinks are supplied by the application or the protocol test.
void midi_message_received(const uint8_t *data, size_t size);
void midi_sysex_received(const uint8_t *data, size_t size);
