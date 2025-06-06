/**
 * @file
 * @brief The ThunderKittens shared vector struct.
 */

#pragma once

#include <concepts>
#include <type_traits>

#include "../../common/common.cuh"

namespace kittens {

/* ----------  MAIN VECTOR STRUCT  ---------- */

namespace ducks {
/**
 * @namespace sv
 *
 * @brief The namespace where concepts and abstract types for shared vectors live.
 */
namespace sv {
/**
 * @brief A dummy type used to identify shared vectors.
 *
 * For a type to quack like an sv, it should define its identifier as ducks::sv::identifier.
 * If a type quacks like ducks::sv::identifier, it will be treated as an sv by compiler checks.
 */
struct identifier {};
}
}

/**
 * @brief Shared vector structure.
 *
 * @tparam _T The packed data type used for the vector elements.
 * @tparam _tiles The size of the tile, in units of TILE_ROW_DIM (16 for fp16, bf16, fp32).
 *
 * Shared vectors are used to accumulate and map values across shared tiles.
 * Unlike every other structure present in ThunderKittens, these have a simple
 * uniform layout which is just an array in memory. EZ!
 */
template<typename _T, size_t _length>
struct KITTENS_DEFAULT_ALIGN sv {
    using identifier = ducks::sv::identifier;
    using T = base_types::packing<_T>::unpacked_type;
    using T2 = base_types::packing<_T>::packed_type;
    using dtype = T; ///< Data type of the elements in the tile.

    static constexpr int length = _length; ///< Length in elements.
    static_assert(length % TILE_ROW_DIM<T> == 0, "Length must be divisible by the tile dimension");
    static constexpr int tiles  = length / TILE_ROW_DIM<T>; ///< Length in subtiles.'
    #ifdef KITTENS_HOPPER
    static_assert(!std::is_same_v<T2, fp8e4m3_4> && !std::is_same_v<T2, fp8e5m2_4>, "Unsupported type for fp8");
    #endif

#ifdef KITTENS_HOPPER
    static constexpr int num_alloc_elements = ((length * sizeof(dtype) + 127) / 128) * (128 / sizeof(dtype)); // round up to the nearest 128-byte boundary
#else
    static constexpr int num_alloc_elements = length;
#endif
    dtype data[num_alloc_elements]; ///< The actual shared vector data.

    __device__ static inline T* idx(T *ptr, int idx) { // useful for computations in shared address space, as silly as it sounds.
        return ptr[idx];
    }

    __device__ inline       dtype& operator[](size_t idx)       { return data[idx]; }
    __device__ inline const dtype& operator[](size_t idx) const { return data[idx]; }

    template<size_t sub_length> using subvec = sv<dtype, sub_length>; ///< A subvector which allows warpgroups and blocks to work cooperatively.

    __device__ inline void operator=(const dtype &value) { // runs at warp scope by default
        #pragma unroll
        for(int i = kittens::laneid(); i < length; i += WARP_THREADS) {
            data[i] = value;
        }
    }
};

/* ----------  CONCEPTS  ---------- */

namespace ducks {
namespace sv {
/**
* @brief Concept for all shared vectors.
* @tparam T The type to check against the concept requirements.
*
* Requires:
* - T has a nested type identifier that is the same as sv::identifier.
*/
template<typename T>
concept all = requires {
    typename T::identifier; // Checks if T::identifier exists
} && std::is_same_v<typename T::identifier, identifier>; // Checks if T::identifier is ducks::sv::identifier

} // namespace sv
} // namespace ducks


/* ----------  WRAPPERS FOR PRETTINESS  ---------- */

// vector types
template<size_t _length> using sv_bf = sv<bf16,  _length>;
template<size_t _length> using sv_hf = sv<half,  _length>;
template<size_t _length> using sv_fl = sv<float, _length>;

/* ----------  PRINTOUTS  ---------- */

template<ducks::sv::all SV>
__device__ inline void print(const SV& sv) {
    if(laneid() == 0) {
        printf("Shared Vector %d: [", SV::length);

        // Maximum number of elements to display before truncating
        constexpr int max_display = 10;

        // Calculate how many elements to show at beginning and end
        const int show_begin = (SV::length <= max_display) ? SV::length : max_display / 2;
        const int show_end = (SV::length <= max_display) ? 0 : max_display / 2;

        for(int i = 0; i < SV::length; i++) {
            // Skip middle elements if needed
            if(i >= show_begin && i < SV::length - show_end) {
                if(i == show_begin) {
                    printf("... ");
                }
                continue;
            }

            // Print value based on type
            if constexpr (std::is_same_v<typename SV::dtype, bf16>) {
                printf("%f", __bfloat162float(sv[i]));
            } else if constexpr (std::is_same_v<typename SV::dtype, half>) {
                printf("%f", __half2float(sv[i]));
            } else if constexpr (std::is_same_v<typename SV::dtype, float>) {
                printf("%f", sv[i]);
            } else {
                printf("%d", (int)(sv[i]));
            }

            // Add comma except for last element
            if(i < SV::length - 1 && (i < show_begin - 1 || i >= SV::length - show_end)) {
                printf(", ");
            }
        }
        printf("]\n");
    }
}

} // namespace kittens