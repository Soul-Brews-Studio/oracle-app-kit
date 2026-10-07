//! HF `tokenizers` behind a C ABI. The Python service encodes with the same library (its
//! "fast" tokenizer), so ids match by construction; swift-transformers' pure-Swift BPE was
//! 5-14x slower on real text.
pub mod umap;

use std::ffi::{c_char, CStr};
use tokenizers::{Tokenizer, TruncationParams, TruncationStrategy};

pub struct TokFFI(Tokenizer);

#[no_mangle]
pub extern "C" fn tok_new(path: *const c_char, max_tokens: usize) -> *mut TokFFI {
    if path.is_null() { return std::ptr::null_mut(); }
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else { return std::ptr::null_mut() };
    let Ok(mut tok) = Tokenizer::from_file(path) else { return std::ptr::null_mut() };
    tok.with_padding(None);
    let params = TruncationParams { max_length: max_tokens, strategy: TruncationStrategy::LongestFirst, ..Default::default() };
    if tok.with_truncation(Some(params)).is_err() { return std::ptr::null_mut(); }
    Box::into_raw(Box::new(TokFFI(tok)))
}

#[no_mangle]
pub extern "C" fn tok_free(tok: *mut TokFFI) {
    if !tok.is_null() { drop(unsafe { Box::from_raw(tok) }); }
}

#[no_mangle]
pub extern "C" fn tok_encode_batch(tok: *const TokFFI, texts: *const *const c_char, n: usize,
                                   ids: *mut *mut u32, lens: *mut usize) -> i32 {
    if tok.is_null() || ids.is_null() || lens.is_null() || (n > 0 && texts.is_null()) { return -1; }
    let tok = unsafe { &(*tok).0 };
    let mut inputs = Vec::with_capacity(n);
    for i in 0..n {
        let p = unsafe { *texts.add(i) };
        if p.is_null() { return -1; }
        match unsafe { CStr::from_ptr(p) }.to_str() { Ok(s) => inputs.push(s), Err(_) => return -1 }
    }
    let Ok(encodings) = tok.encode_batch(inputs, true) else { return -1 };
    let mut flat: Vec<u32> = Vec::new();
    for (i, e) in encodings.iter().enumerate() {
        flat.extend_from_slice(e.get_ids());
        unsafe { *lens.add(i) = e.get_ids().len(); }
    }
    let mut flat = flat.into_boxed_slice();
    unsafe { *ids = flat.as_mut_ptr(); }
    std::mem::forget(flat);
    0
}

#[no_mangle]
pub extern "C" fn tok_free_ids(ids: *mut u32, total: usize) {
    if !ids.is_null() { drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ids, total)) }); }
}
