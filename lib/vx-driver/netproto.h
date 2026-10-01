// The net class protocol (docs/01 §7.3): frames between a network driver
// and its one client, netd, over a ring session (lib/vx-ring/session.c) on
// the driver's post (/srv/ether0).
//
//   INFO   the completion says the MAC address (aux2, its six bytes from the
//          lowest) and the MTU (aux)
//   TX     sends the frame at [arena_off, arena_off + len) of the client's
//          arena (with VX_SQE_DREF); completes with its length, or a
//          negative status. The driver has copied the frame by then.
//   RX     offers slot `target` of the driver's arena (VX_NET_SLOTS of
//          VX_NET_SLOT bytes) for a frame; completes when one arrives, with
//          its length, and aux2 its offset in the driver's arena. The driver
//          writes nothing there again until the client offers that slot
//          again, so the client copies the frame out first.
//
// Frames are whole Ethernet frames, without the FCS. A frame that arrives
// while no slot is offered is dropped, as a full NIC would drop it.
//
// Every request is completed exactly once, so a client keeps no more of them
// outstanding (submitted, not yet completed, RX offers included) than the
// completion queue holds: a driver whose completion queue is full drops the
// client.

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t { VX_NET_CONNECT = 0x7465'6e63 }; // "cnet": the listen channel's one ordinal
enum : uint16_t { VX_NET_INFO = 1, VX_NET_TX = 2, VX_NET_RX = 3 };

static constexpr uint32_t VX_NET_SLOTS = 64;       // frames each side's arena holds
static constexpr uint32_t VX_NET_SLOT = 2048;      // bytes a slot holds: an MTU of 1500 and room to spare
static constexpr uint32_t VX_NET_MAX_FRAME = 1514; // 14 bytes of header, 1500 of payload

static const vx_ring_params VX_NET_PARAMS = {
    .sq_entries = VX_NET_SLOTS * 2, // offers and sends together
    .cq_entries = VX_NET_SLOTS * 2,
    .sqe_size = sizeof(vx_sqe),
    .cqe_size = sizeof(vx_cqe),
    .client_arena = (uint64_t)VX_NET_SLOTS * VX_NET_SLOT,
    .server_arena = (uint64_t)VX_NET_SLOTS * VX_NET_SLOT,
};
