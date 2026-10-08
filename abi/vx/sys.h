// vx/sys.h: the syscall wrappers a program may use (09 §5.12, ADR-0004 libvx v0).
// libvx's public declarations: a native program's, and the system's own
// programs' through lib/vx-rt (VX_API, api.h).

#pragma once

#include "api.h"
VX_API vx_instant vx_clock_read(void);
VX_API vx_status vx_clock_info_read(vx_clock_info *info);
VX_API vx_status vx_task_info(vx_handle task, vx_task_summary *out);
VX_API vx_status vx_port_create(uint32_t options, vx_handle *out);
VX_API int64_t vx_port_wait(vx_handle port, vx_instant deadline, vx_duration leeway, vx_packet *out,
                            size_t out_len);
VX_API vx_status vx_port_post(vx_handle port, const vx_packet *packet);
VX_API vx_status vx_port_bind(vx_handle port, vx_handle source, enum vx_trigger trigger, uint64_t key,
                              uint64_t threshold);
VX_API vx_status vx_vmo_create(uint64_t size, uint32_t options, vx_handle *out);
VX_API vx_status vx_vmo_rw(vx_handle vmo, enum vx_vmo_op op, uint64_t offset, void *buf, uint64_t size);
VX_API vx_status vx_vmo_resize(vx_handle vmo, uint64_t size);
VX_API vx_status vx_vmo_decommit(vx_handle vmo, uint64_t offset, uint64_t size);
VX_API vx_status vx_vmo_clone(vx_handle vmo, uint64_t offset, uint64_t size, vx_handle *out);
VX_API vx_status vx_vmo_seal(vx_handle vmo);
VX_API vx_status vx_vmo_lease(vx_handle vmo, vx_handle *lease);
VX_API vx_status vx_vmo_revoke(vx_handle lease);
VX_API vx_status vx_as_map(vx_handle task, vx_handle vmo, uint64_t offset, uint64_t size, uint32_t flags,
                           uint64_t *addr);
VX_API vx_status vx_as_unmap(vx_handle task, uint64_t addr, uint64_t size);
VX_API vx_status vx_as_reserve(vx_handle task, uint64_t size, uint64_t align, uint32_t flags,
                               uint64_t *address);
VX_API vx_status vx_as_protect(vx_handle task, uint64_t address, uint64_t size, uint32_t flags);
VX_API vx_status vx_as_query(vx_handle task, uint64_t address, vx_map_info *info);
VX_API vx_status vx_as_key_alloc(vx_handle task, uint32_t *key);
VX_API vx_status vx_as_key_free(vx_handle task, uint32_t key);
VX_API vx_status vx_keys_set(uint32_t key, uint32_t rights);
VX_API uint32_t vx_keys_get(uint32_t key);
VX_API uint64_t vx_rights_get(void);
VX_API void vx_rights_set(uint64_t rights);
VX_API vx_status vx_thread_state(vx_handle task, uint64_t thread, uint32_t op, void *buf, uint64_t size);
VX_API vx_status vx_thread_suspend(vx_handle task, uint64_t thread);
VX_API vx_status vx_thread_resume(vx_handle task, uint64_t thread);
VX_API vx_status vx_thread_interrupt(vx_handle task, uint64_t thread, vx_str note);
VX_API vx_status vx_thread_set_robust(const void *head, uint64_t size, uint32_t owner);
VX_API vx_status vx_thread_create(vx_handle task, vx_handle *out);
VX_API vx_status vx_thread_create_id(vx_handle task, vx_handle *out, uint32_t *id);
VX_API vx_status vx_thread_start(vx_handle thread, uint64_t entry, uint64_t sp, vx_handle handle,
                                 uint64_t arg2);
VX_API vx_status vx_futex_wait(const _Atomic uint32_t *word, uint32_t expected, vx_instant deadline);
VX_API int64_t vx_futex_wake(const _Atomic uint32_t *word, uint32_t count);
VX_API vx_status vx_channel_create(uint32_t options, vx_handle out[2]);
VX_API vx_status vx_channel_write(vx_handle ch, const void *bytes, uint32_t len, const vx_handle *handles,
                                  uint32_t count);
VX_API vx_status vx_channel_read(vx_handle ch, void *bytes, uint32_t cap, vx_handle *handles,
                                 uint32_t count_cap, vx_msg_size *actual);
VX_API vx_status vx_channel_call(vx_handle ch, vx_call *args, vx_instant deadline);
VX_API vx_status vx_counter_create(uint64_t initial, vx_handle *out);
VX_API vx_status vx_counter_signal(vx_handle c, uint64_t value);
VX_API int64_t vx_counter_read(vx_handle c);
VX_API vx_status vx_handle_dup(vx_handle h, uint32_t rights, vx_handle *out);
VX_API vx_status vx_handle_close(vx_handle h);
VX_API vx_status vx_task_create(vx_str name, vx_handle *out);
VX_API vx_status vx_task_fork(vx_str name, vx_handle *out);
VX_API vx_status vx_task_exec(vx_handle scratch, vx_handle bootstrap, uint64_t entry, uint64_t sp);
VX_API vx_status vx_task_kill(vx_handle task, vx_str msg);
VX_API vx_status vx_task_kill_id(vx_handle task, uint64_t id, vx_str msg);
VX_API vx_status vx_sched_ctx_create(const vx_sched_params *p, vx_handle *out);
VX_API vx_status vx_sched_ctx_bind(vx_handle ctx, vx_handle thread, int32_t core);
VX_API vx_status vx_sched_ctx_configure(vx_handle ctx, const vx_sched_params *p);
VX_API vx_status vx_sched_reserve(vx_handle ctx, uint32_t count, uint32_t cls, uint32_t domain,
                                  uint32_t flags, vx_core_set *out);
