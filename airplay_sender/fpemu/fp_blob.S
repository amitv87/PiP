/*
 * Embeds the FairPlay snapshot (fp_blob.bin) into the binary via .incbin.
 *
 * fp_blob.bin is Apple's proprietary FairPlay code and is NEVER committed. It
 * is produced at build time by extract_blob.py from the doubletake submodule.
 * The assembler must be given an include path (-I) to the directory containing
 * fp_blob.bin. See fpemu/README.md.
 */
    .section __TEXT,__const
    .p2align 4
    .global _fpemu_blob
_fpemu_blob:
    .incbin "fp_blob.bin"
    .global _fpemu_blob_end
_fpemu_blob_end:
