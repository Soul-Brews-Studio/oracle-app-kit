//! Apple's `umap` crate (umap-learn port) behind a C ABI. One call: data in, embedding + kNN graph out.
//! Lives in the tokenizer crate so the apps link ONE Rust static library (two would duplicate std symbols).
use ndarray::Array2;
use std::ffi::c_char;
use umap::{Init, Umap};

#[no_mangle]
pub extern "C" fn umap_fit(data: *const f32, n: usize, dim: usize,
                           n_components: usize, n_neighbors: usize, min_dist: f32, n_epochs: usize, seed: u64,
                           out_embedding: *mut f32, out_knn_indices: *mut i32, out_knn_distances: *mut f32) -> i32 {
    if data.is_null() || out_embedding.is_null() || n == 0 || dim == 0 || n_components == 0 || n_neighbors < 2 || n_neighbors >= n { return -1; }
    let slice = unsafe { std::slice::from_raw_parts(data, n * dim) };
    let Ok(arr) = Array2::from_shape_vec((n, dim), slice.to_vec()) else { return -1 };
    let mut b = Umap::builder(&arr)
        .n_components(n_components)
        .n_neighbors(n_neighbors)
        .min_dist(min_dist)
        .metric("cosine")
        .random_state(seed)
        .init_method(Init::Spectral);
    if n_epochs > 0 { b = b.n_epochs(n_epochs); }
    let r = match b.build() { Ok(r) => r, Err(_) => return -2 };
    if r.embedding.shape() != [n, n_components] { return -2; }
    let out = unsafe { std::slice::from_raw_parts_mut(out_embedding, n * n_components) };
    for (o, v) in out.iter_mut().zip(r.embedding.iter()) { *o = *v; }
    let k = r.knn_indices.shape()[1].min(n_neighbors);
    if !out_knn_indices.is_null() && !out_knn_distances.is_null() {
        let oi = unsafe { std::slice::from_raw_parts_mut(out_knn_indices, n * n_neighbors) };
        let od = unsafe { std::slice::from_raw_parts_mut(out_knn_distances, n * n_neighbors) };
        for i in 0..n { for j in 0..n_neighbors {
            oi[i * n_neighbors + j] = if j < k { r.knn_indices[[i, j]] } else { -1 };
            od[i * n_neighbors + j] = if j < k { r.knn_distances[[i, j]] } else { f32::INFINITY };
        } }
    }
    0
}

#[no_mangle]
pub extern "C" fn umap_ffi_version() -> *const c_char {
    concat!("apple/embedding-atlas umap 0.1.0 · umap_ffi ", env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}
