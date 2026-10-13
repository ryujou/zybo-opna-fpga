#ifndef TRANSPORT_H_
#define TRANSPORT_H_

#include <cstddef>

#include "xstatus.h"
#include "xil_types.h"

enum class TransportKind : u8 {
	Uart = 1,
	Usb = 2,
};

struct TransportCapabilities {
	TransportKind kind;
	u32 cli_hint;
	u32 stream_hint;
	u16 max_frame_payload;
	u16 upload_chunk_bytes;
	u32 transport_flags;
	bool send_hello_on_open;
};

int transport_open_stream(void);
void transport_close_stream(void);
bool transport_read_byte(u8 *value);
void transport_write(const u8 *data, size_t length);
int transport_error(void);
const TransportCapabilities &transport_get_capabilities(void);

#endif
