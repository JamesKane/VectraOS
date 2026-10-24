// amd64 handoff to the kernel. Assembly because it reloads CR3 and jumps
// into the new address space; see loader.h for the contract.

.section .text.croi_arch, "ax", @progbits

// void croi_arch_enter_kernel(root=%rdi, root_high=%rsi, entry=%rdx, handoff=%rcx)
.globl croi_arch_enter_kernel
.type croi_arch_enter_kernel, @function
croi_arch_enter_kernel:
    cli
    mov     %rcx, %r8               // handoff; rdmsr/wrmsr clobber rcx and rdx
    mov     %rdx, %r9               // entry

    // The boot page tables use NX, so make sure EFER.NXE is on.
    mov     $0xc0000080, %ecx
    rdmsr
    or      $(1 << 11), %eax
    wrmsr

    // Enforce read-only mappings in supervisor mode (CR0.WP).
    mov     %cr0, %rax
    or      $(1 << 16), %rax
    mov     %rax, %cr0

    mov     %rdi, %cr3
    mov     %r8, %rdi
    jmp     *%r9
.size croi_arch_enter_kernel, . - croi_arch_enter_kernel

// 1 if the firmware left 5-level paging (CR4.LA57) enabled.
.globl croi_arch_unsupported
.type croi_arch_unsupported, @function
croi_arch_unsupported:
    mov     %cr4, %rax
    shr     $12, %rax
    and     $1, %eax
    ret
.size croi_arch_unsupported, . - croi_arch_unsupported

// uint64_t croi_arch_entropy(uint64_t *strong=rdi): RDRAND if CPUID says
// so (ten tries), else 0 with *strong = 0.
.globl croi_arch_entropy
.type croi_arch_entropy, @function
croi_arch_entropy:
    push    %rbx
    mov     $1, %eax
    cpuid
    bt      $30, %ecx               // RDRAND
    jnc     2f
    mov     $10, %ecx
1:  rdrand  %rax
    jc      3f
    dec     %ecx
    jnz     1b
2:  movq    $0, (%rdi)
    xor     %eax, %eax
    pop     %rbx
    ret
3:  movq    $1, (%rdi)
    pop     %rbx
    ret
.size croi_arch_entropy, . - croi_arch_entropy

.globl croi_arch_counter
.type croi_arch_counter, @function
croi_arch_counter:
    rdtsc
    shl     $32, %rdx
    or      %rdx, %rax
    ret
.size croi_arch_counter, . - croi_arch_counter

// Caches are coherent with page walks and instruction fetch on x86.
.globl croi_arch_clean_dcache
.type croi_arch_clean_dcache, @function
croi_arch_clean_dcache:
    ret
.size croi_arch_clean_dcache, . - croi_arch_clean_dcache

// void croi_arch_cpu_ids(uint64_t ids[4]=rdi): CPUID 1's ECX, 7.0's EBX,
// 0xD.1's EAX, and the highest basic leaf (leaves past it read as 0).
.globl croi_arch_cpu_ids
.type croi_arch_cpu_ids, @function
croi_arch_cpu_ids:
    push    %rbx
    mov     %rdi, %r8
    xor     %eax, %eax
    cpuid
    mov     %eax, %r9d
    mov     %rax, 24(%r8)
    mov     $1, %eax
    cpuid
    mov     %rcx, (%r8)
    movq    $0, 8(%r8)
    movq    $0, 16(%r8)
    cmp     $7, %r9d
    jb      1f
    mov     $7, %eax
    xor     %ecx, %ecx
    cpuid
    mov     %rbx, 8(%r8)
    cmp     $0xd, %r9d
    jb      1f
    mov     $0xd, %eax
    mov     $1, %ecx
    cpuid
    mov     %rax, 16(%r8)
1:  pop     %rbx
    ret
.size croi_arch_cpu_ids, . - croi_arch_cpu_ids
