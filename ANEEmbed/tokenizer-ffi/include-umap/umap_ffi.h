#ifndef UMAP_FFI_H
#define UMAP_FFI_H
#include <stddef.h>
#include <stdint.h>

/// UMAP over n rows of dim floats (row-major), cosine metric, spectral init, seeded.
/// Writes n*n_components floats to out_embedding and n*n_neighbors ints/floats to out_knn_indices / out_knn_distances
/// (the kNN graph UMAP built, reused for edges and for placing new points). All out buffers are caller-owned.
/// Returns 0 on success, -1 on bad arguments, -2 when UMAP failed. n_epochs 0 = the library's default.
int umap_fit(const float *data, size_t n, size_t dim,
             size_t n_components, size_t n_neighbors, float min_dist, size_t n_epochs, uint64_t seed,
             float *out_embedding, int32_t *out_knn_indices, float *out_knn_distances);

/// The version of the vendored crate, for the layout's sidecar file.
const char *umap_ffi_version(void);

#endif
