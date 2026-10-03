// drv-uart-pl011: the arm PL011 UART as the console (docs/01 §7, 04 §5 M2).
//
// svcd gives it the UART's registers (a physical VMO) and its IRQ, minted
// from the root Resource by its manifest (boot/svc/cons.ndb), and the listen
// channel it posts as /srv/cons. It serves vx-driver's console over them; once
// it has the registers, the kernel writes to the UART only to report a panic.
//
// The IRQ is a level-triggered SPI: the kernel masks it when it fires, and the
// driver clears the UART's interrupts before it acknowledges it.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/cons.c"

enum : uint32_t { // registers, as u32 indices
  DR = 0x00 / 4,
  FR = 0x18 / 4,
  LCR_H = 0x2c / 4,
  IMSC = 0x38 / 4,
  MIS = 0x40 / 4,
  ICR = 0x44 / 4,
};
enum : uint32_t {
  FR_RXFE = 1u << 4, // receive FIFO empty
  FR_TXFF = 1u << 5, // transmit FIFO full
  FR_TXFE = 1u << 7, // transmit FIFO empty
  INT_RX = 1u << 4,
  INT_TX = 1u << 5,
  INT_RT = 1u << 6, // receive timeout: bytes waiting below the FIFO level
  INT_ALL = 0x7ff,
};

static volatile uint32_t *regs;
static uint32_t imsc = INT_RX | INT_RT;
static vx_handle irq;
static vx_cons cons;
static p9_ring_server server;

static uint32_t tx_room(void *dev) {
  (void)dev;
  uint32_t fr = regs[FR];
  if (fr & FR_TXFE) return 16; // the FIFO holds 16
  return fr & FR_TXFF ? 0 : 1;
}

static void tx_byte(void *dev, uint8_t b) {
  (void)dev;
  regs[DR] = b;
}

static void tx_wanted(void *dev, bool on) {
  (void)dev;
  uint32_t want = on ? imsc | INT_TX : imsc & ~INT_TX;
  if (want != imsc) regs[IMSC] = imsc = want;
}

static void service(void) {
  regs[ICR] = regs[MIS];
  while (!(regs[FR] & FR_RXFE)) vx_cons_input(&cons, (uint8_t)regs[DR]);
  vx_cons_pump(&cons);
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->trigger != VX_TRIGGER_IRQ) return;
  service();
  vx_irq_ack(irq);
  vx_port_bind(server.port, irq, VX_TRIGGER_IRQ, P9_KEY_USER, 0);
}

const char *vx_main(void) {
  vx_handle mmio = vx_spawn_take("mmio");
  irq = vx_spawn_take("irq");
  server.listen = vx_spawn_take("listen");
  uint64_t at = 0;
  if (!mmio || !irq || !server.listen || vx_as_map(vx_self, mmio, 0, 4096, VX_MAP_WRITE, &at) != VX_OK) {
    vx_print(VX_STR("drv-uart-pl011: no registers, IRQ or listen channel\n"));
    return "no registers, IRQ or listen channel";
  }
  vx_handle_close(mmio); // the mapping keeps it
  regs = (volatile uint32_t *)at;

  regs[LCR_H] |= 1u << 4; // FEN: the FIFOs, which tx_room counts on (16 bytes when empty)
  regs[ICR] = INT_ALL;
  regs[IMSC] = imsc;
  vx_cons_print_here(&cons);
  cons = (vx_cons){.tx_room = tx_room, .tx_byte = tx_byte, .tx_wanted = tx_wanted};
  server.fs = vx_cons_fs(&cons);
  vx_cons_conns_for(&server);
  server.event = event;
  if (vx_port_create(0, &server.port) != VX_OK ||
      vx_port_bind(server.port, irq, VX_TRIGGER_IRQ, P9_KEY_USER, 0) != VX_OK) {
    vx_print(VX_STR("drv-uart-pl011: cannot wait for the IRQ\n"));
    return "cannot wait for the IRQ";
  }
  vx_irq_ack(irq);
  service();
  vx_print(VX_STR("drv-uart-pl011: serving /srv/cons\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
