/**
 * @file
 * @brief An aggregate header for all group-scope MMA operations.
 */

// All compilation targets can use the warp-scope MMA operations.
#include "warp/warp.cuh"

// Hopper has its own warpgroup-scope MMA operations.
#if KITTENS_ARCH == 900
#include "warpgroup/warpgroup.cuh"
#endif

// Blackwell has its own tensor-scope MMA operations.
#if KITTENS_ARCH >= 1000
#include "tensor/tensor.cuh"
#endif