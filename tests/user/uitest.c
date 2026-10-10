// uitest: vxui's immediate-mode UI (M7 step 7e2b, the ui scenario): a
// label with a count, a label that appears once the count is above 0 (the
// buttons below it move down), Add and Reset, and two Delete buttons told
// apart by vx_push_id. The scenario clicks Add, then Add where it has moved
// to (input by the last frame's rectangles), the second Delete, and Reset
// (the label goes and the buttons move back: the damage repainted right in
// both buffers). Each change is a line; two screens are matched.

#include <vxui.h>

const char *vx_main(void) {
  vx_app *app = vx_app_open("org.example.ui");
  vx_window *win = vx_window_open(app, "UI", 300, 260);
  uint32_t count = 0;
  vx_event ev;
  while (vx_wait(app, &ev, VX_INFINITE)) {
    if (ev.kind == VX_CLOSE) return nullptr;
    if (ev.kind != VX_FRAME) continue;
    vx_ui *ui = vx_ui_begin(win, &ev.frame);
    char text[32] = "Count: ";
    size_t n = 7;
    char d[10];
    size_t k = 0;
    uint32_t v = count;
    do d[k++] = (char)('0' + v % 10), v /= 10;
    while (v);
    while (k) text[n++] = d[--k];
    text[n] = 0;
    vx_label(ui, text);
    if (count) vx_label(ui, "Clicked!");
    if (vx_button(ui, "Add")) vx_printf("uitest: count %u\n", ++count), vx_window_redraw(win);
    if (vx_button(ui, "Reset")) vx_printf("uitest: count %u\n", count = 0), vx_window_redraw(win);
    for (uint64_t row = 0; row < 2; row++) {
      vx_push_id(ui, row);
      if (vx_button(ui, "Delete")) vx_printf("uitest: delete %u\n", (unsigned)row);
      vx_pop_id(ui);
    }
    vx_ui_end(ui);
  }
  return nullptr;
}
