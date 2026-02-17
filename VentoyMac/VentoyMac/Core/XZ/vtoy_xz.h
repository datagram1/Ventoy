#ifndef VTOY_XZ_H
#define VTOY_XZ_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Decompress XZ data in memory.
 *
 * input:        pointer to XZ compressed data
 * input_len:    length of compressed data
 * output:       pre-allocated output buffer
 * output_max:   size of output buffer
 * actual_size:  (out) actual decompressed size, set on success
 *
 * Returns 0 on success, non-zero on failure.
 *
 * Tries macOS compression framework (COMPRESSION_LZMA) first.
 * Falls back to streaming decompression if the first attempt fails.
 */
int vtoy_xz_decompress(const uint8_t *input, size_t input_len,
                        uint8_t *output, size_t output_max,
                        size_t *actual_size);

/*
 * Decompress an XZ file to an output file.
 *
 * input_path:   path to the .xz file
 * output_path:  path for the decompressed output
 *
 * Returns 0 on success, non-zero on failure.
 * Falls back to system `xz` command if in-memory decompression fails.
 */
int vtoy_xz_decompress_file(const char *input_path, const char *output_path);

/*
 * Get the uncompressed size from an XZ file header/footer.
 * Returns 0 if it cannot be determined.
 *
 * Note: XZ format stores the uncompressed size in the stream footer's
 * index records. This reads the file footer to extract it.
 */
uint64_t vtoy_xz_get_uncompressed_size(const char *input_path);

#ifdef __cplusplus
}
#endif

#endif /* VTOY_XZ_H */
