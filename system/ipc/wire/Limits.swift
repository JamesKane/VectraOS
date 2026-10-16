// SPDX-License-Identifier: BSD-3-Clause

/// The most bytes one message may have, header included (Zircon's channel
/// limit, which the transport enforces as well).
public let maxMessageBytes = 65_536

/// The most handles one message may carry.
public let maxMessageHandles = 64
