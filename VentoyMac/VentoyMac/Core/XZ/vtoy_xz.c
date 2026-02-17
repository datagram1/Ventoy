/*
 * vtoy_xz.c - XZ/LZMA decompression module for VentoyMac
 *
 * Provides in-memory and file-based XZ decompression using the macOS
 * compression framework, with fallback to the system xz command.
 *
 * Pure C, no Objective-C. Thread-safe (no global mutable state).
 */

#include "vtoy_xz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <compression.h>

/* XZ format constants */
#define XZ_MAGIC_SIZE          6
#define XZ_STREAM_HEADER_SIZE  12  /* magic(6) + stream_flags(2) + crc32(4) */
#define XZ_STREAM_FOOTER_SIZE  12
#define XZ_FOOTER_MAGIC_0     0x59  /* 'Y' */
#define XZ_FOOTER_MAGIC_1     0x5A  /* 'Z' */
#define XZ_DEFAULT_OUTPUT_SIZE (64UL * 1024 * 1024)  /* 64 MB */
#define XZ_STREAM_CHUNK_SIZE   (64 * 1024)           /* 64 KB */

static const uint8_t xz_magic[XZ_MAGIC_SIZE] = {
    0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00
};

/* ------------------------------------------------------------------ */
/* Internal helpers                                                    */
/* ------------------------------------------------------------------ */

/*
 * Read a little-endian uint32 from a byte pointer.
 */
static uint32_t read_le32(const uint8_t *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/*
 * Read a little-endian uint64 from a byte pointer.
 */
static uint64_t read_le64(const uint8_t *p)
{
    return (uint64_t)p[0]
         | ((uint64_t)p[1] << 8)
         | ((uint64_t)p[2] << 16)
         | ((uint64_t)p[3] << 24)
         | ((uint64_t)p[4] << 32)
         | ((uint64_t)p[5] << 40)
         | ((uint64_t)p[6] << 48)
         | ((uint64_t)p[7] << 56);
}

/*
 * Decode a multibyte variable-length integer used in the XZ index.
 * Returns the number of bytes consumed, or 0 on error.
 * The decoded value is stored in *value.
 */
static size_t decode_multibyte(const uint8_t *buf, size_t buf_len, uint64_t *value)
{
    uint64_t result = 0;
    size_t i;

    if (buf_len == 0) {
        return 0;
    }

    for (i = 0; i < buf_len && i < 9; i++) {
        result |= (uint64_t)(buf[i] & 0x7F) << (i * 7);
        if ((buf[i] & 0x80) == 0) {
            *value = result;
            return i + 1;
        }
    }

    return 0; /* malformed */
}

/*
 * Check whether the buffer starts with the XZ magic bytes.
 */
static int is_xz_format(const uint8_t *data, size_t len)
{
    if (len < XZ_MAGIC_SIZE) {
        return 0;
    }
    return memcmp(data, xz_magic, XZ_MAGIC_SIZE) == 0;
}

/*
 * Attempt to skip the XZ stream header and the first block header
 * to locate the start of raw compressed LZMA2 data.
 *
 * On success, sets *payload_offset and *payload_len.
 * Returns 0 on success, -1 on failure.
 *
 * XZ stream layout:
 *   Stream Header (12 bytes)
 *   Block Header  (variable)
 *   Compressed Data (LZMA2)
 *   Block Padding
 *   Index
 *   Stream Footer (12 bytes)
 *
 * Block Header:
 *   Byte 0: Block Header Size = (real_size / 4) encoded. real_size = (byte0 + 1) * 4
 *   Remaining: flags + filters + padding + CRC32
 */
static int skip_xz_header(const uint8_t *data, size_t data_len,
                           size_t *payload_offset, size_t *payload_len)
{
    size_t block_header_start;
    size_t block_header_size;

    if (data_len < XZ_STREAM_HEADER_SIZE + 4 + XZ_STREAM_FOOTER_SIZE) {
        return -1;
    }

    if (!is_xz_format(data, data_len)) {
        return -1;
    }

    /* Block header starts right after the 12-byte stream header */
    block_header_start = XZ_STREAM_HEADER_SIZE;

    /* First byte of block header encodes the size:
     * 0 means Index indicator, not a block. Otherwise size = (byte + 1) * 4 */
    if (data[block_header_start] == 0x00) {
        return -1; /* No blocks, just an index -- nothing to decompress */
    }

    block_header_size = ((size_t)data[block_header_start] + 1) * 4;

    if (block_header_start + block_header_size > data_len) {
        return -1;
    }

    *payload_offset = block_header_start + block_header_size;

    /*
     * Payload length: everything from the end of the block header up to
     * the stream footer area.  We subtract the footer (12 bytes) and
     * allow some slack for the index section.  This is an approximation:
     * we feed this to the LZMA decoder which will stop when the stream
     * ends, so over-estimating the length is acceptable.
     */
    if (*payload_offset >= data_len - XZ_STREAM_FOOTER_SIZE) {
        return -1;
    }

    *payload_len = data_len - *payload_offset - XZ_STREAM_FOOTER_SIZE;

    return 0;
}

/*
 * Try decompression using macOS compression_stream (streaming API).
 * This gives more control than the one-shot compression_decode_buffer.
 * Returns 0 on success, -1 on failure.
 */
static int try_streaming_decompress(const uint8_t *input, size_t input_len,
                                    uint8_t *output, size_t output_max,
                                    size_t *actual_size)
{
    compression_stream stream;
    compression_status status;
    size_t total_out = 0;
    size_t src_consumed = 0;

    status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA);
    if (status != COMPRESSION_STATUS_OK) {
        return -1;
    }

    stream.src_ptr = input;
    stream.src_size = input_len;
    stream.dst_ptr = output;
    stream.dst_size = output_max;

    while (1) {
        int flags = 0;

        /* If all input has been provided, signal end of input */
        if (stream.src_size == 0) {
            flags = COMPRESSION_STREAM_FINALIZE;
        }

        status = compression_stream_process(&stream, flags);

        if (status == COMPRESSION_STATUS_OK) {
            /* Progress was made; continue */
            continue;
        } else if (status == COMPRESSION_STATUS_END) {
            /* Decompression complete */
            total_out = output_max - stream.dst_size;
            break;
        } else {
            /* Error */
            compression_stream_destroy(&stream);
            return -1;
        }
    }

    compression_stream_destroy(&stream);

    if (total_out == 0 || total_out > output_max) {
        return -1;
    }

    *actual_size = total_out;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

int vtoy_xz_decompress(const uint8_t *input, size_t input_len,
                        uint8_t *output, size_t output_max,
                        size_t *actual_size)
{
    size_t result;

    if (!input || !output || !actual_size || input_len == 0 || output_max == 0) {
        return -1;
    }

    *actual_size = 0;

    /*
     * Attempt 1: Direct LZMA decompression of the entire buffer.
     * This works if the data is raw LZMA (not XZ-wrapped).
     */
    result = compression_decode_buffer(output, output_max,
                                       input, input_len,
                                       NULL, COMPRESSION_LZMA);

    if (result > 0 && result <= output_max) {
        *actual_size = result;
        return 0;
    }

    /*
     * Attempt 2: If the data is XZ-wrapped, skip the XZ header/block
     * header and try to decompress the raw LZMA2 payload.
     */
    if (is_xz_format(input, input_len)) {
        size_t payload_offset = 0;
        size_t payload_len = 0;

        if (skip_xz_header(input, input_len,
                           &payload_offset, &payload_len) == 0) {

            /* Try one-shot on the raw payload */
            result = compression_decode_buffer(output, output_max,
                                               input + payload_offset,
                                               payload_len,
                                               NULL, COMPRESSION_LZMA);
            if (result > 0 && result <= output_max) {
                *actual_size = result;
                return 0;
            }

            /* Try streaming on the raw payload */
            if (try_streaming_decompress(input + payload_offset, payload_len,
                                         output, output_max,
                                         actual_size) == 0) {
                return 0;
            }
        }
    }

    /*
     * Attempt 3: Streaming decompression on the full input buffer.
     * Some data may be decodable with the streaming API even when
     * the one-shot call fails.
     */
    if (try_streaming_decompress(input, input_len,
                                 output, output_max,
                                 actual_size) == 0) {
        return 0;
    }

    return -1;
}

int vtoy_xz_decompress_file(const char *input_path, const char *output_path)
{
    int fd_in = -1;
    int fd_out = -1;
    int ret = -1;
    struct stat st;
    uint8_t *mapped = MAP_FAILED;
    uint8_t *out_buf = NULL;
    size_t out_size = 0;
    size_t actual_size = 0;
    uint64_t uncompressed_hint;
    ssize_t written;

    if (!input_path || !output_path) {
        return -1;
    }

    /* Open and map the input file */
    fd_in = open(input_path, O_RDONLY);
    if (fd_in < 0) {
        return -1;
    }

    if (fstat(fd_in, &st) != 0 || st.st_size <= 0) {
        close(fd_in);
        return -1;
    }

    mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd_in, 0);
    close(fd_in);
    fd_in = -1;

    if (mapped == MAP_FAILED) {
        return -1;
    }

    /*
     * Determine output buffer size.  Try to read the uncompressed size
     * from the XZ footer first.  If that fails, use a generous default.
     */
    uncompressed_hint = vtoy_xz_get_uncompressed_size(input_path);
    if (uncompressed_hint > 0 && uncompressed_hint <= (uint64_t)4 * 1024 * 1024 * 1024) {
        out_size = (size_t)uncompressed_hint;
    } else {
        out_size = XZ_DEFAULT_OUTPUT_SIZE;
    }

    out_buf = malloc(out_size);
    if (!out_buf) {
        munmap(mapped, (size_t)st.st_size);
        return -1;
    }

    /* Attempt in-memory decompression */
    if (vtoy_xz_decompress(mapped, (size_t)st.st_size,
                            out_buf, out_size,
                            &actual_size) == 0) {

        /* Write decompressed data to output file */
        fd_out = open(output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd_out < 0) {
            goto cleanup;
        }

        written = 0;
        while ((size_t)written < actual_size) {
            ssize_t w = write(fd_out, out_buf + written,
                              actual_size - (size_t)written);
            if (w < 0) {
                close(fd_out);
                unlink(output_path);
                goto cleanup;
            }
            written += w;
        }

        close(fd_out);
        ret = 0;
        goto cleanup;
    }

    /*
     * All in-memory attempts failed.  Fall back to the system xz command.
     */
    {
        char cmd[2048];
        int cmd_len;

        cmd_len = snprintf(cmd, sizeof(cmd),
                           "xz -dk -c '%s' > '%s'", input_path, output_path);
        if (cmd_len < 0 || (size_t)cmd_len >= sizeof(cmd)) {
            goto cleanup;
        }

        ret = system(cmd);
    }

cleanup:
    if (out_buf) {
        free(out_buf);
    }
    if (mapped != MAP_FAILED) {
        munmap(mapped, (size_t)st.st_size);
    }
    return ret;
}

uint64_t vtoy_xz_get_uncompressed_size(const char *input_path)
{
    int fd = -1;
    struct stat st;
    uint8_t footer[XZ_STREAM_FOOTER_SIZE];
    uint32_t backward_size_field;
    uint32_t backward_size;
    off_t index_offset;
    uint8_t *index_buf = NULL;
    ssize_t nread;
    uint64_t uncompressed_size = 0;
    size_t pos;
    uint64_t num_records;
    uint64_t i;
    size_t consumed;

    if (!input_path) {
        return 0;
    }

    fd = open(input_path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }

    if (fstat(fd, &st) != 0 || st.st_size < (off_t)(XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE)) {
        close(fd);
        return 0;
    }

    /*
     * Read the stream footer (last 12 bytes).
     *
     * Footer layout:
     *   Bytes 0-3:  CRC32 of bytes 4-7
     *   Bytes 4-7:  Backward Size (LE uint32)
     *   Bytes 8-9:  Stream Flags
     *   Bytes 10-11: Footer Magic "YZ"
     */
    if (lseek(fd, -(off_t)XZ_STREAM_FOOTER_SIZE, SEEK_END) == (off_t)-1) {
        close(fd);
        return 0;
    }

    nread = read(fd, footer, XZ_STREAM_FOOTER_SIZE);
    if (nread != XZ_STREAM_FOOTER_SIZE) {
        close(fd);
        return 0;
    }

    /* Verify footer magic bytes */
    if (footer[10] != XZ_FOOTER_MAGIC_0 || footer[11] != XZ_FOOTER_MAGIC_1) {
        close(fd);
        return 0;
    }

    /*
     * Backward Size: stored as (real_size / 4 - 1).
     * So: real_size = (field_value + 1) * 4
     * This gives the size of the Index section including its CRC32.
     */
    backward_size_field = read_le32(&footer[4]);
    backward_size = (backward_size_field + 1) * 4;

    /*
     * The Index section is located just before the Stream Footer.
     * index_offset = file_size - footer_size - backward_size
     */
    index_offset = st.st_size - (off_t)XZ_STREAM_FOOTER_SIZE - (off_t)backward_size;
    if (index_offset < (off_t)XZ_STREAM_HEADER_SIZE || (size_t)backward_size > (size_t)st.st_size) {
        close(fd);
        return 0;
    }

    index_buf = malloc(backward_size);
    if (!index_buf) {
        close(fd);
        return 0;
    }

    if (lseek(fd, index_offset, SEEK_SET) == (off_t)-1) {
        goto fail;
    }

    nread = read(fd, index_buf, backward_size);
    close(fd);
    fd = -1;

    if (nread != (ssize_t)backward_size) {
        goto fail;
    }

    /*
     * Parse the XZ Index section:
     *
     *   Byte 0:      Index Indicator (must be 0x00)
     *   Multibyte:   Number of Records
     *   For each record:
     *     Multibyte: Unpadded Size (compressed)
     *     Multibyte: Uncompressed Size
     *   Padding to 4-byte alignment
     *   4 bytes:     CRC32
     */
    pos = 0;

    /* Index Indicator */
    if (pos >= backward_size || index_buf[pos] != 0x00) {
        goto fail;
    }
    pos++;

    /* Number of Records */
    consumed = decode_multibyte(index_buf + pos, backward_size - pos, &num_records);
    if (consumed == 0) {
        goto fail;
    }
    pos += consumed;

    /* Sum up the uncompressed sizes from all records */
    uncompressed_size = 0;
    for (i = 0; i < num_records; i++) {
        uint64_t unpadded_size;
        uint64_t uncomp;

        /* Unpadded Size (we read it but don't need it) */
        consumed = decode_multibyte(index_buf + pos, backward_size - pos, &unpadded_size);
        if (consumed == 0) {
            goto fail;
        }
        pos += consumed;

        /* Uncompressed Size */
        consumed = decode_multibyte(index_buf + pos, backward_size - pos, &uncomp);
        if (consumed == 0) {
            goto fail;
        }
        pos += consumed;

        uncompressed_size += uncomp;
    }

    free(index_buf);
    return uncompressed_size;

fail:
    if (fd >= 0) {
        close(fd);
    }
    free(index_buf);
    return 0;
}
