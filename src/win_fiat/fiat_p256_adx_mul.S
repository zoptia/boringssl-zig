// fiat_p256_adx_mul.S — win64 (COFF) build of the fiat-crypto P-256 ADX field op.
//
// FORK-OWNED build-system file (not upstream). Two things conspire to break the
// win64 cross-build of this op, and this file fixes BOTH:
//
//  1. LINK: upstream ships the op only as the `__APPLE__ || __ELF__`-guarded GAS
//     .S at third_party/fiat/asm/fiat_p256_adx_mul.S (emits nothing on PE/COFF),
//     with no nasm variant — so the win64 nasm path defines no symbol, yet
//     crypto/fipsmodule/ec/p256_internal.h references fiat_p256_adx_{mul,sqr}
//     under `__GNUC__ && OPENSSL_X86_64` (which zig cc/clang satisfies). The
//     de-ELF'd body below supplies the missing definition.
//
//  2. ABI (the subtle one): unlike crypto/curve25519/internal.h, whose adx decls
//     carry `__attribute__((sysv_abi))`, p256_internal.h declares fiat_p256_adx_*
//     as PLAIN functions. On x86_64-windows the default convention is Microsoft
//     x64, so clang calls them with args in rcx/rdx/r8 — but the fiat body is
//     System V (args in rdi/rsi/rdx) and clobbers the win64-nonvolatile rsi/rdi.
//     Calling the raw SysV body directly would read wrong operands and corrupt
//     memory. So the entry point `fiat_p256_adx_mul` below is a small Win64->SysV
//     shim that marshals the args and preserves rsi/rdi, then calls the body.
//
// The body (.Lfiat_p256_adx_mul_body) is the upstream SysV body, mechanically
// de-ELF'd, BYTE-IDENTICAL to the upstream .S preprocessed for COFF. Keep it that
// way: scripts/check-win-fiat.sh re-derives it from the current upstream .S and
// fails CI on drift. build.zig compiles this on the win64 nasm path.
//
// Regenerate the body from the upstream .S in this same tree:
//   zig cc -target x86_64-windows -E -Iinclude -D__ELF__=1 \
//     third_party/fiat/asm/fiat_p256_adx_mul.S \
//   | grep -vE '^[[:space:]]*(#|\.(type|size|hidden|private_extern|pushsection|popsection|section[[:space:]]+\.note))'

#define _CET_ENDBR
.text

.global fiat_p256_adx_mul
fiat_p256_adx_mul:
	// Win64 (rcx=out, rdx=in1, r8=in2) -> SysV (rdi/rsi/rdx); rsi/rdi are
	// win64-nonvolatile and the SysV body clobbers them, so save/restore.
	pushq %rsi
	pushq %rdi
	movq %rcx, %rdi
	movq %rdx, %rsi
	movq %r8, %rdx
	call .Lfiat_p256_adx_mul_body
	popq %rdi
	popq %rsi
	retq

.Lfiat_p256_adx_mul_body:
.cfi_startproc

pushq %rbp
;.cfi_adjust_cfa_offset 8
.cfi_offset rbp, -16
movq %rsp, %rbp
movq %rdx, %rax
movq (%rsi), %rdx
testb %al, %al
mulxq (%rax), %rcx, %r8
movq %rbx, -0x80(%rsp)
.cfi_offset rbx, -16-0x80
mulxq 0x8(%rax), %r9, %rbx
movq %r14, -0x68(%rsp)
.cfi_offset r14, -16-0x68
adcq %r8, %r9
movq %r15, -0x60(%rsp)
.cfi_offset r15, -16-0x60
mulxq 0x10(%rax), %r14, %r15
movq %r12, -0x78(%rsp)
.cfi_offset r12, -16-0x78
adcq %rbx, %r14
mulxq 0x18(%rax), %r10, %r11
movq %r13, -0x70(%rsp)
.cfi_offset r13, -16-0x70
adcq %r15, %r10
movq 0x8(%rsi), %rdx
mulxq (%rax), %r8, %rbx
adcq $0x0, %r11
xorq %r15, %r15
adcxq %r9, %r8
adoxq %r14, %rbx
movq %rdi, -0x58(%rsp)
mulxq 0x8(%rax), %r9, %rdi
adcxq %rbx, %r9
adoxq %r10, %rdi
mulxq 0x10(%rax), %r14, %rbx
adcxq %rdi, %r14
adoxq %r11, %rbx
mulxq 0x18(%rax), %r12, %r13
adcxq %rbx, %r12
movq $0x100000000, %rdx
mulxq %rcx, %r10, %r11
adoxq %r15, %r13
adcxq %r15, %r13
xorq %rdi, %rdi
adoxq %r8, %r10
mulxq %r10, %rbx, %r8
adoxq %r9, %r11
adcxq %r11, %rbx
adoxq %r14, %r8
movq $0xffffffff00000001, %rdx
mulxq %rcx, %r15, %r9
adcxq %r8, %r15
adoxq %r12, %r9
mulxq %r10, %rcx, %r14
movq 0x10(%rsi), %rdx
mulxq 0x8(%rax), %r12, %r10
adcxq %r9, %rcx
adoxq %r13, %r14
mulxq (%rax), %r13, %r11
movq %rdi, %r9
adcxq %r9, %r14
adoxq %rdi, %rdi
adcq $0x0, %rdi
xorq %r9, %r9
adcxq %rbx, %r13
adoxq %r15, %r11
movq 0x10(%rsi), %rdx
mulxq 0x10(%rax), %r8, %r15
adoxq %rcx, %r10
mulxq 0x18(%rax), %rbx, %rcx
movq 0x18(%rsi), %rdx
adcxq %r11, %r12
mulxq 0x8(%rax), %r11, %rsi
adcxq %r10, %r8
adoxq %r14, %r15
adcxq %r15, %rbx
adoxq %r9, %rcx
adcxq %r9, %rcx
mulxq (%rax), %r10, %r15
addq %rdi, %rcx
movq %r9, %r14
adcq $0x0, %r14
xorq %r9, %r9
adcxq %r12, %r10
adoxq %r8, %r15
adcxq %r15, %r11
adoxq %rbx, %rsi
mulxq 0x10(%rax), %r12, %r8
adoxq %rcx, %r8
mulxq 0x18(%rax), %rbx, %rcx
adcxq %rsi, %r12
adoxq %r9, %rcx
movq $0x100000000, %rdx
adcxq %r8, %rbx
adcq $0x0, %rcx
mulxq %r13, %r15, %rdi
xorq %rax, %rax
adcxq %r14, %rcx
adcq $0x0, %rax
xorq %r9, %r9
adoxq %r10, %r15
mulxq %r15, %r10, %r14
adoxq %r11, %rdi
movq $0xffffffff00000001, %rdx
adoxq %r12, %r14
adcxq %rdi, %r10
mulxq %r13, %r11, %r12
adcxq %r14, %r11
adoxq %rbx, %r12
mulxq %r15, %r13, %rbx
adcxq %r12, %r13
adoxq %rcx, %rbx
movq %r9, %r8
adoxq %r9, %rax
adcxq %rbx, %r8
adcq $0x0, %rax
movq %rax, %rcx
movq $0xffffffffffffffff, %r15
movq %r10, %rdi
subq %r15, %rdi
movq $0xffffffff, %r14
movq %r11, %r12
sbbq %r14, %r12
movq %r13, %rbx
sbbq %r9, %rbx
movq %rax, %rax
movq %r8, %rax
sbbq %rdx, %rax
sbbq %r9, %rcx
cmovcq %r10, %rdi
movq -0x58(%rsp), %r10
cmovcq %r13, %rbx
movq -0x70(%rsp), %r13
.cfi_restore r13
cmovcq %r11, %r12
cmovcq %r8, %rax
movq %rbx, 0x10(%r10)
movq -0x80(%rsp), %rbx
.cfi_restore rbx
movq %rdi, (%r10)
movq %r12, 0x8(%r10)
movq %rax, 0x18(%r10)
movq -0x78(%rsp), %r12
.cfi_restore r12
movq -0x68(%rsp), %r14
.cfi_restore r14
movq -0x60(%rsp), %r15
.cfi_restore r15
popq %rbp
.cfi_restore rbp
.cfi_adjust_cfa_offset -8
retq
.cfi_endproc
