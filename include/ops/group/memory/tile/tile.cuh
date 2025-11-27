/**
 * @file
 * @brief An aggregate header of group memory operations on tiles.
 */

#include "shared_to_register.cuh"
#include "global_to_register.cuh"
#include "global_to_shared.cuh"

#if KITTENS_ARCH == 900
#include "pgl_to_register.cuh"
#endif

#if KITTENS_ARCH >= 1000
#include "tensor_to_register.cuh"
#endif

#include "complex/complex_shared_to_register.cuh"
#include "complex/complex_global_to_register.cuh"
#include "complex/complex_global_to_shared.cuh"

