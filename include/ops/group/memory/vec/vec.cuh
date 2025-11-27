/**
 * @file
 * @brief An aggregate header of group memory operations on vectors.
 */

#include "shared_to_register.cuh"
#include "global_to_register.cuh"
#include "global_to_shared.cuh"

#if KITTENS_ARCH == 900
#include "pgl_to_register.cuh"
#endif
