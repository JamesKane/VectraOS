// drv-uart-16550: the PC serial port as the console (docs/01 §7, 04 §5 M2).
//
// svcd gives it the port's I/O range and IRQ, minted from the root Resource
// by its manifest (boot/svc/cons.ndb), and the listen channel it posts as
// /srv/cons. It serves vx-driver's console over them; once it has the ports,
// the kernel writes to the port only to report a panic.
//
// The IRQ is an ISA line, edge-triggered: the kernel never masks it, so each
// interrupt is handled until the IIR says nothing is pending, which lowers
// the line for the next edge.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/cons.c"

static inline void outb(uint16_t port, uint8_t value) {
  __asm__ volatile("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
  uint8_t value;
  __asm__ volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
  return value;
}

enum : uint16_t { RBR = 0, THR = 0, IER = 1, IIR = 2, FCR = 2, MCR = 4, LSR = 5, MSR = 6 };
enum : uint8_t {
  IER_RX = 0x01, // data received
  IER_TX = 0x02, // transmitter empty
  LSR_DATA = 0x01,
  LSR_THRE = 0x20,
  IIR_NONE = 0x01, // no interrupt pending
  FIFO_SIZE = 16,
};

static uint16_t base;
static uint8_t ier = IER_RX;
static vx_handle irq;
static vx_cons cons;
static p9_ring_server server;

static uint32_t tx_room(void *dev) {
  (void)dev;
  return inb(base + LSR) & LSR_THRE ? FIFO_SIZE : 0;
}

static void tx_byte(void *dev, uint8_t b) {
  (void)dev;
  outb(base + THR, b);
}

static void tx_wanted(void *dev, bool on) {
  (void)dev;
  uint8_t want = on ? IER_RX | IER_TX : IER_RX;
  if (want != ier) outb(base + IER, ier = want);
}

// Everything the port has pending, until the IIR says there is nothing left.
static void service(void) {
  for (int rounds = 0; rounds < 64 && !(inb(base + IIR) & IIR_NONE); rounds++) {
    while (inb(base + LSR) & LSR_DATA) vx_cons_input(&cons, inb(base + RBR));
    (void)inb(base + MSR); // modem-status interrupts clear on read
    vx_cons_pump(&cons);   // and a transmitter-empty one, on writing or on reading the IIR
  }
  while (inb(base + LSR) & LSR_DATA) vx_cons_input(&cons, inb(base + RBR));
  vx_cons_pump(&cons);
  // Still pending after the rounds above: the edge-triggered line stays up,
  // so no new edge will come. Come back to it after the other work queued.
  if (!(inb(base + IIR) & IIR_NONE)) vx_port_post(server.port, &(vx_packet){.key = P9_KEY_USER + 1});
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key == P9_KEY_USER + 1) { // service() left something pending
    service();
    return;
  }
  if (pk->trigger != VX_TRIGGER_IRQ) return;
  service();
  vx_irq_ack(irq);
  vx_port_bind(server.port, irq, VX_TRIGGER_IRQ, P9_KEY_USER, 0);
}

const char *vx_main(void) {
  vx_handle io = vx_spawn_take("ioport");
  irq = vx_spawn_take("irq");
  server.listen = vx_spawn_take("listen");
  vx_ndb_record rec;
  uint64_t port = 0, ignored = 0;
  if (!io || !irq || !server.listen || !vx_spawn_record("ioport", &rec) ||
      !vx_ndb_get_u64(&rec, "ioport", &port) || port > 0xfff8 ||
      vx_as_map(vx_self, io, 0, 0, 0, &ignored) != VX_OK) {
    vx_print(VX_STR("drv-uart-16550: no port, IRQ or listen channel\n"));
    return "no port, IRQ or listen channel";
  }
  base = (uint16_t)port;

  outb(base + IER, 0);
  outb(base + FCR, 0xc7); // FIFOs on and cleared, interrupt at 14 bytes
  outb(base + MCR, 0x0b); // DTR, RTS, and OUT2, which gates the IRQ on a PC
  outb(base + IER, ier);
  vx_cons_print_here(&cons);
  cons = (vx_cons){.tx_room = tx_room, .tx_byte = tx_byte, .tx_wanted = tx_wanted};
  server.fs = vx_cons_fs(&cons);
  server.event = event;
  if (vx_port_create(0, &server.port) != VX_OK ||
      vx_port_bind(server.port, irq, VX_TRIGGER_IRQ, P9_KEY_USER, 0) != VX_OK) {
    vx_print(VX_STR("drv-uart-16550: cannot wait for the IRQ\n"));
    return "cannot wait for the IRQ";
  }
  vx_irq_ack(irq);
  service(); // what arrived before the IRQ was ours
  vx_print(VX_STR("drv-uart-16550: serving /srv/cons\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
