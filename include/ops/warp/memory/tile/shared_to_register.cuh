/**
 * @file
 * @brief Functions for transferring data directly between shared memory and registers and back.
 */

#pragma once

#include <type_traits>

#include "../../../../common/common.cuh"
#include "../../../../types/types.cuh"
#include "../util/util.cuh"

namespace kittens {

// These probably need to be redone to reduce bank conflicts.
// They currently work fine with xor layout but it should be
// possible to reduce their bank conflicts with other layouts too.

/**
 * @brief Load data from a shared tile into a register tile.
 *
 * @tparam RT The register tile type
 * @tparam ST The shared tile type
 * @param dst[out] The destination register tile.
 * @param src[in]  The source shared tile.
 */
template<ducks::rt::all RT, ducks::st::all ST>
__device__ inline static void load(RT &dst, const ST &src) {

    static_assert(RT::height == ST::height, "register tile and shared tile must match height");
    static_assert(RT::width  == ST::width,  "register tile and shared tile must match width");

    using T2 = RT::dtype;
    using T  = base_types::packing<T2>::unpacked_type;
    using U  = ST::dtype;
    using U2 = base_types::packing<U >::packed_type;

    int laneid = kittens::laneid();

    // convert to shared state space
    uint32_t shared_addr = static_cast<uint32_t>(__cvta_generic_to_shared(&src.data[0]));

    #pragma unroll
    for(int i = 0; i < dst.height; i++) {
        #pragma unroll
        for(int j = 0; j < dst.width; j++) {
            if constexpr (sizeof(typename ST::dtype) == 2) { // half and bfloat16
                // handle 16-bit types
                U2 tmp[4];
                int row = i*dst.tile_size_row + (laneid % 16);
                int col = j*dst.tile_size_col + (laneid / 16) * 8;
                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    move<U2>::ldsm4(tmp[0], tmp[1], tmp[2], tmp[3], src.idx(shared_addr, {row, col}));
                }
                else {
                    move<U2>::ldsm4t(tmp[0], tmp[2], tmp[1], tmp[3], src.idx(shared_addr, {row, col}));
                }
                dst.tiles[i][j].data[0] = base_types::convertor<T2, U2>::convert(tmp[0]);
                dst.tiles[i][j].data[1] = base_types::convertor<T2, U2>::convert(tmp[1]);
                dst.tiles[i][j].data[2] = base_types::convertor<T2, U2>::convert(tmp[2]);
                dst.tiles[i][j].data[3] = base_types::convertor<T2, U2>::convert(tmp[3]);
            }
            else if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row> && sizeof(typename ST::dtype) == 1 ) {
                // ldmatrix operates on 16-bits
                // handle the fp8 by hacking with fp8x2 16-bit types
                U2 tmp[4];
                int row = i*dst.tile_size_row + (laneid % 16);
                int col = j*dst.tile_size_col + (laneid / 16) * 16;
                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    move<U2>::ldsm4(tmp[0], tmp[1], tmp[2], tmp[3], src.idx(shared_addr, {row, col}));
                }
                else {
                    move<U2>::ldsm4t(tmp[0], tmp[2], tmp[1], tmp[3], src.idx(shared_addr, {row, col}));
                }
                dst.tiles[i][j].data[0] = base_types::convertor<T2, U2>::convert(tmp[0]);
                dst.tiles[i][j].data[1] = base_types::convertor<T2, U2>::convert(tmp[1]);
                dst.tiles[i][j].data[2] = base_types::convertor<T2, U2>::convert(tmp[2]);
                dst.tiles[i][j].data[3] = base_types::convertor<T2, U2>::convert(tmp[3]);
            }
            else if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row> && sizeof(typename ST::dtype) == 4) { // float32
                // handle the row-major layout for 32-bit types
                int row, col;
                if constexpr (ST::rows == ST::underlying_rows && ST::cols == ST::underlying_cols) {
                    row = i*dst.tile_size_row + (laneid / 4);
                    col = j*dst.tile_size_col + 2*(laneid % 4);
                }
                else {
                    row = i*dst.tile_size_row + (laneid / 4)   + src.row_offset;
                    col = j*dst.tile_size_col + 2*(laneid % 4) + src.col_offset;
                }
                int blit = sizeof(typename ST::dtype)*((laneid%4)/2);
                U2 tmp[4];
                static constexpr int swizzle_repeat = ST::swizzle_bytes * 8;
                static constexpr int subtile_cols   = ST::swizzle_bytes / sizeof(U);
                const int outer_idx = col/subtile_cols;
                const uint32_t addr_1 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+0)*subtile_cols + col%subtile_cols);
                const uint32_t addr_2 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+8)*subtile_cols + col%subtile_cols);
                const int swizzle_1 = blit ^ ((addr_1 % swizzle_repeat) >> 7) << 4;
                const int swizzle_2 = blit ^ ((addr_2 % swizzle_repeat) >> 7) << 4;
                move<U>::lds(tmp[0].x, (addr_1+ 0)^swizzle_1);
                move<U>::lds(tmp[0].y, (addr_1+ 4)^swizzle_1);
                move<U>::lds(tmp[2].x, (addr_1+32)^swizzle_1);
                move<U>::lds(tmp[2].y, (addr_1+36)^swizzle_1);
                move<U>::lds(tmp[1].x, (addr_2+ 0)^swizzle_2);
                move<U>::lds(tmp[1].y, (addr_2+ 4)^swizzle_2);
                move<U>::lds(tmp[3].x, (addr_2+32)^swizzle_2);
                move<U>::lds(tmp[3].y, (addr_2+36)^swizzle_2);
                dst.tiles[i][j].data[0] = base_types::convertor<T2, U2>::convert(tmp[0]);
                dst.tiles[i][j].data[1] = base_types::convertor<T2, U2>::convert(tmp[1]);
                dst.tiles[i][j].data[2] = base_types::convertor<T2, U2>::convert(tmp[2]);
                dst.tiles[i][j].data[3] = base_types::convertor<T2, U2>::convert(tmp[3]);
                if(blit) {
                    #pragma unroll
                    for(int k = 0; k < 4; k++) {
                        dst.tiles[i][j].data[k] = T2{dst.tiles[i][j].data[k].y, dst.tiles[i][j].data[k].x};
                    }
                }
            }
            else if constexpr (sizeof(typename ST::dtype) != 1) {
                // handle the column-major layout
                U2 tmp[4];
                int row = i*dst.tile_size_row + 2*(laneid % 4);
                int col = j*dst.tile_size_col + (laneid / 4);
                move<U>::lds(tmp[0].x, src.idx(shared_addr, {row+0, col+0}));
                move<U>::lds(tmp[0].y, src.idx(shared_addr, {row+1, col+0}));
                move<U>::lds(tmp[1].x, src.idx(shared_addr, {row+0, col+8}));
                move<U>::lds(tmp[1].y, src.idx(shared_addr, {row+1, col+8}));
                move<U>::lds(tmp[2].x, src.idx(shared_addr, {row+8, col+0}));
                move<U>::lds(tmp[2].y, src.idx(shared_addr, {row+9, col+0}));
                move<U>::lds(tmp[3].x, src.idx(shared_addr, {row+8, col+8}));
                move<U>::lds(tmp[3].y, src.idx(shared_addr, {row+9, col+8}));
                dst.tiles[i][j].data[0] = base_types::convertor<T2, U2>::convert(tmp[0]);
                dst.tiles[i][j].data[1] = base_types::convertor<T2, U2>::convert(tmp[1]);
                dst.tiles[i][j].data[2] = base_types::convertor<T2, U2>::convert(tmp[2]);
                dst.tiles[i][j].data[3] = base_types::convertor<T2, U2>::convert(tmp[3]);
            }
        }
    }
}


/**
 * @brief Store data into a shared tile from a register tile.
 *
 * @tparam RT The register tile type
 * @tparam ST The shared tile type
 * @param dst[out] The destination shared tile.
 * @param src[in]  The source register tile.
 */
template<ducks::rt::all RT, ducks::st::all ST>
__device__ inline static void store(ST &dst, const RT &src) {

    static_assert(RT::height == ST::height, "register tile and shared tile must match height");
    static_assert(RT::width  == ST::width,  "register tile and shared tile must match width");

    using T2 = RT::dtype;
    using T  = base_types::packing<T2>::unpacked_type;
    using U  = ST::dtype;
    using U2 = base_types::packing<U >::packed_type;

    // convert to shared state space
    uint32_t shared_addr = static_cast<uint32_t>(__cvta_generic_to_shared(&dst.data[0]));

    int laneid = threadIdx.x % 32;
    #pragma unroll
    for(int i = 0; i < src.height; i++) {
        #pragma unroll
        for(int j = 0; j < src.width; j++) {

            if constexpr (sizeof(typename ST::dtype) == 2) {
                // handle the 16-bit types
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[3]);
#ifdef KITTENS_HOPPER
                int row = i*src.tile_size_row + (laneid % 16);
                int col = j*src.tile_size_col + (laneid / 16) * 8;
                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    move<U2>::stsm4(dst.idx(shared_addr, {row, col}), tmp[0], tmp[1], tmp[2], tmp[3]);
                }
                else {
                    move<U2>::stsm4t(dst.idx(shared_addr, {row, col}), tmp[0], tmp[2], tmp[1], tmp[3]);
                }
#else
                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    int row = i*src.tile_size_row + (laneid / 4);
                    int col = j*src.tile_size_col + 2*(laneid % 4);
                    move<U2>::sts(dst.idx(shared_addr, {row+0, col+0}), tmp[0]);
                    move<U2>::sts(dst.idx(shared_addr, {row+8, col+0}), tmp[1]);
                    move<U2>::sts(dst.idx(shared_addr, {row+0, col+8}), tmp[2]);
                    move<U2>::sts(dst.idx(shared_addr, {row+8, col+8}), tmp[3]);
                }
                else {
                    int row = i*src.tile_size_row + 2*(laneid % 4);
                    int col = j*src.tile_size_col + (laneid / 4);
                    move<U>::sts(dst.idx(shared_addr, {row+0, col+0}), tmp[0].x);
                    move<U>::sts(dst.idx(shared_addr, {row+1, col+0}), tmp[0].y);
                    move<U>::sts(dst.idx(shared_addr, {row+0, col+8}), tmp[1].x);
                    move<U>::sts(dst.idx(shared_addr, {row+1, col+8}), tmp[1].y);
                    move<U>::sts(dst.idx(shared_addr, {row+8, col+0}), tmp[2].x);
                    move<U>::sts(dst.idx(shared_addr, {row+9, col+0}), tmp[2].y);
                    move<U>::sts(dst.idx(shared_addr, {row+8, col+8}), tmp[3].x);
                    move<U>::sts(dst.idx(shared_addr, {row+9, col+8}), tmp[3].y);
                }
#endif
            } else if constexpr (sizeof(typename ST::dtype) == 1) {
                // ldmatrix operates on 16-bits
                // handle the fp8 by hacking with fp8x2 16-bit types
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[3]);
                int row = i*src.tile_size_row + (laneid % 16);
                int col = j*src.tile_size_col + (laneid / 16) * 16;
                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    move<U2>::stsm4(dst.idx(shared_addr, {row, col}), tmp[0], tmp[1], tmp[2], tmp[3]);
                }
                else {
                    move<U2>::stsm4t(dst.idx(shared_addr, {row, col}), tmp[0], tmp[2], tmp[1], tmp[3]);
                }

            } else if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row> && sizeof(typename ST::dtype) == 4) {
                // handle the row-major layout for 32-bit types
                int row, col;
                if constexpr (ST::rows == ST::underlying_rows && ST::cols == ST::underlying_cols) {
                    row = i*src.tile_size_row + (laneid / 4);
                    col = j*src.tile_size_col + 2*(laneid % 4);
                }
                else {
                    row = i*src.tile_size_row + (laneid / 4)   + dst.row_offset;
                    col = j*src.tile_size_col + 2*(laneid % 4) + dst.col_offset;
                }
                int blit = sizeof(typename ST::dtype)*((laneid%4) / 2);
                T2 reg_tmp[4];
                if(blit) {
                    #pragma unroll
                    for(int k = 0; k < 4; k++) {
                        reg_tmp[k] = T2{src.tiles[i][j].data[k].y, src.tiles[i][j].data[k].x};
                    }
                }
                else {
                    #pragma unroll
                    for(int k = 0; k < 4; k++) {
                        reg_tmp[k] = src.tiles[i][j].data[k];
                    }
                }
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(reg_tmp[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(reg_tmp[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(reg_tmp[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(reg_tmp[3]);
                static constexpr int swizzle_repeat = ST::swizzle_bytes * 8;
                static constexpr int subtile_cols   = ST::swizzle_bytes / sizeof(U);
                const int outer_idx = col/subtile_cols;
                const uint32_t addr_1 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+0)*subtile_cols + col%subtile_cols);
                const uint32_t addr_2 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+8)*subtile_cols + col%subtile_cols);
                const int swizzle_1 = blit ^ ((addr_1 % swizzle_repeat) >> 7) << 4;
                const int swizzle_2 = blit ^ ((addr_2 % swizzle_repeat) >> 7) << 4;
                move<U>::sts((addr_1+ 0)^swizzle_1, tmp[0].x);
                move<U>::sts((addr_1+ 4)^swizzle_1, tmp[0].y);
                move<U>::sts((addr_1+32)^swizzle_1, tmp[2].x);
                move<U>::sts((addr_1+36)^swizzle_1, tmp[2].y);
                move<U>::sts((addr_2+ 0)^swizzle_2, tmp[1].x);
                move<U>::sts((addr_2+ 4)^swizzle_2, tmp[1].y);
                move<U>::sts((addr_2+32)^swizzle_2, tmp[3].x);
                move<U>::sts((addr_2+36)^swizzle_2, tmp[3].y);
            }
            else if constexpr (sizeof(typename ST::dtype) != 1) {
                // handle the column-major layout
                int row = i*src.tile_size_row + 2*(laneid % 4);
                int col = j*src.tile_size_col + (laneid / 4);
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[3]);
                move<U>::sts(dst.idx(shared_addr, {row+0, col+0}), tmp[0].x);
                move<U>::sts(dst.idx(shared_addr, {row+1, col+0}), tmp[0].y);
                move<U>::sts(dst.idx(shared_addr, {row+0, col+8}), tmp[1].x);
                move<U>::sts(dst.idx(shared_addr, {row+1, col+8}), tmp[1].y);
                move<U>::sts(dst.idx(shared_addr, {row+8, col+0}), tmp[2].x);
                move<U>::sts(dst.idx(shared_addr, {row+9, col+0}), tmp[2].y);
                move<U>::sts(dst.idx(shared_addr, {row+8, col+8}), tmp[3].x);
                move<U>::sts(dst.idx(shared_addr, {row+9, col+8}), tmp[3].y);
            }
        }
    }
}

/**
 * @brief Atomic add into a shared tile from a register tile.
 *
 * @tparam RT The register tile type
 * @tparam ST The shared tile type
 * @param dst[out] The destination shared tile.
 * @param src[in]  The source register tile.
 */
template<ducks::rt::all RT, ducks::st::all ST>
__device__ inline static void atomic_add(ST &dst, const RT &src) {

    static_assert(RT::height == ST::height, "register tile and shared tile must match height");
    static_assert(RT::width  == ST::width,  "register tile and shared tile must match width");

    static_assert(sizeof(typename ST::dtype) != 1, "atomic_add is not supported for this type");

    using T2 = RT::dtype;
    using T  = base_types::packing<T2>::unpacked_type;
    using U  = ST::dtype;
    using U2 = base_types::packing<U >::packed_type;

    // convert to shared state space
    uint32_t shared_addr = static_cast<uint32_t>(__cvta_generic_to_shared(&dst.data[0]));

    int laneid = threadIdx.x % 32;
    #pragma unroll
    for(int i = 0; i < src.height; i++) {
        #pragma unroll
        for(int j = 0; j < src.width; j++) {

            if constexpr (sizeof(typename ST::dtype) == 2) {
                // handle the 16-bit types
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[3]);

                if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row>) {
                    int row = i*src.tile_size_row + (laneid / 4);
                    int col = j*src.tile_size_col + 2*(laneid % 4);
                    atomic<U2>::adds(dst.idx(shared_addr, {row+0, col+0}), tmp[0]);
                    atomic<U2>::adds(dst.idx(shared_addr, {row+8, col+0}), tmp[1]);
                    atomic<U2>::adds(dst.idx(shared_addr, {row+0, col+8}), tmp[2]);
                    atomic<U2>::adds(dst.idx(shared_addr, {row+8, col+8}), tmp[3]);
                } else {
                    int row = i*src.tile_size_row + 2*(laneid % 4);
                    int col = j*src.tile_size_col + (laneid / 4);
                    atomic<U>::adds(dst.idx(shared_addr, {row+0, col+0}), tmp[0].x);
                    atomic<U>::adds(dst.idx(shared_addr, {row+1, col+0}), tmp[0].y);
                    atomic<U>::adds(dst.idx(shared_addr, {row+0, col+8}), tmp[1].x);
                    atomic<U>::adds(dst.idx(shared_addr, {row+1, col+8}), tmp[1].y);
                    atomic<U>::adds(dst.idx(shared_addr, {row+8, col+0}), tmp[2].x);
                    atomic<U>::adds(dst.idx(shared_addr, {row+9, col+0}), tmp[2].y);
                    atomic<U>::adds(dst.idx(shared_addr, {row+8, col+8}), tmp[3].x);
                    atomic<U>::adds(dst.idx(shared_addr, {row+9, col+8}), tmp[3].y);
                }
            } else if constexpr (std::is_same_v<typename RT::layout, ducks::rt_layout::row> && sizeof(typename ST::dtype) == 4) {
                // handle the row-major layout for 32-bit types
                int row, col;
                if constexpr (ST::rows == ST::underlying_rows && ST::cols == ST::underlying_cols) {
                    row = i*src.tile_size_row + (laneid / 4);
                    col = j*src.tile_size_col + 2*(laneid % 4);
                }
                else {
                    row = i*src.tile_size_row + (laneid / 4)   + dst.row_offset;
                    col = j*src.tile_size_col + 2*(laneid % 4) + dst.col_offset;
                }
                int blit = sizeof(typename ST::dtype)*((laneid%4) / 2);
                T2 reg_tmp[4];
                if(blit) {
                    #pragma unroll
                    for(int k = 0; k < 4; k++) {
                        reg_tmp[k] = T2{src.tiles[i][j].data[k].y, src.tiles[i][j].data[k].x};
                    }
                }
                else {
                    #pragma unroll
                    for(int k = 0; k < 4; k++) {
                        reg_tmp[k] = src.tiles[i][j].data[k];
                    }
                }
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(reg_tmp[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(reg_tmp[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(reg_tmp[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(reg_tmp[3]);
                static constexpr int swizzle_repeat = ST::swizzle_bytes * 8;
                static constexpr int subtile_cols   = ST::swizzle_bytes / sizeof(U);
                const int outer_idx = col/subtile_cols;
                const uint32_t addr_1 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+0)*subtile_cols + col%subtile_cols);
                const uint32_t addr_2 = shared_addr + sizeof(U)*(outer_idx*ST::underlying_rows*subtile_cols + (row+8)*subtile_cols + col%subtile_cols);
                const int swizzle_1 = blit ^ ((addr_1 % swizzle_repeat) >> 7) << 4;
                const int swizzle_2 = blit ^ ((addr_2 % swizzle_repeat) >> 7) << 4;
                atomic<U>::adds((addr_1+ 0)^swizzle_1, tmp[0].x);
                atomic<U>::adds((addr_1+ 4)^swizzle_1, tmp[0].y);
                atomic<U>::adds((addr_1+32)^swizzle_1, tmp[2].x);
                atomic<U>::adds((addr_1+36)^swizzle_1, tmp[2].y);
                atomic<U>::adds((addr_2+ 0)^swizzle_2, tmp[1].x);
                atomic<U>::adds((addr_2+ 4)^swizzle_2, tmp[1].y);
                atomic<U>::adds((addr_2+32)^swizzle_2, tmp[3].x);
                atomic<U>::adds((addr_2+36)^swizzle_2, tmp[3].y);
            }
            else if constexpr (sizeof(typename ST::dtype) != 1) {
                // handle the column-major layout
                int row = i*src.tile_size_row + 2*(laneid % 4);
                int col = j*src.tile_size_col + (laneid / 4);
                U2 tmp[4];
                tmp[0] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[0]);
                tmp[1] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[1]);
                tmp[2] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[2]);
                tmp[3] = base_types::convertor<U2, T2>::convert(src.tiles[i][j].data[3]);
                atomic<U>::adds(dst.idx(shared_addr, {row+0, col+0}), tmp[0].x);
                atomic<U>::adds(dst.idx(shared_addr, {row+1, col+0}), tmp[0].y);
                atomic<U>::adds(dst.idx(shared_addr, {row+0, col+8}), tmp[1].x);
                atomic<U>::adds(dst.idx(shared_addr, {row+1, col+8}), tmp[1].y);
                atomic<U>::adds(dst.idx(shared_addr, {row+8, col+0}), tmp[2].x);
                atomic<U>::adds(dst.idx(shared_addr, {row+9, col+0}), tmp[2].y);
                atomic<U>::adds(dst.idx(shared_addr, {row+8, col+8}), tmp[3].x);
                atomic<U>::adds(dst.idx(shared_addr, {row+9, col+8}), tmp[3].y);
            }
        }
    }
}

} // namespace kittens