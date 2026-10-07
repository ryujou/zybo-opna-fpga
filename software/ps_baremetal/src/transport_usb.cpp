#include "transport_backend.h"

#include <cstring>

#include "sleep.h"
#include "usb_ch9.h"
#include "xgpiops.h"
#include "xscugic.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xinterrupt_wrap.h"
#include "xparameters.h"
#include "xusbps.h"

extern "C" volatile u32 g_debug_usb_ep0_setup_count = 0;
extern "C" volatile u32 g_debug_usb_ep0_rx_count = 0;
extern "C" volatile u32 g_debug_usb_ep1_out_count = 0;
extern "C" volatile u32 g_debug_usb_ep1_out_bytes = 0;
extern "C" volatile u32 g_debug_usb_ep1_in_count = 0;
extern "C" volatile u32 g_debug_usb_ep1_in_bytes = 0;
extern "C" volatile u32 g_debug_usb_last_event_type = 0;
extern "C" volatile u32 g_debug_usb_last_status = 0;
extern "C" volatile u32 g_debug_usb_open_stage = 0;
extern "C" volatile u32 g_debug_usb_open_error = 0;

namespace {

constexpr u16 kMaxFramePayload = 1024;
constexpr u16 kUploadChunkBytes = 1024;
constexpr size_t kUsbRxRingSize = 8192;
constexpr size_t kUsbTxChunkSize = 64;
constexpr size_t kUsbDmaMemorySize = 64 * 1024;
constexpr u32 kUsbPhyResetPin = 46U;

const TransportCapabilities kCaps = {
	TransportKind::Usb,
	0,
	0,
	kMaxFramePayload,
	kUploadChunkBytes,
	1,
	false,
};

struct UsbRxRing {
	u8 data[kUsbRxRingSize];
	volatile size_t head = 0;
	volatile size_t tail = 0;
};

struct UsbTransportState {
	XUsbPs instance;
	UsbCh9Local ch9_local = {};
	bool initialized = false;
	volatile bool tx_busy = false;
	volatile int error = 0;
	UsbRxRing rx_ring;
};

UsbTransportState g_usb = {};
XScuGic g_usb_gic = {};
bool g_usb_gic_ready = false;
u8 g_dma_memory[kUsbDmaMemorySize] USB_ALIGN_CACHELINE = {};
u8 g_tx_buffer[kUsbTxChunkSize] USB_ALIGN_CACHELINE = {};

void debug_store_u32(volatile u32 *ptr, u32 value)
{
	*ptr = value;
	Xil_DCacheFlushRange((INTPTR)ptr, sizeof(*ptr));
}

void debug_add_u32(volatile u32 *ptr, u32 delta)
{
	*ptr += delta;
	Xil_DCacheFlushRange((INTPTR)ptr, sizeof(*ptr));
}

void usb_intr_handler(void *CallBackRef, u32 Mask)
{
	(void)CallBackRef;
	if (Mask & XUSBPS_IXR_UR_MASK) {
		if (usb_ch9_is_configured()) g_usb.error = 4;
		usb_ch9_reset_configured();
		g_usb.tx_busy = false;
	}
	if (Mask & XUSBPS_IXR_UE_MASK) g_usb.error = 5;
}

void usb_ring_push_bytes(const u8 *data, size_t length)
{
	for (size_t i = 0; i < length; ++i) {
		size_t next_tail = (g_usb.rx_ring.tail + 1) % kUsbRxRingSize;
		if (next_tail == g_usb.rx_ring.head) {
			g_usb.error = 1;
			return;
		}
		g_usb.rx_ring.data[g_usb.rx_ring.tail] = data[i];
		g_usb.rx_ring.tail = next_tail;
	}
}

void usb_ep0_event_handler(void *CallBackRef, u8 EpNum, u8 EventType, void *Data)
{
	XUsbPs *InstancePtr;
	int Status;
	XUsbPs_SetupData SetupData;
	u8 *BufferPtr;
	u32 BufferLen;
	u32 Handle;

	(void)Data;
	InstancePtr = (XUsbPs *)CallBackRef;
	if (InstancePtr == nullptr) {
		return;
	}

	switch (EventType) {
	case XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED:
		debug_add_u32(&g_debug_usb_ep0_setup_count, 1U);
		debug_store_u32(&g_debug_usb_last_event_type, 0x100U | EventType);
		Status = XUsbPs_EpGetSetupData(InstancePtr, EpNum, &SetupData);
		debug_store_u32(&g_debug_usb_last_status, (u32)Status);
		if (Status == XST_SUCCESS) {
			(void)XUsbPs_Ch9HandleSetupPacket(InstancePtr, &SetupData);
		}
		break;
	case XUSBPS_EP_EVENT_DATA_RX:
		debug_add_u32(&g_debug_usb_ep0_rx_count, 1U);
		debug_store_u32(&g_debug_usb_last_event_type, 0x200U | EventType);
		Status = XUsbPs_EpBufferReceive(InstancePtr, EpNum, &BufferPtr, &BufferLen, &Handle);
		debug_store_u32(&g_debug_usb_last_status, (u32)Status);
		if (Status == XST_SUCCESS) {
			XUsbPs_EpBufferRelease(Handle);
		}
		break;
	default:
		break;
	}
}

void usb_ep1_out_event_handler(void *CallBackRef, u8 EpNum, u8 EventType, void *Data)
{
	XUsbPs *InstancePtr;
	int Status;
	u8 *BufferPtr;
	u32 BufferLen;
	u32 InvalidateLen;
	u32 Handle;

	(void)Data;
	InstancePtr = (XUsbPs *)CallBackRef;
	if ((InstancePtr == nullptr) || (EventType != XUSBPS_EP_EVENT_DATA_RX)) {
		return;
	}

	debug_store_u32(&g_debug_usb_last_event_type, 0x300U | EventType);
	Status = XUsbPs_EpBufferReceive(InstancePtr, EpNum, &BufferPtr, &BufferLen, &Handle);
	debug_store_u32(&g_debug_usb_last_status, (u32)Status);
	if (Status != XST_SUCCESS) {
		return;
	}

	debug_add_u32(&g_debug_usb_ep1_out_count, 1U);
	debug_add_u32(&g_debug_usb_ep1_out_bytes, BufferLen);
	InvalidateLen = (BufferLen % 32U) == 0U ? BufferLen : ((BufferLen / 32U) * 32U) + 32U;
	Xil_DCacheInvalidateRange((INTPTR)BufferPtr, InvalidateLen);
	usb_ring_push_bytes(BufferPtr, BufferLen);
	XUsbPs_EpBufferRelease(Handle);
}

void usb_ep1_in_event_handler(void *CallBackRef, u8 EpNum, u8 EventType, void *Data)
{
	(void)CallBackRef;
	(void)EpNum;
	(void)Data;

	if (EventType == XUSBPS_EP_EVENT_DATA_TX) {
		debug_add_u32(&g_debug_usb_ep1_in_count, 1U);
		debug_store_u32(&g_debug_usb_last_event_type, 0x400U | EventType);
		g_usb.tx_busy = false;
	}
}

int usb_setup_interrupts(XUsbPs_Config *config)
{
	if (config == nullptr) {
		return XST_FAILURE;
	}

	if (!g_usb_gic_ready) {
#ifdef SDT
		XScuGic_Config *gic_config = XScuGic_LookupConfig(XGet_BaseAddr(config->IntrParent));
#else
		XScuGic_Config *gic_config = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
#endif
		if (gic_config == nullptr) {
			return XST_FAILURE;
		}

		int status = XScuGic_CfgInitialize(&g_usb_gic, gic_config, 0);
		if (status != XST_SUCCESS) {
			return status;
		}

		Xil_ExceptionInit();
		Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
			(Xil_ExceptionHandler)XScuGic_InterruptHandler, &g_usb_gic);
		Xil_ExceptionEnable();
		g_usb_gic_ready = true;
	}

#ifdef SDT
	const u16 intr_num = static_cast<u16>(XGet_IntrId(config->IntrId) + XGet_IntrOffset(config->IntrId));
	const u8 trigger = ((XGet_TriggerType(config->IntrId) == 1U)
		|| (XGet_TriggerType(config->IntrId) == 2U))
		? XINTR_IS_EDGE_TRIGGERED
		: XINTR_IS_LEVEL_TRIGGERED;
#else
	const u16 intr_num = XPAR_XUSBPS_0_INTR;
	const u8 trigger = 1U; // GIC active-high level, as required by PS USB.
#endif

	XScuGic_SetPriorityTriggerType(&g_usb_gic, intr_num,
		0xA0U, trigger);

	int status = XScuGic_Connect(&g_usb_gic, intr_num,
		(Xil_ExceptionHandler)XUsbPs_IntrHandler, &g_usb.instance);
	if (status != XST_SUCCESS) {
		return status;
	}

	XScuGic_Enable(&g_usb_gic, intr_num);
	return XST_SUCCESS;
}

int usb_phy_reset_pulse(void)
{
	XGpioPs gpio;
#ifdef SDT
	XGpioPs_Config *config = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_BASEADDR);
#else
	XGpioPs_Config *config = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_DEVICE_ID);
#endif
	if (config == nullptr) {
		return XST_FAILURE;
	}

	int status = XGpioPs_CfgInitialize(&gpio, config, config->BaseAddr);
	if (status != XST_SUCCESS) {
		return status;
	}

	XGpioPs_SetDirectionPin(&gpio, kUsbPhyResetPin, 1U);
	XGpioPs_SetOutputEnablePin(&gpio, kUsbPhyResetPin, 1U);
	XGpioPs_WritePin(&gpio, kUsbPhyResetPin, 0U);
	usleep(20000);
	XGpioPs_WritePin(&gpio, kUsbPhyResetPin, 1U);
	usleep(20000);
	return XST_SUCCESS;
}
} // namespace

int usb_transport_open_stream(void)
{
	XUsbPs_Config *config;
	XUsbPs_DeviceConfig device_config = {};
	int status;

	status = usb_phy_reset_pulse();
	if (status != XST_SUCCESS) {
		xil_printf("usb phy reset fail: %d\r\n", status);
		debug_store_u32(&g_debug_usb_open_error, 0x0FU);
		return status;
	}

	debug_store_u32(&g_debug_usb_open_stage, 1U);
	debug_store_u32(&g_debug_usb_open_error, 0U);
#ifdef SDT
	config = XUsbPs_LookupConfig((u32)XPAR_XUSBPS_0_BASEADDR);
#else
	config = XUsbPs_LookupConfig(XPAR_XUSBPS_0_DEVICE_ID);
#endif
	if (config == nullptr) {
		debug_store_u32(&g_debug_usb_open_error, 0x10U);
		return XST_FAILURE;
	}

	status = XUsbPs_CfgInitialize(&g_usb.instance, config, config->BaseAddress);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x11U);
		return status;
	}

	debug_store_u32(&g_debug_usb_open_stage, 2U);
	status = usb_setup_interrupts(config);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x12U);
		return status;
	}

	debug_store_u32(&g_debug_usb_open_stage, 3U);
	std::memset(g_dma_memory, 0, sizeof(g_dma_memory));
	Xil_DCacheFlushRange((INTPTR)g_dma_memory, sizeof(g_dma_memory));
	g_usb.instance.UserDataPtr = &g_usb.ch9_local;
	g_usb.ch9_local.CurrentConfig = 0;
	g_usb.rx_ring.head = 0;
	g_usb.rx_ring.tail = 0;
	g_usb.tx_busy = false;
	usb_ch9_reset_configured();
	debug_store_u32(&g_debug_usb_ep0_setup_count, 0U);
	debug_store_u32(&g_debug_usb_ep0_rx_count, 0U);
	debug_store_u32(&g_debug_usb_ep1_out_count, 0U);
	debug_store_u32(&g_debug_usb_ep1_out_bytes, 0U);
	debug_store_u32(&g_debug_usb_ep1_in_count, 0U);
	debug_store_u32(&g_debug_usb_ep1_in_bytes, 0U);
	debug_store_u32(&g_debug_usb_last_event_type, 0U);
	debug_store_u32(&g_debug_usb_last_status, 0U);

	device_config.NumEndpoints = 2;
	device_config.DMAMemPhys = static_cast<u32>(reinterpret_cast<UINTPTR>(g_dma_memory));
	device_config.EpCfg[0].Out.Type = XUSBPS_EP_TYPE_CONTROL;
	device_config.EpCfg[0].Out.NumBufs = 2;
	device_config.EpCfg[0].Out.BufSize = 64;
	device_config.EpCfg[0].Out.MaxPacketSize = 64;
	device_config.EpCfg[0].In.Type = XUSBPS_EP_TYPE_CONTROL;
	device_config.EpCfg[0].In.NumBufs = 2;
	device_config.EpCfg[0].In.MaxPacketSize = 64;
	device_config.EpCfg[1].Out.Type = XUSBPS_EP_TYPE_BULK;
	device_config.EpCfg[1].Out.NumBufs = 16;
	device_config.EpCfg[1].Out.BufSize = 64;
	device_config.EpCfg[1].Out.MaxPacketSize = 64;
	device_config.EpCfg[1].In.Type = XUSBPS_EP_TYPE_BULK;
	device_config.EpCfg[1].In.NumBufs = 16;
	device_config.EpCfg[1].In.MaxPacketSize = 64;

	status = XUsbPs_ConfigureDevice(&g_usb.instance, &device_config);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x13U);
		return status;
	}

	debug_store_u32(&g_debug_usb_open_stage, 4U);
	status = XUsbPs_IntrSetHandler(&g_usb.instance, usb_intr_handler, nullptr,
		XUSBPS_IXR_UE_MASK | XUSBPS_IXR_UR_MASK);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x14U);
		return status;
	}

	status = XUsbPs_EpSetHandler(&g_usb.instance, 0, XUSBPS_EP_DIRECTION_OUT,
		usb_ep0_event_handler, &g_usb.instance);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x15U);
		return status;
	}

	status = XUsbPs_EpSetHandler(&g_usb.instance, 1, XUSBPS_EP_DIRECTION_OUT,
		usb_ep1_out_event_handler, &g_usb.instance);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x16U);
		return status;
	}

	status = XUsbPs_EpSetHandler(&g_usb.instance, 1, XUSBPS_EP_DIRECTION_IN,
		usb_ep1_in_event_handler, &g_usb.instance);
	if (status != XST_SUCCESS) {
		debug_store_u32(&g_debug_usb_open_error, 0x17U);
		return status;
	}

	debug_store_u32(&g_debug_usb_open_stage, 5U);
	XUsbPs_IntrEnable(&g_usb.instance, XUSBPS_IXR_UR_MASK | XUSBPS_IXR_UI_MASK);
	XUsbPs_Start(&g_usb.instance);
	XUsbPs_ClrBits(&g_usb.instance, XUSBPS_OTGCSR_OFFSET, XUSBPS_OTGSC_OT_MASK);
	usleep(20000);
	XUsbPs_SetBits(&g_usb.instance, XUSBPS_OTGCSR_OFFSET, XUSBPS_OTGSC_OT_MASK);
	usleep(20000);
	g_usb.initialized = true;
	g_usb.error = 0;
	debug_store_u32(&g_debug_usb_open_stage, 6U);
	return XST_SUCCESS;
}

void usb_transport_close_stream(void)
{
	if (!g_usb.initialized) {
		return;
	}

#ifdef SDT
	const u16 intr_num = static_cast<u16>(XGet_IntrId(g_usb.instance.Config.IntrId)
		+ XGet_IntrOffset(g_usb.instance.Config.IntrId));
#else
	const u16 intr_num = XPAR_XUSBPS_0_INTR;
#endif
	if (g_usb_gic_ready) {
		XScuGic_Disable(&g_usb_gic, intr_num);
		XScuGic_Disconnect(&g_usb_gic, intr_num);
	}

	XUsbPs_Stop(&g_usb.instance);
	XUsbPs_IntrDisable(&g_usb.instance, XUSBPS_IXR_ALL);
	g_usb.initialized = false;
}

bool usb_transport_read_byte(u8 *value)
{
	if (g_usb.error) return false;
	if (g_usb.rx_ring.head == g_usb.rx_ring.tail) {
		return false;
	}

	*value = g_usb.rx_ring.data[g_usb.rx_ring.head];
	g_usb.rx_ring.head = (g_usb.rx_ring.head + 1) % kUsbRxRingSize;
	return true;
}

void usb_transport_write(const u8 *data, size_t length)
{
	size_t offset = 0;
	u32 wait_loops;

	if ((!g_usb.initialized) || (data == nullptr) || (length == 0)) {
		return;
	}

	while (!usb_ch9_is_configured()) {
		usleep(1000);
	}

	while (offset < length) {
		size_t chunk = length - offset;
		if (chunk > sizeof(g_tx_buffer)) {
			chunk = sizeof(g_tx_buffer);
		}

		while (g_usb.tx_busy) {
			usleep(100);
		}

		std::memcpy(g_tx_buffer, data + offset, chunk);
		Xil_DCacheFlushRange((INTPTR)g_tx_buffer, chunk);
		debug_add_u32(&g_debug_usb_ep1_in_bytes, (u32)chunk);
		g_usb.tx_busy = true;
		if (XUsbPs_EpBufferSend(&g_usb.instance, 1, g_tx_buffer, (u32)chunk) != XST_SUCCESS) {
			g_usb.tx_busy = false;
			g_usb.error = 2;
			return;
		}

		wait_loops = 0;
		while (g_usb.tx_busy && wait_loops < 50000U) {
			usleep(100);
			++wait_loops;
		}

		if (g_usb.tx_busy) {
			g_usb.tx_busy = false;
			g_usb.error = 3;
			return;
		}

		offset += chunk;
	}
}

const TransportCapabilities &usb_transport_get_capabilities(void)
{
	return kCaps;
}

int usb_transport_error(void) { return g_usb.error; }
