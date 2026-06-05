.globl memzero
memzero:
    /* size == 0: write nothing. Live callers all pass nonzero, but fail
       closed so a future zero-length call can't clobber 8 bytes. */
    cbz x1, 1f
0:
    /* store 8 bytes of zero to [x0], then x0 += 8 */
    str xzr, [x0], #8
    subs x1, x1, #8
    /* branch if bytes remain */
    b.gt 0b
1:
    ret
