/**
 * Copyright (c) 2011, CESNET z.s.p.o
 * Copyright (c) 2011, Silicon Genome, LLC.
 *
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
 
#include "gpujpeg_huffman_gpu_encoder.h"
#include "gpujpeg_util.h"

#define WARPS_NUM 8


#ifdef GPUJPEG_HUFFMAN_CODER_TABLES_IN_CONSTANT
/** Allocate huffman tables in constant memory */
__constant__ struct gpujpeg_table_huffman_encoder gpujpeg_huffman_gpu_encoder_table_huffman[GPUJPEG_COMPONENT_TYPE_COUNT][GPUJPEG_HUFFMAN_TYPE_COUNT];
/** Pass huffman tables to encoder */
extern struct gpujpeg_table_huffman_encoder (*gpujpeg_encoder_table_huffman)[GPUJPEG_COMPONENT_TYPE_COUNT][GPUJPEG_HUFFMAN_TYPE_COUNT] = &gpujpeg_huffman_gpu_encoder_table_huffman;
#endif

/** Natural order in constant memory */
__constant__ int gpujpeg_huffman_gpu_encoder_order_natural[GPUJPEG_ORDER_NATURAL_SIZE];

/**
 * Write one byte to compressed data
 * 
 * @param data_compressed  Data compressed
 * @param value  Byte value to write
 * @return void
 */
#define gpujpeg_huffman_gpu_encoder_emit_byte(data_compressed, value) { \
    *data_compressed = (uint8_t)(value); \
    data_compressed++; }
    
/**
 * Write two bytes to compressed data
 * 
 * @param data_compressed  Data compressed
 * @param value  Two-byte value to write
 * @return void
 */
#define gpujpeg_huffman_gpu_encoder_emit_2byte(data_compressed, value) { \
    *data_compressed = (uint8_t)(((value) >> 8) & 0xFF); \
    data_compressed++; \
    *data_compressed = (uint8_t)((value) & 0xFF); \
    data_compressed++; }
    
/**
 * Write marker to compressed data
 * 
 * @param data_compressed  Data compressed
 * @oaran marker  Marker to write (JPEG_MARKER_...)
 * @return void
 */
#define gpujpeg_huffman_gpu_encoder_marker(data_compressed, marker) { \
    *data_compressed = 0xFF;\
    data_compressed++; \
    *data_compressed = (uint8_t)(marker); \
    data_compressed++; }

/**
 * Output bits to the file. Only the right 24 bits of put_buffer are used; 
 * the valid bits are left-justified in this part.  At most 16 bits can be 
 * passed to EmitBits in one call, and we never retain more than 7 bits 
 * in put_buffer between calls, so 24 bits are sufficient.
 * 
 * @param coder  Huffman coder structure
 * @param code  Huffman code
 * @param size  Size in bits of the Huffman code
 * @return void
 */
__device__ inline int
gpujpeg_huffman_gpu_encoder_emit_bits(unsigned int code, int size, int & put_value, int & put_bits, uint8_t* & data_compressed)
{
    // This routine is heavily used, so it's worth coding tightly
    int _put_buffer = (int)code;
    int _put_bits = put_bits;
    // If size is 0, caller used an invalid Huffman table entry
    if ( size == 0 )
        return -1;
    // Mask off any extra bits in code
    _put_buffer &= (((int)1) << size) - 1; 
    // New number of bits in buffer
    _put_bits += size;                    
    // Align incoming bits
    _put_buffer <<= 24 - _put_bits;        
    // And merge with old buffer contents
    _put_buffer |= put_value;    
    // If there are more than 8 bits, write it out
    unsigned char uc;
    while ( _put_bits >= 8 ) {
        // Write one byte out
        uc = (unsigned char) ((_put_buffer >> 16) & 0xFF);
        gpujpeg_huffman_gpu_encoder_emit_byte(data_compressed, uc);
        // If need to stuff a zero byte
        if ( uc == 0xFF ) {  
            // Write zero byte out
            gpujpeg_huffman_gpu_encoder_emit_byte(data_compressed, 0);
        }
        _put_buffer <<= 8;
        _put_bits -= 8;
    }
    // update state variables
    put_value = _put_buffer; 
    put_bits = _put_bits;
    return 0;
}

/**
 * Emit left bits
 * 
 * @param coder  Huffman coder structure
 * @return void
 */
__device__ inline void
gpujpeg_huffman_gpu_encoder_emit_left_bits(int & put_value, int & put_bits, uint8_t* & data_compressed)
{
    // Fill 7 bits with ones
    if ( gpujpeg_huffman_gpu_encoder_emit_bits(0x7F, 7, put_value, put_bits, data_compressed) != 0 )
        return;
    
    //unsigned char uc = (unsigned char) ((put_value >> 16) & 0xFF);
    // Write one byte out
    //gpujpeg_huffman_gpu_encoder_emit_byte(data_compressed, uc);
    
    put_value = 0; 
    put_bits = 0;
}

/**
 * Decomposes given value into number of bits and one's complement value.
 */
__device__ void
gpujpeg_huffman_gpu_encoder_decompose(int in_value, int & nbits, int & out_value) {
    out_value = in_value;
    if ( in_value < 0 ) {
        // Temp is abs value of input
        in_value = -in_value;
        // For a negative input, want temp2 = bitwise complement of abs(input)
        // This code assumes we are on a two's complement machine
        out_value--;
    }

    // Find the number of bits needed for the magnitude of the coefficient
    nbits = 0;
    while ( in_value ) {
        nbits++;
        in_value >>= 1;
    }
}




/**
 * Encode one 8x8 block
 *
 * @return 0 if succeeds, otherwise nonzero
 */
__device__ int
gpujpeg_huffman_gpu_encoder_encode_block(int & put_value, int & put_bits, int & dc, int16_t* data, uint8_t* & data_compressed, 
    struct gpujpeg_table_huffman_encoder* d_table_dc, struct gpujpeg_table_huffman_encoder* d_table_ac)
{
    // Encode the DC coefficient difference per section F.1.2.1
    int temp = data[0] - dc;
    dc = data[0];
    
    int temp2 = temp;
    if ( temp < 0 ) {
        // Temp is abs value of input
        temp = -temp;
        // For a negative input, want temp2 = bitwise complement of abs(input)
        // This code assumes we are on a two's complement machine
        temp2--;
    }

    // Find the number of bits needed for the magnitude of the coefficient
    int nbits = 0;
    while ( temp ) {
        nbits++;
        temp >>= 1;
    }

    // Write category number
    if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_dc->code[nbits], d_table_dc->size[nbits], put_value, put_bits, data_compressed) != 0 ) {
        return -1;
    }

    // Write category offset (EmitBits rejects calls with size 0)
    if ( nbits ) {
        if ( gpujpeg_huffman_gpu_encoder_emit_bits((unsigned int) temp2, nbits, put_value, put_bits, data_compressed) != 0 )
            return -1;
    }
    
    // Encode the AC coefficients per section F.1.2.2 (r = run length of zeros)
    int r = 0;
    for ( int k = 1; k < 64; k++ ) 
    {
        temp = data[gpujpeg_huffman_gpu_encoder_order_natural[k]];
        if ( temp == 0 ) {
            r++;
        }
        else {
            // If run length > 15, must emit special run-length-16 codes (0xF0)
            while ( r > 15 ) {
                if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[0xF0], d_table_ac->size[0xF0], put_value, put_bits, data_compressed) != 0 )
                    return -1;
                r -= 16;
            }

            temp2 = temp;
            if ( temp < 0 ) {
                // temp is abs value of input
                temp = -temp;        
                // This code assumes we are on a two's complement machine
                temp2--;
            }

            // Find the number of bits needed for the magnitude of the coefficient
            // there must be at least one 1 bit
            nbits = 1;
            while ( (temp >>= 1) )
                nbits++;

            // Emit Huffman symbol for run length / number of bits
            int i = (r << 4) + nbits;
            if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[i], d_table_ac->size[i], put_value, put_bits, data_compressed) != 0 )
                return -1;

            // Write Category offset
            if ( gpujpeg_huffman_gpu_encoder_emit_bits((unsigned int) temp2, nbits, put_value, put_bits, data_compressed) != 0 )
                return -1;

            r = 0;
        }
    }

    // If all the left coefs were zero, emit an end-of-block code
    if ( r > 0 ) {
        if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[0], d_table_ac->size[0], put_value, put_bits, data_compressed) != 0 )
            return -1;
    }

    return 0;
}



__device__ void
gpujpeg_huffman_gpu_encoder_emit_left_bits(uint8_t * &data_compressed, int * s_out, int &out_size, int tid) {
    if(0 == tid) {
        int & put_value = s_out[0];
        int & put_bits = s_out[1];
        if(out_size == 0) {
            put_value = 0;
            put_bits = 0;
            out_size = 1;
        }
        gpujpeg_huffman_gpu_encoder_emit_left_bits(put_value, put_bits, data_compressed);
    }
}

/**
 * Encode one 8x8 block
 *
 * @return 0 if succeeds, otherwise nonzero
 */
__device__ int
gpujpeg_huffman_gpu_encoder_encode_block(int16_t * block, uint8_t * &data_compressed, int * s_in, int * s_out, int &out_size, int *last_dc, int tid,
                struct gpujpeg_table_huffman_encoder* d_table_dc, struct gpujpeg_table_huffman_encoder* d_table_ac)
{
    int result = 0;
    if(0 == tid) {
        int & dc = *last_dc;
        int & put_value = s_out[0];
        int & put_bits = s_out[1];
        if(out_size == 0) {
            put_value = 0;
            put_bits = 0;
            out_size = 1;
        }
        result = gpujpeg_huffman_gpu_encoder_encode_block(put_value, put_bits, dc, block, data_compressed, d_table_dc, d_table_ac);
    }
    return __ballot(result);
    
    
//     // each thread loads pair of values (pair after zigzag reordering)
//     const int load_idx = tid * 2;
//     int in_even = block[gpujpeg_huffman_gpu_encoder_order_natural[load_idx]];
//     const int in_odd = block[gpujpeg_huffman_gpu_encoder_order_natural[load_idx + 1]];
//     
//     // compute count of consecutive zeros before even value
//     // TODO: reimplement after getting it all to work
//     const int zeros_before_even = 0; // TODO implement anyhow (NOTE: first DC coefficient is treated as nonzero)
//     
//     // TODO: set to true if any nonzero value follows thread's even value
//     const bool nonzero_follows = true;
//     
//     // count of consecutive zeros before odd value (either one more than 
//     // even if even is zero or none if even value itself is nonzero)
//     const int zeros_before_odd = in_even ? 0 : zeros_before_even + 1;
//     
//     // pointer to LUT for encoding thread's even value 
//     // (only thread #0 uses DC table, others use AC table)
//     const struct gpujpeg_table_huffman_encoder * d_table_even = d_table_ac;
//     
//     // first thread handles special DC coefficient
//     if(0 == tid) {
//         // first thread uses DC table for its even value
//         d_table_even = d_table_dc;
//         
//         // update last DC coefficient
//         const int original_in_even = in_even;
//         in_even -= last_dc;
//         last_dc = original_in_even;
//     }
//     
//     // decompose the even value into bit length and one's complement value
//     int even_bit_size = 0, even_code = 0, even_out_size = 0, even_out_bits = in_even;
//     if(in_even || tid == 0) {
//         gpujpeg_huffman_gpu_encoder_decompose(in_even, even_bit_size, even_code);
//     } else if((zeros_before_even & 15) == 15) {
//         even_bit_size = 0xF0;
//     }
//     
//     // encode even value's code if any of following holds:
//     //  - thread index == 0
//     //  - even value is nonzero
//     //  - 16th zero in row
//     if(even_bit_size || tid == 0) {
//         // encode the value itself only if nonzero or in first thread
//         if(in_even || tid == 0) {
//             even_out_size = even_bit_size;
//         }
//         
//         // prepend with value's size (or 16 zero code)
//         const int code_idx = (zeros_before_even << 4) + even_bit_size;
//         const int code_size = d_table_even->size[code_idx];
//         even_out_bits <<= code_size;
//         even_out_bits |= d_table_even->code[code_idx];
//     }
//     
//     
//     
//     // encode odd value - only if 16th zero, or last and zero or nonzero
//     int even_bit_size
//     if()
//     
//     
//     typedef uint64_t loading_t;
//     const int loading_iteration_count = 64 * 2 / sizeof(loading_t);
//     
//     // Load block to shared memory
//     __shared__ int16_t s_data[64 * THREAD_BLOCK_SIZE];
//     for ( int i = 0; i < loading_iteration_count; i++ ) {
//         ((loading_t*)s_data)[loading_iteration_count * threadIdx.x + i] = ((loading_t*)data)[i];
//     }
//     int data_start = 64 * threadIdx.x;
// 
//     // Encode the DC coefficient difference per section F.1.2.1
//     int temp = s_data[data_start + 0] - dc;
//     dc = s_data[data_start + 0];
//     
//     int temp2 = temp;
//     if ( temp < 0 ) {
//         // Temp is abs value of input
//         temp = -temp;
//         // For a negative input, want temp2 = bitwise complement of abs(input)
//         // This code assumes we are on a two's complement machine
//         temp2--;
//     }
// 
//     // Find the number of bits needed for the magnitude of the coefficient
//     int nbits = 0;
//     while ( temp ) {
//         nbits++;
//         temp >>= 1;
//     }
// 
//     // Write category number
//     if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_dc->code[nbits], d_table_dc->size[nbits], put_value, put_bits, data_compressed) != 0 ) {
//         return -1;
//     }
// 
//     // Write category offset (EmitBits rejects calls with size 0)
//     if ( nbits ) {
//         if ( gpujpeg_huffman_gpu_encoder_emit_bits((unsigned int) temp2, nbits, put_value, put_bits, data_compressed) != 0 )
//             return -1;
//     }
//     
//     // Encode the AC coefficients per section F.1.2.2 (r = run length of zeros)
//     int r = 0;
//     for ( int k = 1; k < 64; k++ ) 
//     {
//         temp = s_data[data_start + gpujpeg_huffman_gpu_encoder_order_natural[k]];
//         if ( temp == 0 ) {
//             r++;
//         }
//         else {
//             // If run length > 15, must emit special run-length-16 codes (0xF0)
//             while ( r > 15 ) {
//                 if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[0xF0], d_table_ac->size[0xF0], put_value, put_bits, data_compressed) != 0 )
//                     return -1;
//                 r -= 16;
//             }
// 
//             temp2 = temp;
//             if ( temp < 0 ) {
//                 // temp is abs value of input
//                 temp = -temp;        
//                 // This code assumes we are on a two's complement machine
//                 temp2--;
//             }
// 
//             // Find the number of bits needed for the magnitude of the coefficient
//             // there must be at least one 1 bit
//             nbits = 1;
//             while ( (temp >>= 1) )
//                 nbits++;
// 
//             // Emit Huffman symbol for run length / number of bits
//             int i = (r << 4) + nbits;
//             if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[i], d_table_ac->size[i], put_value, put_bits, data_compressed) != 0 )
//                 return -1;
// 
//             // Write Category offset
//             if ( gpujpeg_huffman_gpu_encoder_emit_bits((unsigned int) temp2, nbits, put_value, put_bits, data_compressed) != 0 )
//                 return -1;
// 
//             r = 0;
//         }
//     }
// 
//     // If all the left coefs were zero, emit an end-of-block code
//     if ( r > 0 ) {
//         if ( gpujpeg_huffman_gpu_encoder_emit_bits(d_table_ac->code[0], d_table_ac->size[0], put_value, put_bits, data_compressed) != 0 )
//             return -1;
//     }
// 
//     return 0;
}

/**
 * Huffman encoder kernel
 * 
 * @return void
 */
__global__ void
gpujpeg_huffman_encoder_encode_kernel(
    struct gpujpeg_component* d_component,
    struct gpujpeg_segment* d_segment,
    int comp_count,
    int segment_count, 
    uint8_t* d_data_compressed
#ifndef GPUJPEG_HUFFMAN_CODER_TABLES_IN_CONSTANT
    ,struct gpujpeg_table_huffman_encoder* d_table_y_dc
    ,struct gpujpeg_table_huffman_encoder* d_table_y_ac
    ,struct gpujpeg_table_huffman_encoder* d_table_cbcr_dc
    ,struct gpujpeg_table_huffman_encoder* d_table_cbcr_ac
#endif
)
{    
#ifdef GPUJPEG_HUFFMAN_CODER_TABLES_IN_CONSTANT
    // Get huffman tables from constant memory
    struct gpujpeg_table_huffman_encoder* d_table_y_dc = &gpujpeg_huffman_gpu_encoder_table_huffman[GPUJPEG_COMPONENT_LUMINANCE][GPUJPEG_HUFFMAN_DC];
    struct gpujpeg_table_huffman_encoder* d_table_y_ac = &gpujpeg_huffman_gpu_encoder_table_huffman[GPUJPEG_COMPONENT_LUMINANCE][GPUJPEG_HUFFMAN_AC];
    struct gpujpeg_table_huffman_encoder* d_table_cbcr_dc = &gpujpeg_huffman_gpu_encoder_table_huffman[GPUJPEG_COMPONENT_CHROMINANCE][GPUJPEG_HUFFMAN_DC];
    struct gpujpeg_table_huffman_encoder* d_table_cbcr_ac = &gpujpeg_huffman_gpu_encoder_table_huffman[GPUJPEG_COMPONENT_CHROMINANCE][GPUJPEG_HUFFMAN_AC];
#endif
    
    int warpidx  = threadIdx.x >> 5;
    int tid    = threadIdx.x & 31;
    int out_size = 0;

    __shared__ int s_in_all[64 * WARPS_NUM];
    __shared__ int s_out_all[192 * WARPS_NUM];

    int * s_in  =  s_in_all + warpidx * 64;
    int * s_out = s_out_all + warpidx * 192;
    
    // Select Segment
    int segment_index = blockIdx.x * WARPS_NUM + warpidx;
    if ( segment_index >= segment_count )
        return;
    
    struct gpujpeg_segment* segment = &d_segment[segment_index];
    
    // Initialize huffman coder
    int dc[GPUJPEG_MAX_COMPONENT_COUNT]; //TODO pouze prvni vlakno
    for ( int comp = 0; comp < GPUJPEG_MAX_COMPONENT_COUNT; comp++ )
        dc[comp] = 0;
    
    // Prepare data pointers
    uint8_t * data_compressed = &d_data_compressed[segment->data_compressed_index]; //TODO zmeni datovy typ
    uint8_t * data_compressed_start = data_compressed;
    
    // Non-interleaving mode
    if ( comp_count == 1 ) {
        int segment_index = segment->scan_segment_index; //TODO tento index muze byt jiny nez byl segment_index vyse?

        // Get component for current scan
        struct gpujpeg_component* component = &d_component[segment->scan_index];

        // Get component data for MCU (first block)
        int16_t* block = &component->d_data_quantized[(segment_index * component->segment_mcu_count) * component->mcu_size];
        //int16_t* block = &component->d_data_quantized[(segment_index * component->segment_mcu_count + mcu_index) * component->mcu_size];

        // Get coder parameters
        int & last_dc = dc[segment->scan_index];

        // Get huffman tables
        struct gpujpeg_table_huffman_encoder* d_table_dc = NULL;
        struct gpujpeg_table_huffman_encoder* d_table_ac = NULL;
        if ( component->type == GPUJPEG_COMPONENT_LUMINANCE ) {
            d_table_dc = d_table_y_dc;
            d_table_ac = d_table_y_ac;
        } else {
            d_table_dc = d_table_cbcr_dc;
            d_table_ac = d_table_cbcr_ac;
        }
            
        // Encode MCUs in segment
        for ( int mcu_index = 0; mcu_index < segment->mcu_count; mcu_index++ ) {
            // Encode 8x8 block
            if (gpujpeg_huffman_gpu_encoder_encode_block(block, data_compressed, s_in, s_out, out_size, &last_dc, tid, d_table_dc, d_table_ac) != 0)
                break;
            block += component->mcu_size;
        }
    }
#if 0
    // Interleaving mode
    else {
        int segment_index = segment->scan_segment_index;
        // Encode MCUs in segment
        for ( int mcu_index = 0; mcu_index < segment->mcu_count; mcu_index++ ) {
            //assert(segment->scan_index == 0);
            for ( int comp = 0; comp < comp_count; comp++ ) {
                struct gpujpeg_component* component = &d_component[comp];

                // Prepare mcu indexes
                int mcu_index_x = (segment_index * component->segment_mcu_count + mcu_index) % component->mcu_count_x;
                int mcu_index_y = (segment_index * component->segment_mcu_count + mcu_index) / component->mcu_count_x;
                // Compute base data index
                int data_index_base = mcu_index_y * (component->mcu_size * component->mcu_count_x) + mcu_index_x * (component->mcu_size_x * GPUJPEG_BLOCK_SIZE);
                
                // For all vertical 8x8 blocks
                for ( int y = 0; y < component->sampling_factor.vertical; y++ ) {
                    // Compute base row data index
                    int data_index_row = data_index_base + y * (component->mcu_count_x * component->mcu_size_x * GPUJPEG_BLOCK_SIZE);
                    // For all horizontal 8x8 blocks
                    for ( int x = 0; x < component->sampling_factor.horizontal; x++ ) {
                        // Compute 8x8 block data index
                        int data_index = data_index_row + x * GPUJPEG_BLOCK_SIZE * GPUJPEG_BLOCK_SIZE;
                        
                        // Get component data for MCU
                        int16_t* block = &component->d_data_quantized[data_index];
                        
                        // Get coder parameters
                        int & component_dc = dc[comp];
            
                        // Get huffman tables
                        struct gpujpeg_table_huffman_encoder* d_table_dc = NULL;
                        struct gpujpeg_table_huffman_encoder* d_table_ac = NULL;
                        if ( component->type == GPUJPEG_COMPONENT_LUMINANCE ) {
                            d_table_dc = d_table_y_dc;
                            d_table_ac = d_table_y_ac;
                        } else {
                            d_table_dc = d_table_cbcr_dc;
                            d_table_ac = d_table_cbcr_ac;
                        }
                        
                        // Encode 8x8 block
                        gpujpeg_huffman_gpu_encoder_encode_block(put_value, put_bits, component_dc, block, data_compressed, d_table_dc, d_table_ac);
                    }
                }
            }
        }
    }
#endif

    // Emit left bits
    gpujpeg_huffman_gpu_encoder_emit_left_bits(data_compressed, s_out, out_size, tid);

    // Output restart marker
    if (tid == 0 ) {
        int restart_marker = GPUJPEG_MARKER_RST0 + (segment->scan_segment_index % 8);
        gpujpeg_huffman_gpu_encoder_marker(data_compressed, restart_marker);
                
        // Set compressed size
        segment->data_compressed_size = data_compressed - data_compressed_start;
    }
    __syncthreads();
}

/** Documented at declaration */
int
gpujpeg_huffman_gpu_encoder_init()
{
    // Copy natural order to constant device memory
    cudaMemcpyToSymbol(
        (const char*)gpujpeg_huffman_gpu_encoder_order_natural,
        gpujpeg_order_natural, 
        GPUJPEG_ORDER_NATURAL_SIZE * sizeof(int),
        0,
        cudaMemcpyHostToDevice
    );
    gpujpeg_cuda_check_error("Huffman encoder init");
    
    return 0;
}

/** Documented at declaration */
int
gpujpeg_huffman_gpu_encoder_encode(struct gpujpeg_encoder* encoder)
{    
    // Get coder
    struct gpujpeg_coder* coder = &encoder->coder;
    
    assert(coder->param.restart_interval > 0);
    
    int comp_count = 1;
    if ( coder->param.interleaved == 1 )
        comp_count = coder->param_image.comp_count;
    assert(comp_count >= 1 && comp_count <= GPUJPEG_MAX_COMPONENT_COUNT);

    // Configure more shared memory
    cudaFuncSetCacheConfig(gpujpeg_huffman_encoder_encode_kernel, cudaFuncCachePreferShared);
            
    // Run kernel
    dim3 thread(32 * WARPS_NUM);
    dim3 grid(gpujpeg_div_and_round_up(coder->segment_count, (thread.x / 32)));
    gpujpeg_huffman_encoder_encode_kernel<<<grid, thread>>>(
        coder->d_component, 
        coder->d_segment, 
        comp_count,
        coder->segment_count, 
        coder->d_data_compressed
    #ifndef GPUJPEG_HUFFMAN_CODER_TABLES_IN_CONSTANT
        ,encoder->d_table_huffman[GPUJPEG_COMPONENT_LUMINANCE][GPUJPEG_HUFFMAN_DC]
        ,encoder->d_table_huffman[GPUJPEG_COMPONENT_LUMINANCE][GPUJPEG_HUFFMAN_AC]
        ,encoder->d_table_huffman[GPUJPEG_COMPONENT_CHROMINANCE][GPUJPEG_HUFFMAN_DC]
        ,encoder->d_table_huffman[GPUJPEG_COMPONENT_CHROMINANCE][GPUJPEG_HUFFMAN_AC]
    #endif
    );
    cudaThreadSynchronize();
    gpujpeg_cuda_check_error("Huffman encoding failed");
    
    return 0;
}
