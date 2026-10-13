#include "transport.h"

#include "transport_backend.h"
#include "xil_printf.h"
#include "xstatus.h"

namespace {

enum class ActiveTransport {
	None,
	Uart,
	Usb,
};

ActiveTransport g_active_transport = ActiveTransport::None;

} // namespace

int transport_open_stream(void)
{
	const int usb_status = usb_transport_open_stream();
	if (usb_status == XST_SUCCESS) {
		g_active_transport = ActiveTransport::Usb;
		return XST_SUCCESS;
	}
	xil_printf("usb transport open fail: %d\r\n", usb_status);

	const int uart_status = uart_transport_open_stream();
	if (uart_status == XST_SUCCESS) {
		g_active_transport = ActiveTransport::Uart;
		return XST_SUCCESS;
	}
	xil_printf("uart transport open fail: %d\r\n", uart_status);

	g_active_transport = ActiveTransport::None;
	return XST_FAILURE;
}

void transport_close_stream(void)
{
	switch (g_active_transport) {
	case ActiveTransport::Usb:
		usb_transport_close_stream();
		break;
	case ActiveTransport::Uart:
		uart_transport_close_stream();
		break;
	case ActiveTransport::None:
	default:
		break;
	}

	g_active_transport = ActiveTransport::None;
}

bool transport_read_byte(u8 *value)
{
	switch (g_active_transport) {
	case ActiveTransport::Usb:
		return usb_transport_read_byte(value);
	case ActiveTransport::Uart:
		return uart_transport_read_byte(value);
	case ActiveTransport::None:
	default:
		return false;
	}
}

void transport_write(const u8 *data, size_t length)
{
	switch (g_active_transport) {
	case ActiveTransport::Usb:
		usb_transport_write(data, length);
		break;
	case ActiveTransport::Uart:
		uart_transport_write(data, length);
		break;
	case ActiveTransport::None:
	default:
		break;
	}
}

const TransportCapabilities &transport_get_capabilities(void)
{
	switch (g_active_transport) {
	case ActiveTransport::Usb:
		return usb_transport_get_capabilities();
	case ActiveTransport::Uart:
	case ActiveTransport::None:
	default:
		return uart_transport_get_capabilities();
	}
}

int transport_error(void)
{
	return g_active_transport == ActiveTransport::Usb ? usb_transport_error() : 0;
}
