# Assembly stubs for x86_64 that can't be done in Zig inline assembly
# These are the low-level CPU operations that need proper memory operands

.section .data
# Handler function pointers - set by Zig code
.global exception_handler_ptr
.global irq_handler_ptr
exception_handler_ptr: .quad 0
irq_handler_ptr: .quad 0

.section .text

# void asm_lgdt(void* gdtr_ptr)
.global asm_lgdt
asm_lgdt:
    lgdt (%rdi)
    ret

# void asm_lidt(void* idtr_ptr)
.global asm_lidt
asm_lidt:
    lidt (%rdi)
    ret

# void asm_reload_segments(uint64_t code_sel, uint16_t data_sel)
.global asm_reload_segments
asm_reload_segments:
    pushq %rdi
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    movw %si, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    ret

# ISR common stub
# Stack on entry: [vector, error_code, rip, cs, rflags, rsp, ss]
isr_common:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    
    movq 120(%rsp), %rdi    # vector
    movq 128(%rsp), %rsi    # error_code
    movq exception_handler_ptr(%rip), %rax
    call *%rax
    
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rbx
    popq %rdx
    popq %rcx
    popq %rax
    addq $16, %rsp
    iretq

# IRQ common stub
irq_common:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    
    movq 120(%rsp), %rdi    # vector
    movq irq_handler_ptr(%rip), %rax
    call *%rax
    
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rbx
    popq %rdx
    popq %rcx
    popq %rax
    addq $16, %rsp
    iretq

# Individual ISR entry points
.macro isr_no_error num
.global asm_isr\num
asm_isr\num:
    pushq $0        # dummy error code
    pushq $\num     # vector number
    jmp isr_common
.endm

.macro isr_error num
.global asm_isr\num
asm_isr\num:
    # error code already pushed by CPU
    pushq $\num     # vector number
    jmp isr_common
.endm

# Exceptions 0-31
isr_no_error 0
isr_no_error 1
isr_no_error 2
isr_no_error 3
isr_no_error 4
isr_no_error 5
isr_no_error 6
isr_no_error 7
isr_error 8      # Double fault
isr_no_error 9
isr_error 10     # Invalid TSS
isr_error 11     # Segment not present
isr_error 12     # Stack fault
isr_error 13     # General protection
isr_error 14     # Page fault
isr_no_error 15
isr_no_error 16
isr_error 17     # Alignment check
isr_no_error 18
isr_no_error 19

# IRQs (vectors 32+)
.macro irq num vec
.global asm_irq\num
asm_irq\num:
    pushq $0
    pushq $\vec
    jmp irq_common
.endm

irq 0 32
irq 1 33

# Spurious IRQ
.global asm_irq_spurious
asm_irq_spurious:
    pushq $0
    pushq $255
    jmp irq_common

# Syscall entry point
# ABI: syscall number in RAX, args in RDI, RSI, RDX, R10, R8, R9
# RCX contains return RIP, R11 contains RFLAGS
.global asm_syscall_entry
.global syscall_per_cpu
.global syscall_dispatch_ptr

.section .data
syscall_per_cpu: 
    .quad 0     # kernel_rsp
    .quad 0     # user_rsp
syscall_dispatch_ptr: .quad 0

.section .text
asm_syscall_entry:
    # Save user RSP to per_cpu.user_rsp
    movq %rsp, syscall_per_cpu + 8(%rip)
    
    # Load kernel RSP from per_cpu.kernel_rsp
    movq syscall_per_cpu(%rip), %rsp
    
    # Push interrupt frame for SYSRET
    pushq $0x23             # User SS (0x20 | 3)
    pushq syscall_per_cpu + 8(%rip)  # User RSP
    pushq %r11              # RFLAGS
    pushq $0x1b             # User CS (0x18 | 3)
    pushq %rcx              # User RIP
    
    # Push error code (0 for syscall)
    pushq $0
    
    # Save all GPRs
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    
    # Set up args for dispatch: syscall_num, arg1-6
    # Offsets: 14*8=112, 13*8=104, 5*8=40, 7*8=56, 6*8=48, 15*8=120
    movq %rax, %rdi         # syscall_num
    movq 112(%rsp), %rsi    # original RDI -> arg2
    movq 104(%rsp), %rdx    # original RSI -> arg3
    movq 40(%rsp), %rcx     # original R10 -> arg4
    movq 56(%rsp), %r8      # original R8 -> arg5
    movq 48(%rsp), %r9      # original R9 -> arg6
    
    # Call dispatch
    movq syscall_dispatch_ptr(%rip), %rax
    call *%rax
    
    # Store return value
    movq %rax, 120(%rsp)
    
    # Restore GPRs
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    
    # Skip error code
    addq $8, %rsp
    
    # Pop interrupt frame and return via sysret
    popq %rcx               # RIP
    addq $8, %rsp           # Skip CS
    popq %r11               # RFLAGS
    popq %rsp               # Restore user RSP
    
    sysretq

# Context switch
.global asm_switch_contexts
asm_switch_contexts:
    # rdi = old_rsp_ptr, rsi = new_rsp
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushfq

    movq %rsp, (%rdi)       # Save current RSP
    movq %rsi, %rsp         # Load new RSP

    popfq
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# FPU/SSE state save/restore using FXSAVE/FXRSTOR
# These require 16-byte aligned buffers of 512 bytes

# void asm_fxsave(void* fpu_state_ptr)
# Saves FPU/MMX/SSE state to the 512-byte buffer at fpu_state_ptr
.global asm_fxsave
asm_fxsave:
    fxsave (%rdi)
    ret

# void asm_fxrstor(void* fpu_state_ptr)
# Restores FPU/MMX/SSE state from the 512-byte buffer at fpu_state_ptr
.global asm_fxrstor
asm_fxrstor:
    fxrstor (%rdi)
    ret

# void asm_fninit()
# Initialize FPU to default state (called for fresh threads)
.global asm_fninit
asm_fninit:
    fninit
    ret
