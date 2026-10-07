#include "transport_backend.h"

#include "xparameters.h"
#include "xuartps.h"

namespace {

constexpr u32 kCliBaud = 115200;
constexpr u32 kStreamBaud = 921600;
constexpr u16 kMaxFramePayload = 192;
constexpr u16 kUploadChunkBytes = 180;

const TransportCapabilities kCaps = {
	TransportKind::Uart,
	kCliBaud,
	kStreamBaud,
	kMaxFramePayload,
	kUploadChunkBytes,
	0,
	true,
};

XUartPs g_uart;
bool g_uart_ready = false;

} // namespace

int uart_transport_open_stream(void)
{
	if (!g_uart_ready) {
#ifdef SDT
		XUartPs_Config *config = XUartPs_LookupConfig(XPAR_XUARTPS_0_BASEADDR);
#else
		XUartPs_Config *config = XUartPs_LookupConfig(XPAR_XUARTPS_0_DEVICE_ID);
#endif
		if (config == nullptr) {
			return XST_FAILURE;
		}

		int status = XUartPs_CfgInitialize(&g_uart, config, config->BaseAddress);
		if (status != XST_SUCCESS) {
			return status;
		}

		XUartPs_SetOperMode(&g_uart, XUARTPS_OPER_MODE_NORMAL);
		g_uart_ready = true;
	}

	return XUartPs_SetBaudRate(&g_uart, kStreamBaud);
}

void uart_transport_close_stream(void)
{
	if (!g_uart_ready) {
		return;
	}

	(void)XUartPs_SetBaudRate(&g_uart, kCliBaud);
}

bool uart_transport_read_byte(u8 *value)
{
	return XUartPs_Recv(&g_uart, value, 1) == 1;
}

void uart_transport_write(const u8 *data, size_t length)
{
	if (length == 0) {
		return;
	}

	XUartPs_Send(&g_uart, const_cast<u8 *>(data), static_cast<u32>(length));
	while (XUartPs_IsSending(&g_uart) != 0) {
	}
}

const TransportCapabilities &uart_transport_get_capabilities(void)
{
	return kCaps;
}
