#pragma once

#include <cstddef>

namespace cuda_playground {

// Computes c = a + b on the GPU. Sizes are in elements.
// Throws std::runtime_error on any CUDA failure.
void vector_add(const float* a, const float* b, float* c, std::size_t n);

}  // namespace cuda_playground
