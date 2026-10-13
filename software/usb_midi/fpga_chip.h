#pragma once
#include "chips/opn_chip_base.h"

void midi_opl_write(uint16_t address, uint8_t value);

class FpgaOPNA final : public OPNChipBaseT<FpgaOPNA> {
public:
    explicit FpgaOPNA(OPNFamily) : OPNChipBaseT(OPNChip_OPNA) {}
    bool canRunAtPcmRate() const override { return true; }
    bool hasFullPanning() override { return false; }
    void nativePreGenerate() override {}
    void nativePostGenerate() override {}
    void nativeGenerate(int16_t *frame) override { frame[0] = frame[1] = 0; }
    void writeReg(uint32_t port, uint16_t address, uint8_t value) override {
        midi_opl_write((port << 8) | address, value);
        // OPNA requires SCH to enable FM channels 4-6; OPN2 has no such gate.
        if (port == 0 && address == 0x27) midi_opl_write(0x29, 0x80);
    }
    const char *emulatorName() override { return "Zybo OPNA FPGA"; }
};
