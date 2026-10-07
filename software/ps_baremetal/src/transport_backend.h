#ifndef TRANSPORT_BACKEND_H_
#define TRANSPORT_BACKEND_H_

#include "transport.h"

int uart_transport_open_stream(void);
void uart_transport_close_stream(void);
bool uart_transport_read_byte(u8 *value);
void uart_transport_write(const u8 *data, size_t length);
const TransportCapabilities &uart_transport_get_capabilities(void);

int usb_transport_open_stream(void);
void usb_transport_close_stream(void);
bool usb_transport_read_byte(u8 *value);
void usb_transport_write(const u8 *data, size_t length);
const TransportCapabilities &usb_transport_get_capabilities(void);
int usb_transport_error(void);

#endif
