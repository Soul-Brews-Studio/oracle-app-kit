#ifndef TOKENIZER_FFI_H
#define TOKENIZER_FFI_H
#include <stddef.h>
#include <stdint.h>

/// Opaque handle to a Hugging Face tokenizer loaded from tokenizer.json.
typedef struct TokFFI TokFFI;

/// Load tokenizer.json; truncation to max_tokens (with special tokens), no padding.
/// NULL on failure.
TokFFI *tok_new(const char *tokenizer_json_path, size_t max_tokens);
void tok_free(TokFFI *tok);

/// Encode n UTF-8 texts in parallel. On success returns 0 and sets *ids to a flat buffer of
/// all ids (text after text) and lens[i] to text i's id count; free *ids with
/// tok_free_ids(*ids, total). Returns -1 on failure.
int tok_encode_batch(const TokFFI *tok, const char *const *texts, size_t n,
                     uint32_t **ids, size_t *lens);
void tok_free_ids(uint32_t *ids, size_t total);

#endif
