// SPDX-License-Identifier: LGPL-3.0-or-later
#include "opl_stream.h"

#include <cstddef>
#include <cstring>

#include "opl_hw.h"
#include "timer_ps.h"
#include "transport.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xstatus.h"

namespace {

constexpr u8 kSync0 = 0x4F;
constexpr u8 kSync1 = 0x50;
constexpr u8 kTypeHello = 0x01;
constexpr u8 kTypeEnterStream = 0x02;
constexpr u8 kTypeOplEvent = 0x03;
constexpr u8 kTypeStop = 0x04;
constexpr u8 kTypeResetOpl = 0x05;
constexpr u8 kTypeStatus = 0x06;
constexpr u8 kTypeExitStream = 0x07;
constexpr u8 kTypeUploadBegin = 0x08;
constexpr u8 kTypeUploadChunk = 0x09;
constexpr u8 kTypeUploadEnd = 0x0A;
constexpr u8 kTypePlayBuffered = 0x0B;
constexpr u8 kTypePauseBuffered = 0x0C;
constexpr u8 kTypeResumeBuffered = 0x0D;
constexpr u8 kTypeSampleBegin = 0x0E;
constexpr u8 kTypeSampleChunk = 0x0F;
constexpr u8 kTypeSampleEnd = 0x10;
constexpr u8 kTypeSampleRead = 0x11;
constexpr u8 kTypeError = 0x7F;
constexpr u8 kResponseMask = 0x80;
constexpr u8 kVersionMajor = 2;
constexpr u8 kVersionMinor = 1;
constexpr size_t kQueueCapacity = 2048;
constexpr size_t kSongBufferSize = 8 * 1024 * 1024;

struct QueuedWrite {
	u32 delay_us;
	u8 bank;
	u8 reg;
	u8 value;
};

struct QueueState {
	QueuedWrite items[kQueueCapacity];
	u16 head = 0;
	u16 tail = 0;
	u16 count = 0;
};

struct BufferedEvent {
	u32 delay_us;
	u8 count;
	const u8 *writes;
	u32 size_bytes;
};

struct FrameParser {
	enum State {
		WAIT_SYNC0,
		WAIT_SYNC1,
		READ_TYPE,
		READ_LEN0,
		READ_LEN1,
		READ_PAYLOAD,
		READ_CHECKSUM
	} state = WAIT_SYNC0;

	u8 type = 0;
	u16 length = 0;
	u16 payload_index = 0;
	u8 payload[1024];
};

struct BufferedSongState {
	u8 data[kSongBufferSize];
	u32 expected_size = 0;
	u32 loaded_size = 0;
	u32 play_offset = 0;
	bool upload_active = false;
	bool loaded_ready = false;
	bool playback_active = false;
	bool playback_paused = false;
	bool event_armed = false;
	u64 next_event_ticks = 0;
	u64 remaining_event_ticks = 0;
	BufferedEvent current_event = {};
};

QueueState g_queue = {};
bool g_stream_playback_armed = false;
u64 g_stream_next_deadline_ticks = 0;
BufferedSongState g_song = {};
u16 g_frame_payload_max = 1024;
u16 g_upload_chunk_bytes = 1024;
u32 g_transport_flags = 0;
u32 g_late_writes = 0;
u64 g_max_late_ticks = 0;
u64 g_serialized_ready_ticks = 0;
u32 g_source_completion_late_writes = 0;
u64 g_max_source_completion_late_ticks = 0;
u64 g_pause_start_ticks = 0;
bool g_sample_upload = false;

} // namespace

extern "C" volatile u32 g_debug_buffered_stage = 0;
extern "C" volatile u32 g_debug_buffered_play_offset = 0;
extern "C" volatile u32 g_debug_buffered_events_done = 0;
extern "C" volatile u64 g_debug_buffered_start_ticks = 0;
extern "C" volatile u64 g_debug_buffered_end_ticks = 0;
extern "C" volatile u32 g_debug_jtag_play_request = 0;
extern "C" volatile u32 g_debug_jtag_play_result = 0;

namespace {

u64 now_ticks() { return TimerNowTicks(); }
u64 microseconds_to_ticks(u32 delay_us) { return TimerMicrosecondsToTicks(delay_us); }

void store_u32(u8 *out, u32 value)
{
    for (u32 i = 0; i < 4; ++i) out[i] = static_cast<u8>(value >> (i * 8));
}

u32 load_u32(const u8 *in)
{
    return static_cast<u32>(in[0]) | (static_cast<u32>(in[1]) << 8) |
        (static_cast<u32>(in[2]) << 16) | (static_cast<u32>(in[3]) << 24);
}

bool execute_write(u8 bank, u8 reg, u8 value, u64 source_deadline)
{
    const u64 planned_start = source_deadline > g_serialized_ready_ticks ?
        source_deadline : g_serialized_ready_ticks;
    while (now_ticks() < planned_start) TimerDelay(1);
    const u64 started = now_ticks();
    if (started > planned_start) {
        ++g_late_writes;
        const u64 late = started - planned_start;
        if (late > g_max_late_ticks) g_max_late_ticks = late;
    }
    // Match the conservative Phase 6 chip-bus expansion: 512/1248 half ticks
    // at 16 MHz. These waits supplement the board's actual native handshake.
    g_serialized_ready_ticks = planned_start + microseconds_to_ticks(bank == 0 && reg == 0x10 ? 78 : 32);
    if (!opl_write_reg(reg, value, bank)) return false;
    const u64 completed = now_ticks();
    if (completed > source_deadline) {
        ++g_source_completion_late_writes;
        const u64 late = completed - source_deadline;
        if (late > g_max_source_completion_late_ticks) g_max_source_completion_late_ticks = late;
    }
    return true;
}

u8 calc_checksum(u8 type, u16 length, const u8 *payload)
{
	u32 sum = type;
	sum += static_cast<u8>(length & 0xFF);
	sum += static_cast<u8>((length >> 8) & 0xFF);
	for (u16 i = 0; i < length; ++i) {
		sum += payload[i];
	}
	return static_cast<u8>(sum & 0xFF);
}

void send_frame(u8 type, const u8 *payload, u16 length)
{
	u8 frame[5 + 1024 + 1];
	frame[0] = kSync0;
	frame[1] = kSync1;
	frame[2] = type;
	frame[3] = static_cast<u8>(length & 0xFF);
	frame[4] = static_cast<u8>((length >> 8) & 0xFF);
	if (length > 0) {
		std::memcpy(&frame[5], payload, length);
	}
	frame[5 + length] = calc_checksum(type, length, payload);
	transport_write(frame, static_cast<size_t>(length) + 6U);
}

void send_ok(u8 request_type)
{
	send_frame(static_cast<u8>(request_type | kResponseMask), nullptr, 0);
}

void send_error(u8 code)
{
	send_frame(kTypeError, &code, 1);
}

void send_hello()
{
	u8 payload[24];
	const TransportCapabilities &caps = transport_get_capabilities();
	payload[0] = kVersionMajor;
	payload[1] = kVersionMinor;
	payload[2] = static_cast<u8>(kQueueCapacity & 0xFF);
	payload[3] = static_cast<u8>((kQueueCapacity >> 8) & 0xFF);
	payload[4] = static_cast<u8>(caps.stream_hint & 0xFF);
	payload[5] = static_cast<u8>((caps.stream_hint >> 8) & 0xFF);
	payload[6] = static_cast<u8>((caps.stream_hint >> 16) & 0xFF);
	payload[7] = static_cast<u8>((caps.stream_hint >> 24) & 0xFF);
	payload[8] = static_cast<u8>(caps.cli_hint & 0xFF);
	payload[9] = static_cast<u8>((caps.cli_hint >> 8) & 0xFF);
	payload[10] = static_cast<u8>((caps.cli_hint >> 16) & 0xFF);
	payload[11] = static_cast<u8>((caps.cli_hint >> 24) & 0xFF);
	payload[12] = static_cast<u8>(kSongBufferSize & 0xFF);
	payload[13] = static_cast<u8>((kSongBufferSize >> 8) & 0xFF);
	payload[14] = static_cast<u8>((kSongBufferSize >> 16) & 0xFF);
	payload[15] = static_cast<u8>((kSongBufferSize >> 24) & 0xFF);
	payload[16] = static_cast<u8>(caps.max_frame_payload & 0xFF);
	payload[17] = static_cast<u8>((caps.max_frame_payload >> 8) & 0xFF);
	payload[18] = static_cast<u8>(caps.upload_chunk_bytes & 0xFF);
	payload[19] = static_cast<u8>((caps.upload_chunk_bytes >> 8) & 0xFF);
	payload[20] = static_cast<u8>(caps.transport_flags & 0xFF);
	payload[21] = static_cast<u8>((caps.transport_flags >> 8) & 0xFF);
	payload[22] = static_cast<u8>((caps.transport_flags >> 16) & 0xFF);
	payload[23] = static_cast<u8>((caps.transport_flags >> 24) & 0xFF);
	send_frame(static_cast<u8>(kTypeHello | kResponseMask), payload, sizeof(payload));
}

bool queue_push(u32 delay_us, u8 bank, u8 reg, u8 value)
{
	if (g_queue.count >= kQueueCapacity) {
		return false;
	}

	g_queue.items[g_queue.tail].delay_us = delay_us;
	g_queue.items[g_queue.tail].bank = bank;
	g_queue.items[g_queue.tail].reg = reg;
	g_queue.items[g_queue.tail].value = value;
	g_queue.tail = static_cast<u16>((g_queue.tail + 1) % kQueueCapacity);
	++g_queue.count;
	return true;
}

bool queue_peek(QueuedWrite *item)
{
	if (g_queue.count == 0) {
		return false;
	}

	*item = g_queue.items[g_queue.head];
	return true;
}

bool queue_pop(QueuedWrite *item)
{
	if (!queue_peek(item)) {
		return false;
	}

	g_queue.head = static_cast<u16>((g_queue.head + 1) % kQueueCapacity);
	--g_queue.count;
	return true;
}

void queue_clear()
{
	g_queue.head = 0;
	g_queue.tail = 0;
	g_queue.count = 0;
	g_stream_playback_armed = false;
	g_stream_next_deadline_ticks = 0;
}

void buffered_reset_metadata()
{
	g_song.expected_size = 0;
	g_song.loaded_size = 0;
	g_song.play_offset = 0;
	g_song.upload_active = false;
	g_song.loaded_ready = false;
	g_song.playback_active = false;
	g_song.playback_paused = false;
	g_song.event_armed = false;
	g_song.next_event_ticks = 0;
	g_song.remaining_event_ticks = 0;
	g_song.current_event = {};
}

void buffered_stop_playback()
{
	g_song.play_offset = 0;
	g_song.playback_active = false;
	g_song.playback_paused = false;
	g_song.event_armed = false;
	g_song.next_event_ticks = 0;
	g_song.remaining_event_ticks = 0;
	g_song.current_event = {};
	g_debug_buffered_play_offset = 0;
}

void stop_all_playback()
{
	queue_clear();
	buffered_stop_playback();
}

bool parse_buffered_event(u32 offset, BufferedEvent *event)
{
	if (offset + 5 > g_song.loaded_size) {
		return false;
	}

	const u8 *data = &g_song.data[offset];
	event->delay_us = static_cast<u32>(data[0])
		| (static_cast<u32>(data[1]) << 8)
		| (static_cast<u32>(data[2]) << 16)
		| (static_cast<u32>(data[3]) << 24);
	event->count = data[4];
	if (event->count == 0) {
		return false;
	}

	event->size_bytes = static_cast<u32>(5 + event->count * 3);
	if (offset + event->size_bytes > g_song.loaded_size) {
		return false;
	}

	event->writes = data + 5;
    for (u32 i = 0; i < event->count; ++i) {
        if (event->writes[i * 3] > 1) return false;
    }
	return true;
}

bool validate_buffered_song()
{
	u32 offset = 0;
	while (offset < g_song.loaded_size) {
		BufferedEvent event;
		if (!parse_buffered_event(offset, &event)) {
			return false;
		}
		offset += event.size_bytes;
	}
	return offset == g_song.loaded_size;
}

void send_status()
{
	u8 payload[21];
	u16 free_slots = static_cast<u16>(kQueueCapacity - g_queue.count);
	bool playing = g_stream_playback_armed || g_queue.count != 0 || g_song.playback_active;
	payload[0] = static_cast<u8>(free_slots & 0xFF);
	payload[1] = static_cast<u8>((free_slots >> 8) & 0xFF);
	payload[2] = static_cast<u8>(g_queue.count & 0xFF);
	payload[3] = static_cast<u8>((g_queue.count >> 8) & 0xFF);
	payload[4] = static_cast<u8>((playing ? 1 : 0) | (g_song.playback_paused ? 2 : 0));
    store_u32(payload + 5, opl_status());
    store_u32(payload + 9, g_late_writes);
    const u64 late_us = TimerTicksToMicroseconds(g_max_late_ticks);
    store_u32(payload + 13, static_cast<u32>(late_us > 0xFFFFFFFFULL ? 0xFFFFFFFFULL : late_us));
    store_u32(payload + 17, opl_sample_loaded());
	send_frame(static_cast<u8>(kTypeStatus | kResponseMask), payload, sizeof(payload));
}

void service_stream_playback()
{
	if (!g_stream_playback_armed) {
		QueuedWrite first;
		if (!queue_peek(&first)) {
			return;
		}
		g_stream_next_deadline_ticks = now_ticks() + microseconds_to_ticks(first.delay_us);
		g_stream_playback_armed = true;
	}

	u64 current_ticks = now_ticks();
	while (g_stream_playback_armed && current_ticks >= g_stream_next_deadline_ticks) {
		QueuedWrite item;
		if (!queue_pop(&item)) {
			g_stream_playback_armed = false;
			return;
		}

        if (!execute_write(item.bank, item.reg, item.value, g_stream_next_deadline_ticks)) {
            stop_all_playback(); send_error(12); return;
        }

		QueuedWrite next;
		if (!queue_peek(&next)) {
			g_stream_playback_armed = false;
			return;
		}

		g_stream_next_deadline_ticks += microseconds_to_ticks(next.delay_us);
		current_ticks = now_ticks();
	}
}

void service_buffered_playback()
{
	if (!g_song.playback_active || g_song.playback_paused) {
		return;
	}

	if (g_song.play_offset >= g_song.loaded_size) {
		buffered_stop_playback();
		g_debug_buffered_stage = 2;
		XTime end_ticks = 0;
		XTime_GetTime(&end_ticks);
		g_debug_buffered_end_ticks = end_ticks;
		g_debug_buffered_stage = 3;
		return;
	}

	if (!g_song.event_armed) {
		if (!parse_buffered_event(g_song.play_offset, &g_song.current_event)) {
			buffered_stop_playback();
			g_debug_buffered_stage = 0xEE;
			return;
		}

		g_song.next_event_ticks += microseconds_to_ticks(g_song.current_event.delay_us);
		g_song.event_armed = true;
	}

	if (now_ticks() < g_song.next_event_ticks) {
		return;
	}

	for (u8 i = 0; i < g_song.current_event.count; ++i) {
		const u8 *write = g_song.current_event.writes + (i * 3);
        if (!execute_write(write[0], write[1], write[2], g_song.next_event_ticks)) {
            stop_all_playback(); send_error(12); return;
        }
	}

	g_song.play_offset += g_song.current_event.size_bytes;
	g_song.event_armed = false;
	g_debug_buffered_play_offset = g_song.play_offset;
	++g_debug_buffered_events_done;
}

bool enqueue_opl_event(const u8 *payload, u16 length)
{
	if (length < 5) {
		send_error(13);
		return false;
	}

	u32 delay_us = static_cast<u32>(payload[0])
		| (static_cast<u32>(payload[1]) << 8)
		| (static_cast<u32>(payload[2]) << 16)
		| (static_cast<u32>(payload[3]) << 24);
	u8 count = payload[4];
	if (count == 0 || length != static_cast<u16>(5 + count * 3)) {
		send_error(13);
		return false;
	}

	for (u32 i = 0; i < count; ++i) {
        if (payload[5 + i * 3] > 1) { send_error(13); return false; }
    }
    if (g_song.playback_active || g_song.upload_active || g_sample_upload) { send_error(14); return false; }
    if ((kQueueCapacity - g_queue.count) < count) {
		send_error(2);
		send_status();
		return true;
	}

	for (u8 i = 0; i < count; ++i) {
		u8 bank = payload[5 + i * 3 + 0];
		u8 reg = payload[5 + i * 3 + 1];
		u8 value = payload[5 + i * 3 + 2];
		if (!queue_push(i == 0 ? delay_us : 0, bank, reg, value)) {
			send_error(2);
			return true;
		}
	}

	return true;
}

bool begin_upload(const u8 *payload, u16 length)
{
	if (g_sample_upload) { send_error(14); return false; }
	if (length != 4) {
		send_error(5);
		return false;
	}

	u32 expected_size = static_cast<u32>(payload[0])
		| (static_cast<u32>(payload[1]) << 8)
		| (static_cast<u32>(payload[2]) << 16)
		| (static_cast<u32>(payload[3]) << 24);
	if (expected_size == 0 || expected_size > kSongBufferSize) {
		send_error(6);
		return false;
	}

	stop_all_playback();
	if (!opl_set_running(false)) { send_error(12); return false; }
	buffered_reset_metadata();
	g_song.expected_size = expected_size;
	g_song.upload_active = true;
	send_ok(kTypeUploadBegin);
	return true;
}

bool upload_chunk(const u8 *payload, u16 length)
{
	if (!g_song.upload_active) {
		send_error(7);
		return false;
	}

	if (g_song.loaded_size + length > g_song.expected_size) {
		send_error(8);
		return false;
	}

	std::memcpy(&g_song.data[g_song.loaded_size], payload, length);
	g_song.loaded_size += length;
	send_ok(kTypeUploadChunk);
	return true;
}

bool end_upload()
{
	if (!g_song.upload_active) {
		send_error(7);
		return false;
	}

	if (g_song.loaded_size != g_song.expected_size) {
		send_error(9);
		return false;
	}

	if (!validate_buffered_song()) {
		buffered_reset_metadata();
		send_error(10);
		return false;
	}

	g_song.upload_active = false;
	g_song.loaded_ready = true;
	send_ok(kTypeUploadEnd);
	return true;
}

bool start_buffered_playback()
{
	if (g_sample_upload || !g_song.loaded_ready || g_song.loaded_size == 0) {
		send_error(11);
		return false;
	}

	queue_clear();
	buffered_stop_playback();
	g_late_writes = 0; g_max_late_ticks = 0;
	g_source_completion_late_writes = 0; g_max_source_completion_late_ticks = 0;
	if (!opl_reset_core()) { send_error(12); return false; }
	g_song.play_offset = 0;
	g_song.playback_active = true;
	g_debug_buffered_stage = 1;
	g_debug_buffered_play_offset = 0;
	g_debug_buffered_events_done = 0;
	XTime start_ticks = 0;
	XTime_GetTime(&start_ticks);
	g_debug_buffered_start_ticks = start_ticks;
	g_debug_buffered_end_ticks = 0;
	g_song.playback_paused = false;
	g_song.event_armed = false;
	g_song.next_event_ticks = start_ticks;
	g_serialized_ready_ticks = start_ticks;
	g_song.remaining_event_ticks = 0;
	g_song.current_event = {};
	send_ok(kTypePlayBuffered);
	return true;
}

bool play_buffered_song()
{
	return start_buffered_playback();
}

bool pause_buffered_song()
{
    if (g_song.playback_active && !g_song.playback_paused) {
        if (!opl_set_running(false, &g_pause_start_ticks)) { send_error(12); return false; }
        g_song.playback_paused = true;
    }
    send_ok(kTypePauseBuffered);
    return true;
}

bool resume_buffered_song()
{
    if (g_sample_upload) { send_error(14); return false; }
    if (!opl_set_running(true)) { send_error(12); return false; }
    if (g_song.playback_active && g_song.playback_paused) {
        // Shift every subsequent absolute deadline by the same pause duration.
        const u64 paused_ticks = now_ticks() - g_pause_start_ticks;
        g_song.next_event_ticks += paused_ticks;
        g_serialized_ready_ticks += paused_ticks;
        g_song.playback_paused = false;
    }
    send_ok(kTypeResumeBuffered);
    return true;
}

bool sample_begin(const u8 *payload, u16 length)
{
    if (length != 9) { send_error(5); return false; }
    stop_all_playback();
    if (!opl_sample_begin(load_u32(payload), load_u32(payload + 4), payload[8])) {
        send_error(15); return false;
    }
    g_sample_upload = true;
    send_ok(kTypeSampleBegin);
    return true;
}

bool sample_chunk(const u8 *payload, u16 length)
{
    if (!g_sample_upload || !opl_sample_write(payload, length)) {
        send_error(8); return false;
    }
    send_ok(kTypeSampleChunk);
    return true;
}

bool sample_end()
{
    if (!g_sample_upload || !opl_sample_end()) { send_error(9); return false; }
    g_sample_upload = false;
    send_ok(kTypeSampleEnd);
    return true;
}

bool sample_read(const u8 *payload, u16 length)
{
    if (length != 6 || g_sample_upload || g_queue.count ||
        (g_song.playback_active && !g_song.playback_paused)) {
        send_error(14); return false;
    }
    const u32 count = payload[4] | (static_cast<u32>(payload[5]) << 8);
    u8 data[1024];
    if (count == 0 || count > g_frame_payload_max ||
        !opl_sample_read(load_u32(payload), data, count)) {
        send_error(15); return false;
    }
    send_frame(kTypeSampleRead | kResponseMask, data, count);
    return true;
}

bool handle_frame(u8 type, const u8 *payload, u16 length, bool *keep_running)
{
	switch (type) {
	case kTypeHello:
		send_hello();
		return true;
	case kTypeEnterStream:
		stop_all_playback();
		g_sample_upload = false;
		if (!opl_reset_core()) { send_error(12); return false; }
		send_ok(kTypeEnterStream);
		send_status();
		return true;
	case kTypeOplEvent:
		return enqueue_opl_event(payload, length);
	case kTypeStop:
		stop_all_playback();
		g_sample_upload = false;
		if (!opl_reset_core()) { send_error(12); return false; }
		send_ok(kTypeStop);
		send_status();
		return true;
	case kTypeResetOpl:
		stop_all_playback();
		g_sample_upload = false;
		if (!opl_reset_core()) { send_error(12); return false; }
		send_ok(kTypeResetOpl);
		return true;
	case kTypeStatus:
		send_status();
		return true;
	case kTypeExitStream:
		stop_all_playback();
		g_sample_upload = false;
		if (!opl_reset_core()) { send_error(12); return false; }
		send_ok(kTypeExitStream);
		*keep_running = false;
		return true;
	case kTypeUploadBegin:
		return begin_upload(payload, length);
	case kTypeUploadChunk:
		return upload_chunk(payload, length);
	case kTypeUploadEnd:
		return end_upload();
	case kTypePlayBuffered:
		return play_buffered_song();
	case kTypePauseBuffered:
		return pause_buffered_song();
	case kTypeResumeBuffered:
        return resume_buffered_song();
    case kTypeSampleBegin: return sample_begin(payload, length);
    case kTypeSampleChunk: return sample_chunk(payload, length);
    case kTypeSampleEnd: return sample_end();
    case kTypeSampleRead: return sample_read(payload, length);
	default:
		send_error(1);
		return false;
	}
}

bool feed_parser(FrameParser *parser, u8 byte, bool *keep_running)
{
	switch (parser->state) {
	case FrameParser::WAIT_SYNC0:
		if (byte == kSync0) {
			parser->state = FrameParser::WAIT_SYNC1;
		}
		break;
	case FrameParser::WAIT_SYNC1:
		if (byte == kSync1) {
			parser->state = FrameParser::READ_TYPE;
		} else if (byte != kSync0) {
			parser->state = FrameParser::WAIT_SYNC0;
		}
		break;
	case FrameParser::READ_TYPE:
		parser->type = byte;
		parser->state = FrameParser::READ_LEN0;
		break;
	case FrameParser::READ_LEN0:
		parser->length = byte;
		parser->state = FrameParser::READ_LEN1;
		break;
	case FrameParser::READ_LEN1:
		parser->length |= static_cast<u16>(byte) << 8;
		parser->payload_index = 0;
		if (parser->length > g_frame_payload_max) {
			parser->state = FrameParser::WAIT_SYNC0;
			send_error(3);
			break;
		}
		parser->state = parser->length == 0 ? FrameParser::READ_CHECKSUM : FrameParser::READ_PAYLOAD;
		break;
	case FrameParser::READ_PAYLOAD:
		parser->payload[parser->payload_index++] = byte;
		if (parser->payload_index >= parser->length) {
			parser->state = FrameParser::READ_CHECKSUM;
		}
		break;
	case FrameParser::READ_CHECKSUM: {
		u8 expected = calc_checksum(parser->type, parser->length, parser->payload);
		if (expected == byte) {
			handle_frame(parser->type, parser->payload, parser->length, keep_running);
		} else {
			send_error(4);
		}
		parser->state = FrameParser::WAIT_SYNC0;
		break;
	}
	}

	return true;
}

} // namespace

int stream_session(void)
{
	if (transport_open_stream() != XST_SUCCESS) {
		xil_printf("Transport init failed.\r\n");
		return -1;
	}

	const TransportCapabilities &caps = transport_get_capabilities();
	g_frame_payload_max = caps.max_frame_payload;
	g_upload_chunk_bytes = caps.upload_chunk_bytes;
	g_transport_flags = caps.transport_flags;

	queue_clear();
	buffered_reset_metadata();
	if (!opl_reset_core()) { transport_close_stream(); return -2; }
	if (caps.send_hello_on_open) {
		send_hello();
	}

	FrameParser parser;
	bool keep_running = true;
	while (keep_running) {
		bool did_work = false;
		if (transport_error()) {
			stop_all_playback();
			opl_set_running(false);
			transport_close_stream();
			return -3;
		}

		if (g_debug_jtag_play_request != 0U) {
			g_debug_jtag_play_request = 0;
			g_debug_jtag_play_result = start_buffered_playback() ? 1U : 2U;
			did_work = true;
		}

		u8 byte = 0;
		while (transport_read_byte(&byte)) {
			feed_parser(&parser, byte, &keep_running);
			did_work = true;
		}

		service_stream_playback();
		service_buffered_playback();
		if (g_stream_playback_armed || g_queue.count != 0 || g_song.playback_active) {
			did_work = true;
		}

		if (!did_work) {
			TimerDelay(50);
		}
	}

	transport_close_stream();
	return 0;
}
