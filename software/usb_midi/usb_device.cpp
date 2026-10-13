#include "usb_device.h"
#include "usb_descriptors.h"
#include <cstring>
#include "xusbps.h"
#include "xusbps_endpoint.h"
#include "xusbps_hw.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "xtime_l.h"
#include "sleep.h"
#include "xgpiops.h"

extern "C" {
volatile uint32_t midi_usb_setup_count = 0;
volatile uint32_t midi_usb_ep0_tx_count = 0;
volatile uint32_t midi_usb_send_errors = 0;
}

namespace {
XUsbPs usb;
XScuGic gic;
alignas(32) uint8_t dma_memory[64 * 1024];
alignas(32) uint8_t reply[128];
MidiUsbEvent queue[1024];
volatile unsigned head = 0, tail = 0;
volatile bool reset_pending = false;
volatile uint8_t configured = 0;
volatile uint32_t received = 0, overflows = 0, malformed = 0, resets = 0;

uint32_t irq_lock() {
    uint32_t cpsr;
    asm volatile("mrs %0, cpsr\n\tcpsid i" : "=r"(cpsr) :: "memory");
    return cpsr;
}
void irq_unlock(uint32_t cpsr) {
    asm volatile("msr cpsr_c, %0" :: "r"(cpsr) : "memory");
}
void request_reset() {
    reset_pending = true;
    ++resets;
}
bool reset_endpoint(unsigned ep, uint8_t direction) {
    const uint32_t mask = 1U << (ep + (direction == XUSBPS_EP_DIRECTION_IN ? 16 : 0));
    XUsbPs_EpDisable(&usb, ep, direction);
    XUsbPs_EpFlush(&usb, ep, direction);
    unsigned timeout = 1000000;
    while ((XUsbPs_ReadReg(usb.Config.BaseAddress, XUSBPS_EPFLUSH_OFFSET) & mask) && --timeout) {}
    if (!timeout) return false;
    XUsbPs_WriteReg(usb.Config.BaseAddress, XUSBPS_EPCOMPL_OFFSET, mask);
    auto &endpoint = usb.DeviceConfig.Ep[ep];
    auto *qh = direction == XUSBPS_EP_DIRECTION_IN ? endpoint.In.dQH : endpoint.Out.dQH;
    auto *td = direction == XUSBPS_EP_DIRECTION_IN ? endpoint.In.dTDs : endpoint.Out.dTDs;
    const unsigned count = direction == XUSBPS_EP_DIRECTION_IN
        ? usb.DeviceConfig.EpCfg[ep].In.NumBufs : usb.DeviceConfig.EpCfg[ep].Out.NumBufs;
    XUsbPs_dQHInvalidateCache(qh);
    XUsbPs_WritedQH(qh, XUSBPS_dQHdTDTOKEN, 0);
    XUsbPs_dQHFlushCache(qh);
    for (unsigned i = 0; i < count; ++i) {
        XUsbPs_dTDInvalidateCache(&td[i]);
        XUsbPs_WritedTD(&td[i], XUSBPS_dTDTOKEN, 0);
        XUsbPs_dTDFlushCache(&td[i]);
    }
    return XUsbPs_ReconfigureEp(&usb, &usb.DeviceConfig, ep, direction, 0) == XST_SUCCESS;
}
void stall() {
    XUsbPs_EpStall(&usb, 0, XUSBPS_EP_DIRECTION_IN | XUSBPS_EP_DIRECTION_OUT);
}
void send_reply(size_t size, uint16_t requested) {
    if (size > requested) size = requested;
    Xil_DCacheFlushRange(reinterpret_cast<INTPTR>(reply), sizeof(reply));
    const int status = XUsbPs_EpBufferSend(&usb, 0, size ? reply : nullptr, size);
    if (status != XST_SUCCESS) { ++midi_usb_send_errors; stall(); }
}
bool valid_endpoint(uint16_t ep) { return ep == 0 || ep == 0x80 || ep == 1 || ep == 0x81; }

void setup(const XUsbPs_SetupData &s) {
    if ((s.bmRequestType & 0x60) != 0) { stall(); return; }
    const uint8_t recipient = s.bmRequestType & 0x1F;
    switch (s.bRequest) {
    case 6: { // GET_DESCRIPTOR; full-speed-only devices stall qualifier requests.
        if (s.bmRequestType != 0x80) break;
        const uint8_t type = s.wValue >> 8, index = s.wValue & 0xFF;
        size_t size = 0;
        if (type == 1 && index == 0) {
            size = sizeof(midi_device_descriptor);
            std::memcpy(reply, midi_device_descriptor, size);
        } else if (type == 2 && index == 0) {
            size = sizeof(midi_config_descriptor);
            std::memcpy(reply, midi_config_descriptor, size);
        } else if (type == 3) size = midi_string_descriptor(index, reply);
        if (!size) break;
        send_reply(size, s.wLength);
        return;
    }
    case 5: // SET_ADDRESS: controller applies it after the status stage.
        if (s.bmRequestType != 0 || s.wValue > 127 || s.wIndex || s.wLength) break;
        XUsbPs_SetDeviceAddress(&usb, s.wValue);
        send_reply(0, 0);
        return;
    case 9: // SET_CONFIGURATION
        if (s.bmRequestType != 0 || s.wValue > 1 || s.wIndex || s.wLength) break;
        configured = 0;
        if (!reset_endpoint(1, XUSBPS_EP_DIRECTION_OUT) ||
            !reset_endpoint(1, XUSBPS_EP_DIRECTION_IN)) {
            ++midi_usb_send_errors;
            request_reset();
            break;
        }
        configured = s.wValue;
        request_reset();
        if (configured) {
            XUsbPs_EpEnable(&usb, 1, XUSBPS_EP_DIRECTION_OUT | XUSBPS_EP_DIRECTION_IN);
            XUsbPs_SetBits(&usb, XUSBPS_EPCR1_OFFSET,
                XUSBPS_EPCR_TXT_BULK_MASK | XUSBPS_EPCR_RXT_BULK_MASK |
                XUSBPS_EPCR_TXR_MASK | XUSBPS_EPCR_RXR_MASK);
            XUsbPs_EpPrime(&usb, 1, XUSBPS_EP_DIRECTION_OUT);
        } else {
            XUsbPs_EpDisable(&usb, 1, XUSBPS_EP_DIRECTION_OUT | XUSBPS_EP_DIRECTION_IN);
        }
        send_reply(0, 0);
        return;
    case 8:
        if (s.bmRequestType != 0x80 || s.wValue || s.wIndex || s.wLength != 1) break;
        reply[0] = configured;
        send_reply(1, 1);
        return;
    case 0: { // GET_STATUS
        if (!(s.bmRequestType & 0x80) || s.wValue || s.wLength != 2) break;
        reply[0] = reply[1] = 0;
        if (recipient == 0 && s.wIndex == 0) reply[0] = 1; // self-powered
        else if (recipient == 1 && configured && s.wIndex < 2) {}
        else if (recipient == 2 && valid_endpoint(s.wIndex)) {
            const uint32_t reg = XUsbPs_ReadReg(usb.Config.BaseAddress,
                XUSBPS_EPCRn_OFFSET(s.wIndex & 15));
            reply[0] = (reg & ((s.wIndex & 0x80) ? XUSBPS_EPCR_TXS_MASK : XUSBPS_EPCR_RXS_MASK)) ? 1 : 0;
        } else break;
        send_reply(2, 2);
        return;
    }
    case 1:
    case 3: { // CLEAR/SET_FEATURE ENDPOINT_HALT
        if (s.bmRequestType != 2 || s.wValue || s.wLength ||
            !configured || (s.wIndex != 1 && s.wIndex != 0x81)) break;
        const uint32_t offset = XUSBPS_EPCR1_OFFSET;
        const uint32_t mask = (s.wIndex & 0x80) ? XUSBPS_EPCR_TXS_MASK : XUSBPS_EPCR_RXS_MASK;
        if (s.bRequest == 3) {
            XUsbPs_SetBits(&usb, offset, mask);
        } else {
            XUsbPs_ClrBits(&usb, offset, mask);
            XUsbPs_SetBits(&usb, offset, (s.wIndex & 0x80) ? XUSBPS_EPCR_TXR_MASK : XUSBPS_EPCR_RXR_MASK);
        }
        send_reply(0, 0);
        return;
    }
    case 10: // GET_INTERFACE
        if (s.bmRequestType != 0x81 || !configured || s.wIndex > 1 || s.wValue || s.wLength != 1) break;
        reply[0] = 0;
        send_reply(1, 1);
        return;
    case 11: // Only alternate setting zero exists.
        if (s.bmRequestType != 1 || !configured || s.wIndex > 1 || s.wValue || s.wLength) break;
        send_reply(0, 0);
        return;
    }
    stall();
}

void ep0_handler(void *, u8 ep, u8 event, void *) {
    if (event == XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED) {
        XUsbPs_SetupData data;
        if (XUsbPs_EpGetSetupData(&usb, ep, &data) == XST_SUCCESS) {
            // A new SETUP aborts the previous control transfer, including an uncompleted IN dTD.
            if (!reset_endpoint(0, XUSBPS_EP_DIRECTION_IN)) { ++midi_usb_send_errors; stall(); return; }
            XUsbPs_EpEnable(&usb, 0, XUSBPS_EP_DIRECTION_IN);
            ++midi_usb_setup_count;
            setup(data);
        }
        else stall();
    } else if (event == XUSBPS_EP_EVENT_DATA_TX) {
        ++midi_usb_ep0_tx_count;
    } else if (event == XUSBPS_EP_EVENT_DATA_RX) {
        u8 *buffer; u32 size, handle;
        if (XUsbPs_EpBufferReceive(&usb, ep, &buffer, &size, &handle) == XST_SUCCESS)
            XUsbPs_EpBufferRelease(handle);
    }
}

void ep1_handler(void *, u8 ep, u8 event, void *) {
    if (event != XUSBPS_EP_EVENT_DATA_RX) return;
    u8 *buffer; u32 size, handle;
    if (XUsbPs_EpBufferReceive(&usb, ep, &buffer, &size, &handle) != XST_SUCCESS) {
        request_reset();
        return;
    }
    Xil_DCacheInvalidateRange(reinterpret_cast<INTPTR>(buffer), (size + 31) & ~31U);
    if (size % 4) {
        ++malformed;
        request_reset();
    } else if (configured && !reset_pending) {
        XTime now;
        XTime_GetTime(&now);
        constexpr uint64_t frequency = COUNTS_PER_SECOND;
        const uint32_t timestamp = (now / frequency) * 1000000ULL +
            (now % frequency) * 1000000ULL / frequency;
        for (u32 i = 0; i < size; i += 4) {
            const unsigned next = (tail + 1) % 1024;
            if (next == head) { ++overflows; request_reset(); break; }
            std::memcpy(queue[tail].data, buffer + i, 4);
            queue[tail].received_us = timestamp;
            asm volatile("dmb sy" ::: "memory");
            tail = next;
            ++received;
        }
    }
    XUsbPs_EpBufferRelease(handle);
}

void bus_handler(void *, u32 mask) {
    if (mask & XUSBPS_IXR_UR_MASK) {
        configured = 0;
        request_reset();
        // The BSP flushes hardware on bus reset but leaves aborted software dTDs active.
        for (unsigned ep = 0; ep < 2; ++ep) {
            if (!reset_endpoint(ep, XUSBPS_EP_DIRECTION_OUT) ||
                !reset_endpoint(ep, XUSBPS_EP_DIRECTION_IN)) ++midi_usb_send_errors;
        }
        XUsbPs_EpEnable(&usb, 0, XUSBPS_EP_DIRECTION_OUT | XUSBPS_EP_DIRECTION_IN);
    }
    if (mask & XUSBPS_IXR_UE_MASK) request_reset();
    if (mask & XUSBPS_IXR_PC_MASK) {
        if (!(XUsbPs_ReadReg(usb.Config.BaseAddress, XUSBPS_PORTSCR1_OFFSET) & XUSBPS_PORTSCR_CCS_MASK)) {
            configured = 0;
            request_reset();
        }
    }
}
}

int midi_usb_init() {
    head = tail = 0;
    configured = 0;
    reset_pending = false;
    XGpioPs gpio;
    auto *gpio_config = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_DEVICE_ID);
    if (!gpio_config) return XST_FAILURE;
    if (XGpioPs_CfgInitialize(&gpio, gpio_config, gpio_config->BaseAddr) != XST_SUCCESS) return XST_FAILURE;
    XGpioPs_SetDirectionPin(&gpio, 46, 1);
    XGpioPs_SetOutputEnablePin(&gpio, 46, 1);
    XGpioPs_WritePin(&gpio, 46, 0);
    usleep(20000);
    XGpioPs_WritePin(&gpio, 46, 1);
    usleep(20000);
    XUsbPs_Config *config = XUsbPs_LookupConfig(XPAR_XUSBPS_0_DEVICE_ID);
    if (!config) return XST_FAILURE;
    int status = XUsbPs_CfgInitialize(&usb, config, config->BaseAddress);
    if (status != XST_SUCCESS) return status;

    XScuGic_Config *gic_config = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
    if (!gic_config) return XST_FAILURE;
    status = XScuGic_CfgInitialize(&gic, gic_config, 0);
    if (status != XST_SUCCESS) return status;
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
        reinterpret_cast<Xil_ExceptionHandler>(XScuGic_InterruptHandler), &gic);
    const u16 intr = XPAR_XUSBPS_0_INTR;
    const u8 trigger = 1;
    XScuGic_SetPriorityTriggerType(&gic, intr, 0xA0, trigger);
    status = XScuGic_Connect(&gic, intr, reinterpret_cast<Xil_InterruptHandler>(XUsbPs_IntrHandler), &usb);
    if (status != XST_SUCCESS) return status;

    XUsbPs_DeviceConfig device = {};
    device.NumEndpoints = 2;
    device.DMAMemPhys = reinterpret_cast<UINTPTR>(dma_memory);
    for (unsigned ep = 0; ep < 2; ++ep) {
        device.EpCfg[ep].Out.Type = ep ? XUSBPS_EP_TYPE_BULK : XUSBPS_EP_TYPE_CONTROL;
        device.EpCfg[ep].In.Type = device.EpCfg[ep].Out.Type;
        device.EpCfg[ep].Out.NumBufs = ep ? 16 : 2;
        device.EpCfg[ep].In.NumBufs = 2;
        device.EpCfg[ep].Out.BufSize = 64;
        device.EpCfg[ep].Out.MaxPacketSize = 64;
        device.EpCfg[ep].In.MaxPacketSize = 64;
    }
    Xil_DCacheFlushRange(reinterpret_cast<INTPTR>(dma_memory), sizeof(dma_memory));
    status = XUsbPs_ConfigureDevice(&usb, &device);
    if (status != XST_SUCCESS) return status;
    XUsbPs_SetBits(&usb, XUSBPS_PORTSCR1_OFFSET, XUSBPS_PORTSCR_PFSC_MASK);
    // Keep the controller stopped long enough for Windows to retire a previous JTAG-loaded device.
    XUsbPs_ClrBits(&usb, XUSBPS_OTGCSR_OFFSET, XUSBPS_OTGSC_OT_MASK);
    usleep(2000000);
    const u32 mask = XUSBPS_IXR_UR_MASK | XUSBPS_IXR_UE_MASK | XUSBPS_IXR_PC_MASK;
    if (XUsbPs_IntrSetHandler(&usb, bus_handler, nullptr, mask) != XST_SUCCESS ||
        XUsbPs_EpSetHandler(&usb, 0, XUSBPS_EP_DIRECTION_OUT | XUSBPS_EP_DIRECTION_IN, ep0_handler, nullptr) != XST_SUCCESS ||
        XUsbPs_EpSetHandler(&usb, 1, XUSBPS_EP_DIRECTION_OUT, ep1_handler, nullptr) != XST_SUCCESS)
        return XST_FAILURE;
    XScuGic_Enable(&gic, intr);
    Xil_ExceptionEnable();
    XUsbPs_IntrEnable(&usb, mask | XUSBPS_IXR_UI_MASK);
    XUsbPs_Start(&usb);
    XUsbPs_SetBits(&usb, XUSBPS_OTGCSR_OFFSET, XUSBPS_OTGSC_OT_MASK);
    usleep(20000);
    return XST_SUCCESS;
}

void midi_usb_close() {
    XScuGic_Disable(&gic, XPAR_XUSBPS_0_INTR);
    XScuGic_Disconnect(&gic, XPAR_XUSBPS_0_INTR);
    XUsbPs_IntrDisable(&usb, XUSBPS_IXR_ALL);
    XUsbPs_ClrBits(&usb, XUSBPS_OTGCSR_OFFSET, XUSBPS_OTGSC_OT_MASK);
    XUsbPs_Stop(&usb);
    head = tail = 0;
    configured = 0;
    reset_pending = false;
}

bool midi_usb_pop(MidiUsbEvent &event) {
    const uint32_t flags = irq_lock();
    const bool available = !reset_pending && head != tail;
    if (available) { event = queue[head]; head = (head + 1) % 1024; }
    irq_unlock(flags);
    return available;
}

bool midi_usb_take_reset() {
    const uint32_t flags = irq_lock();
    const bool pending = reset_pending;
    if (pending) { head = tail; reset_pending = false; }
    irq_unlock(flags);
    return pending;
}

MidiUsbStats midi_usb_stats() {
    const uint32_t flags = irq_lock();
    MidiUsbStats stats = {received, overflows, malformed, resets, midi_usb_send_errors};
    irq_unlock(flags);
    return stats;
}
