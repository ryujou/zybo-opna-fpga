#include "midi_synth.h"
#include "opnmidi.h"
#include "opnmidi_midiplay.hpp"
#include <cstdio>
#include "bank_data.h"

namespace {
OPN2_MIDIPlayer *player = nullptr;
char init_error[160] = {};
}

bool midi_synth_init() {
    player = opn2_init(48000);
    if (!player) {
        std::snprintf(init_error, sizeof(init_error), "%s", opn2_errorString());
        return false;
    }
    if (opn2_setNumChips(player, 1) != 0 || opn2_openBankData(player, bank_data, sizeof(bank_data)) != 0) {
        std::snprintf(init_error, sizeof(init_error), "%s", opn2_errorInfo(player));
        midi_synth_close();
        return false;
    }
    opn2_setChipType(player, OPNMIDI_ChipType_OPNA);
    opn2_setVolumeRangeModel(player, 0);
    opn2_setSoftPanEnabled(player, 0);
    midi_synth_reset();
    return true;
}

const char *midi_synth_error() { return init_error; }

void midi_synth_close() {
    opn2_close(player);
    player = nullptr;
}

void midi_synth_reset() {
    opn2_panic(player);
    opn2_rt_resetState(player);
    const uint8_t gm_reset[] = {0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7};
    opn2_rt_systemExclusive(player, gm_reset, sizeof(gm_reset));
}

void midi_synth_tick(uint32_t elapsed_us) {
    static_cast<OPNMIDIplay *>(player->opn2_midiPlayer)->TickIterators(elapsed_us / 1000000.0);
}

void midi_synth_message(const uint8_t *data, size_t size) {
    const unsigned channel = data[0] & 15;
    (void)size; // MIDI packet parser has already checked each message length.
    switch (data[0] & 0xF0) {
    case 0x80: opn2_rt_noteOff(player, channel, data[1]); break;
    case 0x90:
        if (data[2]) opn2_rt_noteOn(player, channel, data[1], data[2]);
        else opn2_rt_noteOff(player, channel, data[1]);
        break;
    case 0xA0: opn2_rt_noteAfterTouch(player, channel, data[1], data[2]); break;
    case 0xB0: opn2_rt_controllerChange(player, channel, data[1], data[2]); break;
    case 0xC0: opn2_rt_patchChange(player, channel, data[1]); break;
    case 0xD0: opn2_rt_channelAfterTouch(player, channel, data[1]); break;
    case 0xE0: opn2_rt_pitchBend(player, channel, data[1] | (data[2] << 7)); break;
    default:
        if (data[0] == 0xFF) midi_synth_reset();
        break;
    }
}

void midi_synth_sysex(const uint8_t *data, size_t size) {
    opn2_rt_systemExclusive(player, data, size);
}

