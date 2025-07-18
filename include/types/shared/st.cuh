/**
 * @file
 * @brief The ThunderKittens shared tile struct.
 */

#pragma once

#include "../../common/common.cuh"
#include "sv.cuh"

/* ----------  MAIN TILE STRUCT  ---------- */

// these are helper structs for type inference
namespace kittens {
namespace ducks {
/**
 * @namespace rt
 *
 * @brief The namespace where concepts and abstract types for shared tiles live.
 */
namespace st {
/**
 * @brief A dummy type used to identify shared tiles.
 *
 * For a type to quack like an st, it should define its identifier as ducks::st::identifier.
 * If a type quacks like ducks::st::identifier, it will be treated as an st by compiler checks.
 * This is particularly useful for subtiles.
 */
struct identifier {};
}
} // namespace ducks

// Forward declaration of subtile
template<
    typename ST,
    int _subtile_height,
    int _subtile_width
>
struct st_subtile;

/**
 * @brief Shared memory tile structure for various data types and layouts.
 *
 * @tparam T The data type of the elements in the tile. Not packed!
 * @tparam _rows The height of the tile.
 * @tparam _cols The width of the tile.
 */
template<typename _T, int _rows, int _cols>
struct KITTENS_DEFAULT_ALIGN st {
    using identifier = ducks::st::identifier; ///< Type identifier for shared memory tile.
    using T = base_types::packing<_T>::unpacked_type;
    using T2 = base_types::packing<_T>::packed_type;
    using dtype = T; ///< Data type of the elements in the tile.

    // define underlying data as same as that projected, to make clear that this is *not* a subtile.
    static constexpr int underlying_rows          = _rows;
    static constexpr int underlying_cols          = _cols;
    static constexpr int underlying_height        = _rows / kittens::TILE_ROW_DIM<T>;
    static constexpr int underlying_width         = _cols / kittens::TILE_COL_DIM<T>;
    static constexpr int underlying_num_elements  = underlying_rows * underlying_cols;

    static constexpr int rows                = _rows; ///< Total number of rows in the tile.
    static_assert(rows % kittens::TILE_ROW_DIM<T> == 0, "Rows must be divisible by the tile dimension");
    static constexpr int cols                = _cols; ///< Total number of cols in the tile.
    static_assert(cols % kittens::TILE_COL_DIM<T> == 0, "Cols must be divisible by the tile dimension");
    static constexpr int height              = _rows / kittens::TILE_ROW_DIM<T>; ///< Height of the tile in terms of 16-element subtiles.
    static constexpr int width               = _cols / kittens::TILE_COL_DIM<T>; ///< Width of the tile in terms of 16-element subtiles.
    static constexpr int num_elements        = rows * cols; ///< Total number of elements in the tile.

    static_assert(base_types::packing<dtype>::num() == 1); // must be a 1-packed type (e.g. float, bf16, etc)

    static constexpr int swizzle_bytes = (
        sizeof(dtype) == 1 ? (  // Add FP8 case
            underlying_width%4 == 0 ? 128 :
            underlying_width%2 == 0 ?  64 : 32
        ) :
        sizeof(dtype) == 2 ? (
            underlying_width%4 == 0 ? 128 :
            underlying_width%2 == 0 ?  64 : 32
        ) :
        sizeof(dtype) == 4 ? (
            underlying_width%2 == 0 ? 128 : 64
        ) : -1
    );

    // wgmma layout with swizzling
    dtype data[rows*cols]; ///< Raw data storage for the tile.

    __device__ static inline T* idx(T *ptr, int2 coord) { // naive row-major coord default
        int r = coord.x, c = coord.y; // alias
        static constexpr int swizzle_repeat = swizzle_bytes * 8;
        static constexpr int subtile_cols   = swizzle_bytes / sizeof(T);
        const int outer_idx = c/subtile_cols;
        const uint64_t addr = (uint64_t)(&ptr[outer_idx*rows*subtile_cols + r*subtile_cols + c%subtile_cols]);
        const int swizzle = ((addr % swizzle_repeat) >> 7) << 4;
        return (T*)(addr ^ swizzle);
    }
    __device__ static inline uint32_t idx(uint32_t ptr, int2 coord) {
        int r = coord.x, c = coord.y; // alias
        static constexpr int swizzle_repeat = swizzle_bytes * 8;
        static constexpr int subtile_cols   = swizzle_bytes / sizeof(T);
        const int outer_idx = c/subtile_cols;
        const uint32_t addr = ptr + sizeof(T)*(outer_idx*rows*subtile_cols + r*subtile_cols + c%subtile_cols);
        const int swizzle = ((addr % swizzle_repeat) >> 7) << 4;
        return (addr ^ swizzle);
    }
    /**
     * @brief Access a shared tile element using a row and column, as if the tile were row-major.
     *
     * This is the preferred way to access memory within a shared tile, which abstracts
     * indexing calculations for swizzled layouts.
     */
    __device__ inline       dtype& operator[](const int2 &rowcol)       {
        return *idx(data, rowcol);
    }
    __device__ inline const dtype& operator[](const int2 &rowcol) const {
        return *(const dtype*)idx((dtype*)data, rowcol);
    }
    __device__ inline       dtype& operator[](int idx)       {
        return data[idx];
    }
    __device__ inline const dtype& operator[](int idx) const {
        return data[idx];
    }

    // vector types
    using col_vec = sv<dtype, rows>; ///< Column vector type for this tile
    using row_vec = sv<dtype, cols>; ///< Row vector type for this tile
    template<int subtile_rows, int subtile_cols> using subtile = st_subtile<
        st<T, rows, cols>, subtile_rows, subtile_cols
    >; ///< A templated subtile type wrapper for this tile.
};



/**
 * @brief A reference into a chunk of shared tile memory.
 *
 * The st_subtile is a drop-in replacement for an st which internally
 * references the appropriate memory while performing minimal address
 * calculations. You should never create this directly, but instead
 * have subtile_inplace return it for you instead. (`auto` is nice.)
 *
 * You can generally just pretend this is an st. But not for wgmma's.
 */
template<
    typename _ST,
    int _subtile_rows,
    int _subtile_cols
>
struct st_subtile {
    using identifier = ducks::st::identifier; // i quack like an st, gcc will never know the difference
    using ST = _ST;
    using T = ST::T;
    using T2 = ST::T2;
    using dtype = T; ///< Data type of the elements in the tile.

    static constexpr int underlying_rows          = ST::underlying_rows;
    static_assert(underlying_rows % kittens::TILE_ROW_DIM<T> == 0, "Underlying rows must be divisible by the tile dimension");
    static constexpr int underlying_cols          = ST::underlying_cols;
    static_assert(underlying_cols % kittens::TILE_COL_DIM<T> == 0, "Underlying cols must be divisible by the tile dimension");
    static constexpr int underlying_height        = ST::underlying_height;
    static constexpr int underlying_width         = ST::underlying_width;
    static constexpr int underlying_num_elements  = ST::underlying_num_elements;

    static constexpr int rows                = _subtile_rows;
    static_assert(rows % kittens::TILE_ROW_DIM<T> == 0, "Rows must be divisible by the tile dimension");
    static constexpr int cols                = _subtile_cols;
    static_assert(cols % kittens::TILE_COL_DIM<T> == 0, "Cols must be divisible by the tile dimension");
    static constexpr int height              = rows / kittens::TILE_ROW_DIM<T>;
    static constexpr int width               = cols / kittens::TILE_COL_DIM<T>;
    static constexpr int num_elements        = rows * cols;

    static constexpr int swizzle_bytes = ST::swizzle_bytes;

    dtype *data;
    int row_offset, col_offset;

    __device__ st_subtile(ST &src, int2 rowcol) {
        data = &src.data[0];
        row_offset = rowcol.x * rows;
        col_offset = rowcol.y * cols;
    }

    __device__ inline T* idx(T *ptr, const int2 coord) { // naive row-major coord default
        int r = coord.x+row_offset, c = coord.y+col_offset; // alias
        static constexpr int swizzle_repeat = swizzle_bytes * 8;
        static constexpr int subtile_cols   = swizzle_bytes / sizeof(T);
        const int outer_idx = c/subtile_cols;
        const uint64_t addr = (uint64_t)(&ptr[outer_idx*underlying_rows*subtile_cols + r*subtile_cols + c%subtile_cols]);
        const int swizzle = ((addr % swizzle_repeat) >> 7) << 4;
        return (T*)(addr ^ swizzle);
    }
    __device__ inline uint32_t idx(uint32_t ptr, const int2 coord) const { // naive row-major coord default
        int r = coord.x+row_offset, c = coord.y+col_offset; // alias
        static constexpr int swizzle_repeat = swizzle_bytes * 8;
        static constexpr int subtile_cols   = swizzle_bytes / sizeof(T);
        const int outer_idx = c/subtile_cols;
        const uint32_t addr = ptr + sizeof(T)*(outer_idx*underlying_rows*subtile_cols + r*subtile_cols + c%subtile_cols);
        const int swizzle = ((addr % swizzle_repeat) >> 7) << 4;
        return (addr ^ swizzle);
    }
    /**
     * @brief Access a shared tile element using a row and column, as if the tile were row-major.
     *
     * This is the preferred way to access memory within a shared tile, which abstracts
     * indexing calculations for swizzled layouts.
     */
    __device__ inline       dtype& operator[](const int2 &rowcol)       {
        return *idx(data, rowcol);
    }
    __device__ inline const dtype& operator[](const int2 &rowcol) const {
        return *(const dtype*)idx((dtype*)data, rowcol);
    }

    // single-coord operator[] is left undefined as it would likely be an improper use of st_subtile type.
    // can of course be end-run by just accessing .data directly.

    // vector types
    using col_vec = sv<dtype, rows>;
    using row_vec = sv<dtype, cols>;

    __device__ inline void operator=(const dtype &value) { // runs at warp scope by default
        #pragma unroll
        for(int i = kittens::laneid(); i < num_elements; i += WARP_THREADS) {
            data[i] = value;
        }
    }
};

/* ----------  CONCEPTS  ---------- */

namespace ducks {
namespace st {

/**
* @brief Concept for all shared tiles.
* @tparam T The type to check against the concept requirements.
*
* Requires:
* - T has a nested type identifier that is the same as st::identifier.
*/
template<typename T> concept all = requires {
    typename T::identifier; // Checks if T::identifier exists
} && std::is_same_v<typename T::identifier, identifier>; // Checks if T::identifier is ducks::st::identifier

} // namespace st
} // namespace ducks


/* ----------  WRAPPERS FOR PRETTINESS  ---------- */

template<int _height, int _width> using st_bf = st<bf16,  _height, _width>;
template<int _height, int _width> using st_hf = st<half,  _height, _width>;
template<int _height, int _width> using st_fl = st<float, _height, _width>;
#ifdef KITTENS_HOPPER
template<int _height, int _width> using st_fl8_e4m3 = st<fp8e4m3, _height, _width>;
template<int _height, int _width> using st_fl8_e5m2 = st<fp8e5m2, _height, _width>;
#endif

/* ----------  PRINTOUTS  ---------- */

/**
 * @brief Print the contents of a shared tile as a formatted table.
 *
 * This function should be called by a single thread in the warp.
 * It will print the entire tile atomically to avoid interleaved output.
 *
 * @param tile The shared tile to print
 */
template<ducks::st::all ST>
__device__ inline void print(const ST& tile) {
    if (laneid() == 0) { // Only first thread in warp prints
        printf("Shared Tile(%d, %d)[\n", ST::rows, ST::cols);

        // Maximum number of rows/columns to display before truncating
        constexpr int max_display_rows = 6;
        constexpr int max_display_cols = 10;

        // Calculate how many rows/cols to show at beginning and end
        const int show_rows_begin = (ST::rows <= max_display_rows) ? ST::rows : max_display_rows / 2;
        const int show_rows_end = (ST::rows <= max_display_rows) ? 0 : max_display_rows / 2;
        const int show_cols_begin = (ST::cols <= max_display_cols) ? ST::cols : max_display_cols / 2;
        const int show_cols_end = (ST::cols <= max_display_cols) ? 0 : max_display_cols / 2;

        // Print rows
        for (int r = 0; r < ST::rows; r++) {
            // Skip middle rows if needed
            if (r >= show_rows_begin && r < ST::rows - show_rows_end) {
                if (r == show_rows_begin) {
                    printf("  ...\n");
                }
                continue;
            }

            printf("  [");

            // Print columns for this row
            for (int c = 0; c < ST::cols; c++) {
                // Skip middle columns if needed
                if (c >= show_cols_begin && c < ST::cols - show_cols_end) {
                    if (c == show_cols_begin) {
                        printf(" ... ");
                    }
                    continue;
                }

                // Print value based on type
                if constexpr (std::is_same_v<typename ST::dtype, float>) {
                    printf("%.4f", tile[{r,c}]);
                } else if constexpr (std::is_same_v<typename ST::dtype, __nv_bfloat16>) {
                    printf("%.4f", __bfloat162float(tile[{r,c}]));
                } else if constexpr (std::is_integral_v<typename ST::dtype>) {
                    printf("%d", (int)tile[{r,c}]);
                } else {
                    printf("%.4f", (float)tile[{r,c}]);
                }

                // Add comma except for last element
                if (c < ST::cols - 1 && (c < show_cols_begin - 1 || c >= ST::cols - show_cols_end)) {
                    printf(", ");
                }
            }

            // End of row
            if (r < ST::rows - 1) {
                printf("],\n");
            } else {
                printf("]\n");
            }
        }

        printf("]\n");
    }
}

}
