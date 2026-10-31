// rv64 handoff to the kernel. Assembly because it writes satp and jumps
// into the new address space; see loader.h for the contract.

#define SATP_MODE_SV39 (8 << 60)

.section .text.croi_arch, "ax", %progbits

// void croi_arch_enter_kernel(root=a0, root_high=a1, entry=a2, handoff=a3)
.globl croi_arch_enter_kernel
.type croi_arch_enter_kernel, %function
croi_arch_enter_kernel:
    csrci   sstatus, 0x2            // clear SIE
    srli    t0, a0, 12
    li      t1, SATP_MODE_SV39
    or      t0, t0, t1
    sfence.vma
    csrw    satp, t0
    sfence.vma
    fence.i                         // kernel text was written as data
    mv      a0, a3
    jr      a2
.size croi_arch_enter_kernel, . - croi_arch_enter_kernel

.globl croi_arch_unsupported
.type croi_arch_unsupported, %function
croi_arch_unsupported:
    li      a0, 0
    ret
.size croi_arch_unsupported, . - croi_arch_unsupported

// No random number instruction S-mode can count on (Zkr's seed CSR traps
// unless M-mode opened it): 0 with *strong = 0.
.globl croi_arch_entropy
.type croi_arch_entropy, %function
croi_arch_entropy:
    sd      zero, 0(a0)
    li      a0, 0
    ret
.size croi_arch_entropy, . - croi_arch_entropy

.globl croi_arch_counter
.type croi_arch_counter, %function
croi_arch_counter:
    rdtime  a0
    ret
.size croi_arch_counter, . - croi_arch_counter

// Data caches are coherent with page walks; fence.i covers instructions.
.globl croi_arch_clean_dcache
.type croi_arch_clean_dcache, %function
croi_arch_clean_dcache:
    ret
.size croi_arch_clean_dcache, . - croi_arch_clean_dcache

// The extensions come from the RHCT's ISA strings; what S-mode can learn
// of the core is its IDs, from SBI's base extension (0x10): mvendorid,
// marchid and mimpid (functions 4-6), 0 where the call fails. SBI keeps
// every register but a0 and a1.
.globl croi_arch_cpu_ids
.type croi_arch_cpu_ids, %function
croi_arch_cpu_ids:
    mv      t0, a0
    li      a7, 0x10
    li      t1, 4
1:  mv      a6, t1
    ecall
    beqz    a0, 2f
    li      a1, 0
2:  sd      a1, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, 1
    li      t2, 7
    bltu    t1, t2, 1b
    sd      zero, 0(t0)
    ret
.size croi_arch_cpu_ids, . - croi_arch_cpu_ids
