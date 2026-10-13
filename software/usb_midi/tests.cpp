#include "midi_parser.h"
#include "midi_synth.h"
#include "usb_descriptors.h"
#include "opnmidi.h"
#include "opnmidi_midiplay.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

extern unsigned key_mask;
struct Write { uint16_t address; uint8_t value; };
std::vector<Write> writes;
std::vector<std::vector<uint8_t>> messages, sysex_messages;
bool synth_enabled = false;
uint8_t registers[512] = {};

void midi_opl_write(uint16_t address, uint8_t value) {
    assert(address < 512);
    registers[address] = value;
    if (address == 0x28) {
        const unsigned ch = (value & 3) + ((value & 4) ? 3 : 0);
        assert(ch < 6);
        if (value & 0xF0) key_mask |= 1U << ch; else key_mask &= ~(1U << ch);
    }
    writes.push_back({address, value});
}
void midi_message_received(const uint8_t *data, size_t size) {
    messages.emplace_back(data, data + size);
    if (synth_enabled) midi_synth_message(data, size);
}
void midi_sysex_received(const uint8_t *data, size_t size) {
    sysex_messages.emplace_back(data, data + size);
    if (synth_enabled) midi_synth_sysex(data, size);
}
void packet(MidiParser &p, uint8_t cin, uint8_t a, uint8_t b = 0, uint8_t c = 0) {
    const uint8_t bytes[] = {cin, a, b, c};
    p.accept(bytes);
}
unsigned key_mask = 0;
unsigned keys_on() { unsigned n=0; for(unsigned m=key_mask;m;m>>=1) n+=m&1; return n; }

void test_descriptors() {
    assert(midi_device_descriptor[0] == 18 && midi_device_descriptor[7] == 64);
    assert(midi_device_descriptor[10] == 0x14 && midi_device_descriptor[11] == 0x40);
    const auto *d = midi_config_descriptor;
    assert((d[2] | d[3] << 8) == sizeof(midi_config_descriptor));
    unsigned interfaces = 0, endpoints = 0, jack_mask = 0;
    unsigned interface_no = 0, last_endpoint = 0;
    for (size_t i = 0; i < sizeof(midi_config_descriptor); i += d[i]) {
        assert(d[i] >= 2 && i + d[i] <= sizeof(midi_config_descriptor));
        if (d[i + 1] == 4) {
            ++interfaces;
            interface_no = d[i + 2];
            assert(d[i + 5] == 1);
            assert(d[i + 6] == (interface_no == 0 ? 1 : 3));
        } else if (d[i + 1] == 0x24 && interface_no == 1 && d[i + 2] >= 2) {
            jack_mask |= 1U << d[i + 4];
            if (d[i + 2] == 3) assert(d[i + 6] == (d[i + 4] == 3 ? 2 : 1));
        } else if (d[i + 1] == 5) {
            ++endpoints; last_endpoint = d[i + 2];
            assert(d[i + 3] == 2 && d[i + 4] == 64 && d[i + 5] == 0);
        } else if (d[i + 1] == 0x25) {
            assert(d[i + 3] == 1 && (jack_mask & (1U << d[i + 4])));
            assert(d[i + 4] == (last_endpoint == 1 ? 1 : 3));
        }
    }
    assert(interfaces == 2 && endpoints == 2 && jack_mask == 0x1E);
    uint8_t text[128];
    assert(midi_string_descriptor(0, text) == 4);
    assert(midi_string_descriptor(2, text) == 30);
    assert(midi_string_descriptor(0xEE, text) == 0);
    std::puts("PASS descriptors: AC/MS topology, endpoint/jack links, strings, no WCID");
}

void test_parser() {
    MidiParser p;
    packet(p, 9, 0x90, 60, 100);
    packet(p, 0xC, 0xC0, 12);
    packet(p, 0xE, 0xE0, 0, 64);
    assert(messages.size() == 3 && messages[1].size() == 2);
    packet(p, 0x19, 0x90, 60, 1); // Unsupported cable
    packet(p, 9, 0x80, 60, 1); // CIN/status mismatch
    packet(p, 9, 0x90, 0xFF, 1);
    assert(messages.size() == 3 && p.invalid_packets == 3);
    packet(p, 4, 0xF0, 0x7E, 0x7F);
    packet(p, 0xF, 0xF8); // Realtime message does not interrupt SysEx
    packet(p, 7, 9, 1, 0xF7);
    assert(sysex_messages.size() == 1 && sysex_messages[0].size() == 6);
    packet(p, 4, 0xF0, 1, 2);
    for (int i = 0; i < 350; ++i) packet(p, 4, 1, 2, 3);
    packet(p, 5, 0xF7);
    assert(p.oversized_sysex == 1 && sysex_messages.size() == 1);
    packet(p, 6, 0xF0, 0xF7);
    assert(sysex_messages.size() == 2);
    packet(p, 4, 0xF0, 1, 2);
    p.reset();
    packet(p, 5, 0xF7);
    assert(sysex_messages.size() == 2);
    packet(p, 4, 0xF0, 1, 2);
    packet(p, 0xF, 0xFF);
    packet(p, 5, 0xF7);
    assert(sysex_messages.size() == 2);
    packet(p, 4, 0xF0, 1, 2);
    packet(p, 7, 3, 0x90, 0xF7);
    packet(p, 6, 0xF0, 0xF7);
    assert(sysex_messages.size() == 3);
    const uint8_t transfer[] = {9, 0x90, 64, 90, 8, 0x80, 64, 0};
    const size_t before = messages.size();
    for (size_t i = 0; i < sizeof(transfer); i += 4) p.accept(transfer + i);
    assert(messages.size() == before + 2);
    const size_t raw_before = messages.size();
    for (const uint8_t byte : {0x90, 60, 100, 61, 0, 0xF8, 0xC0, 12}) packet(p, 0xF, byte);
    assert(messages.size() == raw_before + 4);
    assert(messages[raw_before + 1] == std::vector<uint8_t>({0x90, 61, 0}));
    for (const uint8_t byte : {0xF0, 0x7E, 0x7F, 9, 1, 0xF7}) packet(p, 0xF, byte);
    assert(sysex_messages.back() == std::vector<uint8_t>({0xF0, 0x7E, 0x7F, 9, 1, 0xF7}));
    std::puts("PASS MIDI parser: messages, cable/CIN validation, multi-event transfers, fragmented/oversized SysEx");
}

void send(uint8_t a, uint8_t b=0, uint8_t c=0) { const uint8_t m[]={a,b,c}; midi_synth_message(m,3); }
int main() {
    test_descriptors(); test_parser();
    assert(midi_synth_init());
    assert(registers[0x29] == 0x80);
    for (unsigned p=0; p<128; ++p) {
        send(0xC0,p); send(0x90,69,100); if(!keys_on()) { std::printf("silent program %u\n",p); std::fflush(stdout); } assert(keys_on()>0);
        send(0xB0,120,0); assert(keys_on()==0);
    }
    send(0xC0,80);
    for(unsigned n=60;n<66;++n) send(0x90,n,100);
    assert(keys_on()==6);
    send(0xB0,120,0); assert(keys_on()==0);
    send(0x90,69,100);
    unsigned ch=0; while(!(key_mask & (1<<ch))) ++ch;
    unsigned bank=ch/3*256, index=ch%3;
    unsigned high=registers[bank+0xA4+index], low=registers[bank+0xA0+index];
    double frequency=((high & 7)*256+low)*8000000.0/(144.0*2097152.0)*(1U << ((high>>3)&7));
    std::printf("frequency=%.3f high=%u low=%u\n",frequency,high,low); std::fflush(stdout); assert(frequency>438 && frequency<442);
    send(0xB0,64,127); send(0x80,69); assert(keys_on()>0);
    send(0xB0,64,0); assert(keys_on()==0);
    send(0x90,69,100); send(0xE0,127,127);
    assert(registers[bank+0xA0+index]!=low || registers[bank+0xA4+index]!=high);
    send(0xB0,10,0); assert((registers[bank+0xB4+index]&0xC0)==0x80);
    send(0xB0,10,127); assert((registers[bank+0xB4+index]&0xC0)==0x40);
    midi_synth_reset(); assert(keys_on()==0);
    send(0x99,36,100); assert(keys_on()>0);
    midi_synth_reset(); assert(keys_on()==0);
    midi_synth_close();
    std::printf("PASS OPNA: 128 GM programs, six voices, A4 %.3f Hz, sustain, bend, stereo, percussion, reset\n", frequency);
}
