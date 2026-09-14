// runtime/aarch64-apple/runtime.s
// Pure assembly runtime for L00. No C, no libc I/O, no malloc.
//
// clang/ld may assemble and link this file. They must never compile a .c.
//
// Heap choice (locked): anonymous mmap via Darwin syscall, 64 MiB, 8-byte
// aligned because mmap returns a page (16 KiB on Apple Silicon). Not .bss:
// the binary stays small, ASLR applies, L12 can keep the same heap contract.
//
// Process entry: _main so the usual driver works:
//   clang -arch arm64 runtime/aarch64-apple/runtime.s program.s -o program
// Darwin crt1 calls _main. This file still does write/exit itself via svc;
// it does not return a printed value through libc.
//
// Darwin/arm64 syscall ABI (XNU):
//   x16 = syscall number
//   x0–x7 = arguments
//   svc #0x80
//   success: carry clear, result in x0
//   error:   carry set, errno in x0
//
// Syscall numbers (bsd/kern/syscalls.master):
//   SYS_exit = 1
//   SYS_write = 4     write(fd, buf, nbyte)
//   SYS_mmap = 197    mmap(addr, len, prot, flags, fd, pos)
//
// mmap constants (sys/mman.h):
//   PROT_READ = 1, PROT_WRITE = 2
//   MAP_PRIVATE = 0x0002, MAP_ANON = 0x1000
//   fd must be -1 with MAP_ANON; 64-bit off_t is the 6th argument (x5).
//
// Print convention (L00): _rt_print treats x0 as a signed 64-bit untagged
// integer, writes decimal ASCII plus a trailing newline to fd 1, then
// returns. It must not hard-code 42. L01 will decode fixnum tags here.
//
// scheme_entry convention (Darwin integer ABI, Mach-O underscore names):
//   bl _scheme_entry
//   x0 = heap base (page-aligned)
//   x1 = heap size in bytes (64 MiB)
//   on ret, x0 = Scheme result
//
// Tag constants live in the compiler and as comments here. There is no
// scheme.h and there will not be one.

        .text
        .globl  _main
        .globl  _rt_print
        .globl  _rt_error
        .p2align 2

        .equ    SYS_EXIT, 1
        .equ    SYS_WRITE, 4
        .equ    SYS_MMAP, 197
        .equ    PROT_READ_WRITE, 3
        .equ    MAP_ANON_PRIVATE, 0x1002
        .equ    HEAP_SHIFT, 26          // 1 << 26 = 64 MiB

// ---------------------------------------------------------------------------
// _main
// ---------------------------------------------------------------------------
_main:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp

        // mmap(NULL, 64MiB, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)
        mov     x0, #0
        mov     x1, #1
        lsl     x1, x1, #26             // 64 MiB
        mov     x2, #PROT_READ_WRITE
        mov     x3, #MAP_ANON_PRIVATE
        mov     x4, #-1
        mov     x5, #0
        mov     x16, #SYS_MMAP
        svc     #0x80
        b.cs    .Lmmap_fail

        // x0 = heap base from mmap; reload size (svc may clobber x1)
        mov     x1, #1
        lsl     x1, x1, #26             // 64 MiB
        bl      _scheme_entry
        bl      _rt_print

        mov     x0, #0
        mov     x16, #SYS_EXIT
        svc     #0x80

.Lmmap_fail:
        adr     x0, .Lmsg_heap
        bl      _rt_error               // never returns

// ---------------------------------------------------------------------------
// _rt_print: signed decimal of x0, then '\n', via SYS_write to stdout.
// Handles 0, negatives, and INT64_MIN (unsigned abs via mvn+add).
// Frame: 16 bytes fp/lr + 32 bytes digit buffer (filled from the end).
// ---------------------------------------------------------------------------
        .p2align 2
_rt_print:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp

        add     x1, sp, #47             // last byte of the 32-byte buffer
        mov     w2, #'\n'
        strb    w2, [x1]

        mov     x3, x0
        mov     w4, #0                  // negative flag
        cmp     x3, #0
        b.ge    .Lprt_abs
        mov     w4, #1
        mvn     x3, x3
        add     x3, x3, #1              // unsigned |x0|, works for INT64_MIN
.Lprt_abs:
        cbnz    x3, .Lprt_digits
        sub     x1, x1, #1
        mov     w2, #'0'
        strb    w2, [x1]
        b       .Lprt_sign

.Lprt_digits:
        mov     x5, #10
.Lprt_loop:
        udiv    x6, x3, x5
        msub    x7, x6, x5, x3          // remainder 0..9
        add     w7, w7, #'0'
        sub     x1, x1, #1
        strb    w7, [x1]
        mov     x3, x6
        cbnz    x3, .Lprt_loop

.Lprt_sign:
        cbz     w4, .Lprt_write
        sub     x1, x1, #1
        mov     w2, #'-'
        strb    w2, [x1]

.Lprt_write:
        add     x2, sp, #48             // one past the newline
        sub     x2, x2, x1              // length
        mov     x0, #1                  // stdout
        mov     x16, #SYS_WRITE
        svc     #0x80
        ldp     x29, x30, [sp], #48
        ret

// ---------------------------------------------------------------------------
// _rt_error: x0 = pointer to NUL-terminated message (may include newline).
// Writes the message to stderr, then SYS_exit(1). Never returns.
// ---------------------------------------------------------------------------
        .p2align 2
_rt_error:
        mov     x1, x0
        mov     x2, x0
.Lerr_len:
        ldrb    w3, [x2]
        cbz     w3, .Lerr_len_done
        add     x2, x2, #1
        b       .Lerr_len
.Lerr_len_done:
        sub     x2, x2, x1
        mov     x0, #2                  // stderr
        mov     x16, #SYS_WRITE
        svc     #0x80
        mov     x0, #1
        mov     x16, #SYS_EXIT
        svc     #0x80

        .p2align 2
.Lmsg_heap:
        .asciz  "heap alloc failed\n"
