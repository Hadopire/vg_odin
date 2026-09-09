#pragma once

// helpers for push constant declarations
// constant buffer alignment rule for struct is 16 bytes
// these macros are basically doing struct inlining to bypass that

#define PUSH_PTR(T, name)   uint name##_heap_idx; uint name##_offset; property Ptr<T> name { get { return Ptr<T>(name##_heap_idx, name##_offset); } }
#define PUSH_ARRAY(T, name) uint name##_heap_idx; uint name##_offset; uint name##_count; property Array<T> name { get { return Array<T>(Ptr<T>(name##_heap_idx, name##_offset), name##_count); } }
#define PUSH_TEXTURE(name)  uint name##_texture; uint name##_sampler; property Texture2 name { get { return Texture2(name##_texture, name##_sampler); } }
