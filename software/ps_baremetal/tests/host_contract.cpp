// Executes the PS parser, MMIO, timer, codec and USB code with mocked BSP I/O.
#include "mock.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

struct RegisterWrite { u8 bank, reg, value; u64 completed; };
static u64 host_ticks = 0;
static u64 last_run0_ticks = 0;
static u32 interface_id = 0x26080008;
static std::array<u32, 3> mix_gains{{65536,65536,65536}};
static std::array<u32, 2> clips{};
static u32 control_value = 1, status_value = 0;
static int native_wait = 0, reset_wait = 0, ddr_wait = 0;
static int reset_requests = 0, polls = 0, sample_flushes = 0, sample_invalidates = 0;
static bool warm_failure = false;
static u32 ddr_base = 0, memory_type_value = 0;
static std::array<u8, 262144> sample_memory;
static std::array<u8, 2> register_address{};
static std::vector<RegisterWrite> register_writes;
static std::vector<std::pair<u8,u16>> codec_writes;
static int codec_failure = -1, codec_init_failure = 0;
static u32 private_timer_count = 0;
static u64 vmid_wait_start = 0, activation_ticks = 0;
static std::vector<u8> response_bytes, receive_bytes;
static std::vector<std::pair<u32,u32>> gpio_writes;
static std::vector<u32> usb_tx_sizes;
static MockEpHandler ep_handlers[2][2]{};
static void *ep_refs[2][2]{};
static XUsbPs_SetupData setup_packet{};
static XUsbPs_DeviceConfig device_configuration{};
static int usb_send_failure = 0, usb_stalls = 0, usb_releases = 0;
static std::vector<std::string> checks;

static void require(bool ok, const char *message)
{
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
static void passed(const char *message) { checks.emplace_back(message); }
extern "C" void XTime_GetTime(XTime *value) { *value = host_ticks; }
int xil_printf(const char *, ...) { return 0; }
int usleep(unsigned int us) { host_ticks += static_cast<u64>(us) * COUNTS_PER_SECOND / 1000000ULL; return 0; }
u32 Xil_In32(UINTPTR address)
{
    if (address == 0x43C0001CU) return interface_id;
    if (address >= 0x43C00024U && address <= 0x43C0002CU) return mix_gains[(address-0x43C00024U)/4];
    if (address >= 0x43C00030U && address <= 0x43C00034U) return clips[(address-0x43C00030U)/4];
    if (address == 0x43C00004U) return control_value;
    if (address == 0x43C00008U) {
        ++polls;
        host_ticks += 10;
        u32 value = status_value;
        if (native_wait > 0) { --native_wait; value |= 33; }
        if (reset_wait > 0) { --reset_wait; value |= 2; }
        if (ddr_wait > 0) { --ddr_wait; value |= 4; }
        return value;
    }
    return 0;
}
void Xil_Out32(UINTPTR address, u32 value)
{
    if (address == 0x43C00004U) {
        const bool resuming = (value & 1) && !(control_value & 1) && !(value & 2);
        if (!(value & 1) && (control_value & 1)) last_run0_ticks = host_ticks;
        if (value & 2) { ++reset_requests; reset_wait = 4; status_value &= ~8U; }
        control_value = value & 5U;
        if (resuming) {
            host_ticks += COUNTS_PER_SECOND / 10000ULL; // Real B response follows cache warm.
            if (warm_failure) { status_value |= 8; control_value = 4; }
        }
    } else if (address == 0x43C0000CU) {
        require(!(control_value & 1), "DDR base changes only with RUN=0"); ddr_base = value;
    } else if (address == 0x43C00010U) {
        require(!(control_value & 1), "memory type changes only with RUN=0"); memory_type_value = value;
    } else if (address >= 0x43C00024U && address <= 0x43C0002CU) {
        require(control_value == 4, "mix writes stopped and muted");
        mix_gains[(address-0x43C00024U)/4] = value;
    } else if (address >= 0x43C00030U && address <= 0x43C00034U) {
        clips[(address-0x43C00030U)/4] = 0;
    } else require(false, "known control register");
}
void Xil_Out8(UINTPTR address, u8 value)
{
    require(control_value & 1, "native WR requires RUN");
    require(native_wait == 0 && reset_wait == 0, "poll native busy/reset/host pending before each byte");
    require(!(status_value & 8), "no native write after DDR error");
    const u32 lane = static_cast<u32>(address - 0x43C00000U);
    require(lane < 4, "four native byte MMIO lanes");
    if ((lane & 1) == 0) register_address[lane / 2] = value;
    const u32 wait_us = lane == 1 && register_address[0] == 0x10 ? 74 : 12;
    host_ticks += static_cast<u64>(wait_us) * COUNTS_PER_SECOND / 1000000ULL;
    if (lane & 1) register_writes.push_back({static_cast<u8>(lane / 2), register_address[lane / 2], value, host_ticks});
    native_wait = 3; // AXI response and subsequent hardware recovery polling.
}
void Xil_DCacheFlushRange(INTPTR address, u32 length)
{
    if (address == reinterpret_cast<INTPTR>(sample_memory.data())) {
        require(!(control_value & 1) && ddr_wait == 0, "sample flush after RUN=0 and DDR idle");
        require(length == sample_memory.size(), "complete native sample cache range"); ++sample_flushes;
    }
}
void Xil_DCacheInvalidateRange(INTPTR address, u32 length)
{
    if (address == reinterpret_cast<INTPTR>(sample_memory.data())) {
        require(!(control_value & 1) && length == sample_memory.size(), "native-write readback cache invalidation");
        ++sample_invalidates;
    }
}
namespace { u8 *opna_host_sample_data() { return sample_memory.data(); } }

XScuTimer_Config *XScuTimer_LookupConfig(u16) { static XScuTimer_Config cfg{}; return &cfg; }
int XScuTimer_CfgInitialize(XScuTimer *, XScuTimer_Config *, UINTPTR) { return 0; }
void XScuTimer_SetPrescaler(XScuTimer *, u8 value) { require(value == 0, "SCU prescaler zero"); }
void XScuTimer_Stop(XScuTimer *) {}
void XScuTimer_DisableAutoReload(XScuTimer *) {}
void XScuTimer_LoadTimer(XScuTimer *, u32 value) { private_timer_count = value; }
void XScuTimer_Start(XScuTimer *) { host_ticks += private_timer_count; }
u32 XScuTimer_GetCounterValue(XScuTimer *) { return 0; }
XIicPs_Config *XIicPs_LookupConfig(u16) { static XIicPs_Config cfg{}; return codec_init_failure == 1 ? nullptr : &cfg; }
int XIicPs_CfgInitialize(XIicPs *, XIicPs_Config *, UINTPTR) { return codec_init_failure == 2 ? 1 : 0; }
int XIicPs_SelfTest(XIicPs *) { return codec_init_failure == 3 ? 1 : 0; }
int XIicPs_SetSClk(XIicPs *, u32 rate) { require(rate == 100000, "codec I2C 100 kHz"); return codec_init_failure == 4 ? 1 : 0; }
int XIicPs_MasterSendPolled(XIicPs *, u8 *data, int count, u16 address)
{
    require(count == 2 && address == 0x1A, "codec 7-bit address and packed 9-bit value");
    const u8 reg = data[0] >> 1;
    const u16 value = ((data[0] & 1) << 8) | data[1];
    if (reg == 6 && value == 0x77) vmid_wait_start = host_ticks;
    if (reg == 9) activation_ticks = host_ticks;
    const int index = static_cast<int>(codec_writes.size());
    codec_writes.emplace_back(reg, value);
    return codec_failure == index ? 23 : 0;
}
int XIicPs_BusIsBusy(XIicPs *) { return 0; }
XGpioPs_Config *XGpioPs_LookupConfig(u16) { static XGpioPs_Config cfg{}; return &cfg; }
int XGpioPs_CfgInitialize(XGpioPs *, XGpioPs_Config *, UINTPTR) { return 0; }
void XGpioPs_SetDirectionPin(XGpioPs *, u32 pin, u32 value) { require(pin == 46 && value == 1, "USB PHY MIO46 output"); }
void XGpioPs_SetOutputEnablePin(XGpioPs *, u32 pin, u32 value) { require(pin == 46 && value == 1, "USB PHY MIO46 output enable"); }
void XGpioPs_WritePin(XGpioPs *, u32 pin, u32 value) { gpio_writes.emplace_back(pin, value); }
XScuGic_Config *XScuGic_LookupConfig(u16) { static XScuGic_Config cfg; return &cfg; }
int XScuGic_CfgInitialize(XScuGic *, XScuGic_Config *, UINTPTR) { return 0; }
void XScuGic_InterruptHandler(void *) {}
int XScuGic_Connect(XScuGic *, u16 id, Xil_ExceptionHandler, void *) { require(id == 53, "PS USB interrupt"); return 0; }
void XScuGic_SetPriorityTriggerType(XScuGic *, u16, u8, u8) {}
void XScuGic_Enable(XScuGic *, u16) {}
void XScuGic_Disable(XScuGic *, u16) {}
void XScuGic_Disconnect(XScuGic *, u16) {}
void Xil_ExceptionInit() {}
void Xil_ExceptionRegisterHandler(int, Xil_ExceptionHandler, void *) {}
void Xil_ExceptionEnable() {}
XUsbPs_Config *XUsbPs_LookupConfig(u16) { static XUsbPs_Config cfg{}; return &cfg; }
int XUsbPs_CfgInitialize(XUsbPs *usb, XUsbPs_Config *cfg, UINTPTR) { usb->Config = *cfg; return 0; }
int XUsbPs_ConfigureDevice(XUsbPs *, XUsbPs_DeviceConfig *cfg) { device_configuration = *cfg; return 0; }
int XUsbPs_IntrSetHandler(XUsbPs *, void (*)(void *, u32), void *, u32) { return 0; }
int XUsbPs_EpSetHandler(XUsbPs *, u8 ep, u8 dir, MockEpHandler cb, void *ref) { ep_handlers[ep][dir] = cb; ep_refs[ep][dir] = ref; return 0; }
int XUsbPs_EpGetSetupData(XUsbPs *, u8, XUsbPs_SetupData *data) { *data = setup_packet; return 0; }
int XUsbPs_EpBufferReceive(XUsbPs *, u8, u8 **data, u32 *count, u32 *handle) { *data = receive_bytes.data(); *count = static_cast<u32>(receive_bytes.size()); *handle = 1; return 0; }
void XUsbPs_EpBufferRelease(u32) { ++usb_releases; }
int XUsbPs_EpBufferSend(XUsbPs *, u8 ep, u8 *data, u32 count)
{
    if (usb_send_failure) return 1;
    if (count) response_bytes.insert(response_bytes.end(), data, data + count);
    if (ep == 1) {
        usb_tx_sizes.push_back(count);
        ep_handlers[1][1](ep_refs[1][1], 1, XUSBPS_EP_EVENT_DATA_TX, nullptr);
    }
    return 0;
}
void XUsbPs_IntrHandler(void *) {}
void XUsbPs_IntrEnable(XUsbPs *, u32) {}
void XUsbPs_IntrDisable(XUsbPs *, u32) {}
void XUsbPs_Start(XUsbPs *) {}
void XUsbPs_Stop(XUsbPs *) {}
void XUsbPs_ClrBits(XUsbPs *, u32, u32) {}
void XUsbPs_SetBits(XUsbPs *, u32, u32) {}
u32 XUsbPs_ReadReg(UINTPTR, u32) { return 0; }
void XUsbPs_EpStall(XUsbPs *, u8, u8) { ++usb_stalls; }
void XUsbPs_SetDeviceAddress(XUsbPs *, u16) {}
void XUsbPs_EpEnable(XUsbPs *, u8, u8) {}
void XUsbPs_EpPrime(XUsbPs *, u8, u8) {}

#define OPNA_HOST_TEST 1
#include "../src/opl_hw.cpp"
#include "../src/timer_ps.cpp"
#include "../src/ssm2603.cpp"
#include "../src/transport_usb.cpp"
#include "../src/usb_ch9.c"
#include "../src/usb_descriptors.c"
int transport_open_stream() { return usb_transport_open_stream(); }
void transport_close_stream() { usb_transport_close_stream(); }
bool transport_read_byte(u8 *value) { return usb_transport_read_byte(value); }
void transport_write(const u8 *data, size_t length) { usb_transport_write(data, length); }
int transport_error() { return usb_transport_error(); }
const TransportCapabilities &transport_get_capabilities() { return usb_transport_get_capabilities(); }
#include "../src/opl_stream.cpp"

static FrameParser parser;
static bool keep_running = true;
static void frame(u8 type, const std::vector<u8> &payload = {}, bool corrupt = false)
{
    require(payload.size() <= 1024, "host frame maximum");
    receive_bytes = {0x4F, 0x50, type, static_cast<u8>(payload.size()), static_cast<u8>(payload.size() >> 8)};
    receive_bytes.insert(receive_bytes.end(), payload.begin(), payload.end());
    receive_bytes.push_back(calc_checksum(type, static_cast<u16>(payload.size()), payload.data()) ^ (corrupt ? 1 : 0));
    ep_handlers[1][0](ep_refs[1][0], 1, XUSBPS_EP_EVENT_DATA_RX, nullptr);
    u8 byte;
    while (usb_transport_read_byte(&byte)) feed_parser(&parser, byte, &keep_running);
}
static std::vector<u8> word(u32 value) { return {static_cast<u8>(value), static_cast<u8>(value >> 8), static_cast<u8>(value >> 16), static_cast<u8>(value >> 24)}; }
static void upload_song(const std::vector<u8> &song)
{
    frame(8, word(static_cast<u32>(song.size())));
    for (size_t i = 0; i < song.size(); i += 1024)
        frame(9, std::vector<u8>(song.begin() + i, song.begin() + std::min(i + 1024, song.size())));
    frame(10);
    require(g_song.loaded_ready && g_song.loaded_size == song.size(), "song protocol upload completion");
}
static std::vector<u8> event(u32 delay, u8 bank, u8 reg, u8 value)
{
    auto data = word(delay); data.insert(data.end(), {1, bank, reg, value}); return data;
}
static void drive_buffered()
{
    while (g_song.playback_active) {
        service_buffered_playback();
        if (g_song.event_armed && host_ticks < g_song.next_event_ticks) host_ticks = g_song.next_event_ticks;
    }
}

int main(int argc, char **argv)
{
    require(argc == 2, "real music host input path");
    for (u32 us : {1U, 50U, 75000U, 1000000U, 0xFFFFFFFFU}) {
        require(TimerMicrosecondsToTicks(us) == static_cast<u64>(us) * COUNTS_PER_SECOND / 1000000ULL, "timer exact rational conversion");
        require(TimerTicksToMicroseconds(TimerMicrosecondsToTicks(us)) <= us && us - TimerTicksToMicroseconds(TimerMicrosecondsToTicks(us)) <= 1, "timer reciprocal and no legacy x4 correction");
    }
    require(TimerInitialize(0) == 0, "timer initialized");
    passed("fresh-BSP timer units and reciprocal conversion");
    const std::vector<std::pair<u8,u16>> codec_expected = {{15,0},{6,0x77},{0,0x97},{1,0x97},{2,0x79},{3,0x79},{4,0x10},{5,0},{7,2},{8,0},{9,1},{6,0x67}};
    require(ssm2603_init() == 0 && codec_writes == codec_expected, "complete playback codec sequence");
    require(activation_ticks - vmid_wait_start >= TimerMicrosecondsToTicks(75000), "VMID charge before ACTIVE");
    for (int failure = 0; failure < 12; ++failure) {
        codec_writes.clear(); codec_failure = failure;
        require(ssm2603_init() == 23 && codec_writes.size() == static_cast<size_t>(failure + 1), "codec write failure propagates and stops sequence");
    }
    codec_failure = -1;
    for (codec_init_failure = 1; codec_init_failure <= 4; ++codec_init_failure)
        require(ssm2603_init() < 0, "codec lookup/init/selftest/clock failures");
    codec_init_failure = 0;
    passed("SSM2603 16-bit I2S 48kHz ACTIVE/power/VMID and all failures");
    require(usb_transport_open_stream() == 0, "real USB transport opens with BSP mock");
    require(gpio_writes == std::vector<std::pair<u32,u32>>{{46,0},{46,1}}, "USB PHY reset pulse");
    require(device_configuration.NumEndpoints == 2 && device_configuration.EpCfg[1].Out.MaxPacketSize == 64 && device_configuration.EpCfg[1].In.MaxPacketSize == 64, "real bulk endpoint configuration");
    setup_packet = {0,9,1,0,0};
    ep_handlers[0][0](ep_refs[0][0], 0, XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED, nullptr);
    require(usb_ch9_is_configured(), "USB set configuration");
    u8 descriptor[128];
    require(XUsbPs_Ch9SetupDevDescReply(descriptor, sizeof(descriptor)) == 18 && descriptor[8] == 0xFE && descriptor[9] == 0xCA, "USB device descriptor");
    require(XUsbPs_Ch9SetupCfgDescReply(descriptor, sizeof(descriptor)) == 32 && descriptor[20] == 1 && descriptor[27] == 0x81, "USB configuration two bulk endpoints");
    const u32 product_size = XUsbPs_Ch9SetupStrDescReply(descriptor, sizeof(descriptor), 2);
    std::string product;
    for (u32 i = 2; i < product_size; i += 2) product.push_back(descriptor[i]);
    require(product == "Zybo OPNA USB Interface", "OPNA product descriptor");
    setup_packet = {0x80,6,0x0100,0,18}; response_bytes.clear();
    ep_handlers[0][0](ep_refs[0][0],0,XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED,nullptr);
    require(response_bytes.size() == 18, "EP0 device descriptor reply");
    setup_packet = {0xC0,0x20,0,4,40}; response_bytes.clear();
    ep_handlers[0][0](ep_refs[0][0],0,XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED,nullptr);
    require(response_bytes.size() == 40 && response_bytes[18] == 'W', "WinUSB compatibility descriptor");
    setup_packet = {0x20,0xFE,0,0,0};
    ep_handlers[0][0](ep_refs[0][0],0,XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED,nullptr);
    require(usb_stalls > 0, "unsupported control request stalls");
    passed("real USB PHY/EP0 descriptors/WinUSB/bulk callbacks");
    response_bytes.clear(); frame(1);
    require(response_bytes.size() == 30 && response_bytes[5] == 2 && response_bytes[6] == 2, "protocol 2.2 HELLO via actual USB RX/TX");
    frame(6, {}, true);
    require(response_bytes[response_bytes.size() - 2] == 4, "bad protocol checksum rejected");
    const auto before_invalid = g_queue.count;
    frame(3, event(0,2,0x22,0xFF));
    require(g_queue.count == before_invalid, "invalid native bank rejected before enqueue");
    passed("USB framed parser checksum/HELLO/invalid-bank rejection");
    auto gains = word(131072); auto ssg = word(21845), master = word(8192);
    gains.insert(gains.end(),ssg.begin(),ssg.end()); gains.insert(gains.end(),master.begin(),master.end());
    response_bytes.clear(); clips={7,9}; frame(0x12,gains);
    require(response_bytes.size()==18 && response_bytes[2]==0x92 &&
        std::equal(gains.begin(),gains.end(),response_bytes.begin()+5) &&
        mix_gains==std::array<u32,3>{{131072,21845,8192}} && clips==std::array<u32,2>{{0,0}}, "SET_MIX echo/readback/clear");
    clips={4,6}; response_bytes.clear(); frame(6);
    require(response_bytes.size()==35 && load_u32(response_bytes.data()+26)==4 && load_u32(response_bytes.data()+30)==6, "STATUS clip counters");
    response_bytes.clear(); frame(0x12,{1}); require(response_bytes[2]==0x7F, "SET_MIX invalid length rejected");
    interface_id=0x26080007; response_bytes.clear(); frame(0x12,gains);
    require(response_bytes[2]==0x7F, "SET_MIX old FPGA rejected"); interface_id=0x26080008;
    frame(5); require(mix_gains==std::array<u32,3>{{65536,65536,65536}}, "reset restores MIDI defaults");
    passed("SET_MIX protocol 2.2 gain readback, counters, reset, malformed and old FPGA");
    native_wait = 5; reset_wait = 2; status_value |= 4;
    require(opl_write_reg(0x22,0x08,1), "native writes ignore unrelated DDR prefetch pending");
    status_value &= ~4U;
    const int reset_before = reset_requests;
    require(opl_reset_core() && reset_requests == reset_before + 1 && reset_wait == 0, "actual IC request and release wait");
    status_value = 8;
    require(!opl_write_reg(0x22,1,0), "DDR error blocks native writes");
    require(opl_reset_core() && !(status_value & 8), "reset clears DDR error");
    require(opl_set_running(false), "native stopped for failed cache handoff");
    warm_failure = true;
    require(!opl_set_running(true) && !(control_value & 1), "RUN1 postcheck reports DDR warm failure and keeps native paused");
    warm_failure = false;
    require(opl_reset_core(), "actual reset recovers warm fault");
    passed("native byte MMIO busy/queue/IC/reset/fault contract");
    register_writes.clear();
    auto live = word(100); live.insert(live.end(),{2,0,0x22,8,1,0,0x80});
    frame(3,live); service_stream_playback();
    const u64 live_due = g_stream_next_deadline_ticks;
    require(g_queue.count == 2, "live queue waits for absolute event time");
    host_ticks = live_due; service_stream_playback();
    require(g_queue.count == 0 && register_writes.size() == 2 &&
            register_writes[0].bank == 0 && register_writes[0].reg == 0x22 &&
            register_writes[1].bank == 1 && register_writes[1].reg == 0,
            "live grouped event serialized in both banks");
    std::vector<u8> batch = word(0); batch.push_back(128);
    for (u32 i=0;i<128;++i) batch.insert(batch.end(),{static_cast<u8>(i&1),0x22,0});
    for (int i=0;i<16;++i) frame(3,batch);
    require(g_queue.count == 2048, "live queue full capacity");
    frame(3,event(0,0,0x22,0));
    require(g_queue.count == 2048, "live queue overflow rejected without partially enqueuing");
    queue_clear();
    passed("live grouped events/absolute time/bank order/2048-write capacity");
    auto song = event(100,0,0x10,1);
    auto second = event(20,1,0x00,0x80); song.insert(song.end(),second.begin(),second.end());
    auto third = event(500,0,0x28,0xF0); song.insert(song.end(),third.begin(),third.end());
    upload_song(song); frame(0x12,gains); frame(11);
    require(mix_gains==std::array<u32,3>{{131072,21845,8192}}, "PLAY reset preserves selected mix");
    response_bytes.clear(); frame(0x12,gains); require(response_bytes[2]==0x7F, "playing SET_MIX rejected");
    const u64 started = g_song.next_event_ticks;
    service_buffered_playback(); host_ticks = g_song.next_event_ticks; service_buffered_playback();
    service_buffered_playback();
    require(g_song.next_event_ticks == started + TimerMicrosecondsToTicks(120), "buffer deadlines anchored despite rhythm/native wait");
    // Inject CPU servicing delay beyond both the source time and legal cursor.
    host_ticks += TimerMicrosecondsToTicks(200);
    service_buffered_playback();
    require(g_late_writes > 0 && g_max_late_ticks > 0, "additional software dispatch lateness recorded separately from native serialization");
    const int pause_resets = reset_requests;
    const u64 before_pause = host_ticks, old_cursor = g_serialized_ready_ticks;
    native_wait = 7; ddr_wait = 400;
    frame(12);
    require(g_song.playback_paused && !(control_value & 1) && reset_requests == pause_resets, "pause freezes RUN without IC");
    response_bytes.clear(); frame(0x12,gains); require(response_bytes[2]==0x7F, "paused SET_MIX rejected");
    const u64 pause_tick = g_pause_start_ticks, old_due = g_song.next_event_ticks;
    require(pause_tick == last_run0_ticks && pause_tick > before_pause && host_ticks > pause_tick && ddr_wait == 0,
            "pause epoch follows native busy wait and RUN0 response, before DDR drain");
    host_ticks += TimerMicrosecondsToTicks(250000);
    const u64 before_resume = host_ticks;
    frame(13);
    require(host_ticks >= before_resume + TimerMicrosecondsToTicks(100) && !g_song.playback_paused && control_value == 1 &&
            g_song.next_event_ticks == old_due + host_ticks - pause_tick &&
            g_serialized_ready_ticks == old_cursor + host_ticks - pause_tick,
            "resume shifts source timeline and chip cursor by DDR drain, pause and completed RUN1 warm");
    drive_buffered();
    frame(6);
    passed("absolute playback deadline/late reporting/pause-resume state");
    frame(8,word(8388609)); require(!g_song.upload_active, "8MiB capacity overflow rejected");
    std::vector<u8> capacity(8388608,0);
    for (size_t offset = 0; offset < capacity.size(); offset += 8) { capacity[offset+4] = 1; capacity[offset+5] = (offset/8) & 1; }
    upload_song(capacity);
    require(g_song.loaded_size == 8388608, "exact 8MiB upload and validation");
    frame(9,{1}); require(g_song.loaded_size == 8388608, "chunk after end rejected");
    frame(8,word(8)); frame(9,{0,0,0,0,1,2,0,0}); frame(10);
    require(!g_song.loaded_ready, "buffered invalid bank rejected");
    passed("8MiB upload boundary and malformed buffered events");
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<u8> real((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    require(real.size() >= 12 && std::string(real.begin(),real.begin()+4) == "OPN7", "real music fixture format");
    const u32 music_bytes = load_u32(real.data()+4), samples_bytes = load_u32(real.data()+8);
    require(samples_bytes == 34560 && real.size() == 12ULL + music_bytes + samples_bytes, "real Counterattack sample size");
    const std::vector<u8> music(real.begin()+12,real.begin()+12+music_bytes);
    const std::vector<u8> samples(real.begin()+12+music_bytes,real.end());
    auto begin = word(0); auto sample_size = word(samples_bytes); begin.insert(begin.end(),sample_size.begin(),sample_size.end()); begin.push_back(0);
    ddr_wait = 4; frame(14,begin);
    for (size_t i = 0; i < samples.size(); i += 1024) frame(15,std::vector<u8>(samples.begin()+i,samples.begin()+std::min(i+1024,samples.size())));
    frame(16);
    require(sample_flushes && control_value == 1 && ddr_base == 0x01000000 && memory_type_value == 0, "sample flush then PL cache invalidation/RUN");
    require(std::equal(samples.begin(),samples.end(),sample_memory.begin()) && std::all_of(sample_memory.begin()+samples.size(),sample_memory.end(),[](u8 x){return x==0;}), "actual Counterattack samples byte exact and zero-filled tail");
    upload_song(music); register_writes.clear(); frame(11); drive_buffered();
    size_t offset = 0, index = 0; bool bank_seen[2]{};
    while (offset < music.size()) {
        const u8 count = music[offset+4];
        for (u32 i = 0; i < count; ++i) {
            const u8 *expected = music.data()+offset+5+i*3;
            require(index < register_writes.size(), "real music write present");
            const auto &actual = register_writes[index++]; bank_seen[expected[0]] = true;
            require(actual.bank == expected[0] && actual.reg == expected[1] && actual.value == expected[2], "all real music MMIO values/order exact");
        }
        offset += 5+count*3;
    }
    require(index == 887 && index == register_writes.size() && bank_seen[0] && bank_seen[1], "all 887 real first-second writes across both banks");
    // Independently reconstruct the contract's legal chip-bus timeline from
    // source delays, before considering mocked MMIO service time.
    offset = 0; u64 source_due = g_debug_buffered_start_ticks;
    u64 legal_cursor = source_due;
    while (offset < music.size()) {
        source_due += static_cast<u64>(load_u32(music.data()+offset)) * COUNTS_PER_SECOND / 1000000ULL;
        for (u32 i=0;i<music[offset+4];++i) {
            const u8 *write = music.data()+offset+5+i*3;
            legal_cursor = std::max(legal_cursor,source_due) +
                static_cast<u64>(write[0]==0 && write[1]==0x10 ? 78 : 32) * COUNTS_PER_SECOND / 1000000ULL;
        }
        offset += 5+music[offset+4]*3;
    }
    require(g_serialized_ready_ticks == legal_cursor, "real music legal serialized cursor independent of processing drift");
    const u32 music_late = g_late_writes;
    const u64 music_max_late = TimerTicksToMicroseconds(g_max_late_ticks);
    const u32 source_late = g_source_completion_late_writes;
    const u64 source_max_late = TimerTicksToMicroseconds(g_max_source_completion_late_ticks);
    passed("Counterattack real VGM first-second 887 writes and 34560 sample bytes");
    // Verify the last RAM1 bank and the complete 18-bit byte space, beyond 64KiB.
    require(opl_sample_begin(0,262144,2), "complete 256KiB sample upload");
    std::vector<u8> full(262144); for (u32 i=0;i<full.size();++i) full[i]=static_cast<u8>(i ^ (i >> 16));
    require(opl_sample_write(full.data(),full.size()) && opl_sample_end(), "full RAM1 image cache handoff");
    std::array<u8,16> tail;
    require(opl_sample_read(0x3FFF0,tail.data(),tail.size()) && std::equal(tail.begin(),tail.end(),full.end()-16), "last RAM1 bank/address readback");
    sample_memory[0x3FFFF] = 0xA5; // Models a native HP0 memory write already proved by board RTL test.
    require(opl_sample_read(0x3FFFF,tail.data(),1) && tail[0] == 0xA5 && sample_invalidates, "CPU readback sees native memory writes after cache invalidate");
    require(!opl_sample_begin(0x3FFFF,2,1) && !opl_sample_begin(0,1,3), "sample bounds and memory type rejection");
    require(opl_sample_begin(0x20000,2,1) && !opl_sample_end(), "incomplete sample upload rejected");
    const u8 pair[2] = {0x12,0x34};
    require(!opl_sample_write(pair,3) && opl_sample_write(pair,2) && opl_sample_end(), "sample overrun rejected then exact upload completes");
    require(sample_memory[0x20000] == 0x12 && sample_memory[0x20001] == 0x34, "offset upload beyond 64KiB");
    auto read_request = word(0x20000); read_request.insert(read_request.end(),{2,0});
    response_bytes.clear(); frame(17,read_request);
    require(response_bytes.size()==8 && response_bytes[2]==0x91 && response_bytes[5]==0x12 && response_bytes[6]==0x34, "sample readback protocol");
    passed("full 256KiB DDR/8 RAM1 banks/cache/native-write readback/bounds");
    std::vector<u8> large(1024,0x55); usb_tx_sizes.clear(); usb_transport_write(large.data(),large.size());
    require(usb_tx_sizes.size() == 16 && std::all_of(usb_tx_sizes.begin(),usb_tx_sizes.end(),[](u32 n){return n==64;}), "1024-byte response split into 64-byte USB packets");
    usb_send_failure = 1; usb_transport_write(large.data(),1);
    require(usb_transport_error() == 2, "USB transmit failure is visible");
    usb_send_failure = 0; g_usb.error = 0;
    usb_intr_handler(nullptr,XUSBPS_IXR_UR_MASK);
    require(!usb_ch9_is_configured() && usb_transport_error() == 4, "configured USB reset reported and configuration cleared");
    g_usb.error = 0; g_usb.rx_ring.head = g_usb.rx_ring.tail = 0;
    usb_ring_push_bytes(large.data(),large.size());
    std::vector<u8> overflow(8192,0); usb_ring_push_bytes(overflow.data(),overflow.size());
    require(usb_transport_error() == 1, "USB RX ring overflow visible instead of silent truncation");
    passed("USB TX packetization/error/reset and RX overflow");
    g_usb.error = 0;
    usb_ch9_reset_configured();
    usb_transport_set_stop_callback([] { return true; });
    usb_transport_write(large.data(), 1);
    require(usb_transport_error() == 0, "mode switch cancels an unconfigured USB reply");
    g_configured = 1;
    g_usb.tx_busy = true;
    usb_transport_write(large.data(), 1);
    require(usb_transport_error() == 0, "mode switch cancels a busy USB reply");
    g_usb.tx_busy = false;
    usb_transport_set_stop_callback(nullptr);
    passed("mode switch exits blocked native USB replies");
    std::printf("{\"status\":\"passed\",\"board_verified\":false,\"counter_counts_per_second\":%llu,\"music_writes\":887,\"music_sample_bytes\":34560,\"music_dispatch_late_writes\":%u,\"music_max_dispatch_lateness_us\":%llu,\"music_source_completion_late_writes\":%u,\"music_max_source_completion_lateness_us\":%llu,\"checks\":[",static_cast<unsigned long long>(COUNTS_PER_SECOND),music_late,static_cast<unsigned long long>(music_max_late),source_late,static_cast<unsigned long long>(source_max_late));
    for (size_t i=0;i<checks.size();++i) std::printf("%s\"%s\"",i?",":"",checks[i].c_str());
    std::puts("]}");
}
