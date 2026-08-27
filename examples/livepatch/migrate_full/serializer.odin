#+build windows
package livepatch_migrate_full

// Reflection-based, name-keyed serializer. Vendored from:
//   https://github.com/Binasaurus-Hex/LivePatch  (game/serializer.odin)
// It walks Odin runtime type-info and stores each field by NAME, so `State` (see
// migrate.odin) survives a layout change across a livepatch: add/remove/reorder/
// rename (via `fs` struct tag) fields keep their values; new fields zero-init.
//
// ADAPTED FOR EXE-BASED HOT RELOAD: in a DLL reload each module carries its own type
// table, so `type_info_of(T)` in reloaded code already describes the NEW layout. In
// THIS exe-based reload, hot-code `type_info_of` still resolves to the exe's OLD table
// (see core/livepatch). So `deserialize` takes the destination's NEW `^Type_Info`
// explicitly (from `livepatch.Type_Change.new`) and walks the destination struct via
// that type-info's own field arrays instead of re-`type_info_of`-ing by typeid — which
// would drop back to the old layout. `serialize` needs no change: it runs in pre-patch
// (old) code, where reflection and memory agree.
//
// LIMITATION: only value types are handled (named, struct, array, enum,
// enumerated-array, bit_set, union). Maps, dynamic arrays and pointers fall back
// to a raw mem.copy and are meaningless across a reload -- keep them out of State.
//
// NOTE(license): upstream repo has no license file. Vendored pending explicit
// permission from the author; replace or relicense if that can't be obtained.

import "core:reflect"
import "core:mem"
import "core:strings"
import "core:slice"
import rt "base:runtime"
import sa "core:container/small_array"

MAX_UNION_VARIANTS :: 100
MAX_STRUCT_FIELDS :: 100
MAX_ENUM_FIELDS :: 100

serialize :: proc(t: ^$T, allocator := context.temp_allocator) -> []byte {

    SerializationCtx :: struct {
        types: [dynamic]TypeInfo,
        strings: [dynamic]byte
    }
    ctx := SerializationCtx {}
    ctx.types.allocator = context.temp_allocator
    ctx.strings.allocator = context.temp_allocator

    save_type :: proc(ctx: ^SerializationCtx, type: typeid) -> TypeInfo_Handle {

        for info, i in ctx.types {
            if info.id != type do continue
            return TypeInfo_Handle(i + 1)
        }

        info := type_info_of(type)
        save_info := TypeInfo {
            size = info.size,
            id = type
        }
        #partial switch v in info.variant {
        case rt.Type_Info_Named:
            save_info.variant = TypeInfo_Named {
                name = to_index_string(&ctx.strings, v.name),
                type = save_type(ctx, v.base.id)
            }

        case rt.Type_Info_Struct:
            save_struct := TypeInfo_Struct {}
            for field in reflect.struct_fields_zipped(type){
                sa.append(&save_struct.fields, Struct_Field {
                    name = to_index_string(&ctx.strings, field.name),
                    offset = field.offset,
                    type = save_type(ctx, field.type.id)
                })
            }
            save_info.variant = save_struct

        case rt.Type_Info_Array:
            save_info.variant = TypeInfo_Array {
                elem = save_type(ctx, v.elem.id),
                elem_size = v.elem_size,
                count = v.count
            }

        case rt.Type_Info_Enum:
            save_enum := TypeInfo_Enum {}
            if int_info, ok := rt.type_info_base(v.base).variant.(rt.Type_Info_Integer); ok {
                save_enum.signed = int_info.signed
            }
            for field in reflect.enum_fields_zipped(type){
                sa.append(&save_enum.fields, Enum_Field {
                    name = to_index_string(&ctx.strings, field.name),
                    value = i64(field.value)
                })
            }
            save_info.variant = save_enum

        case rt.Type_Info_Enumerated_Array:
            save_info.variant = TypeInfo_Enumerated_Array {
                elem = save_type(ctx, v.elem.id),
                index = save_type(ctx, v.index.id),
                elem_size = v.elem_size,
                count = v.count,
            }
        case rt.Type_Info_Bit_Set:
            save_info.variant = TypeInfo_Bit_Set {
                elem = save_type(ctx, v.elem.id),
            }
        case rt.Type_Info_Union:
            save_union := TypeInfo_Union {
                tag_offset = v.tag_offset,
                tag_type = save_type(ctx, v.tag_type.id)
            }
            for variant in v.variants {
                sa.append(&save_union.variants, save_type(ctx, variant.id))
            }
            save_info.variant = save_union
        }
        append(&ctx.types, save_info)
        return TypeInfo_Handle(len(ctx.types))
    }

    save_type(&ctx, T)

    header := SaveHeader {}

    for info, i in ctx.types {
        if info.id != T do continue
        header.stored_type = TypeInfo_Handle(i + 1)
    }
    header.types = ctx.types[:]
    header.strings = ctx.strings[:]

    bytes := make([dynamic]byte, allocator)
    append(&bytes, ..mem.ptr_to_bytes(&header))
    append(&bytes, ..mem.slice_to_bytes(header.types))
    append(&bytes, ..mem.slice_to_bytes(header.strings))
    append(&bytes, ..mem.ptr_to_bytes(t))
    return bytes[:]
}

get_typeinfo_base :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (base: ^TypeInfo, ok: bool){
    handle := handle
    for {
        base = get_typeinfo_ptr(header, handle) or_return
        named := base.variant.(TypeInfo_Named) or_break
        handle = named.type
    }
    return base, true
}

get_typeinfo_ptr :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (ptr: ^TypeInfo, ok: bool) {
    index := int(handle) - 1
    return &header.types[index], true
}

// Deserialize `data` (produced by `serialize` in the pre-patch/old code) into `dst`,
// whose NEW layout is described by `dst_ti` (from livepatch.Type_Change.new). Fields
// are matched by name; surviving fields keep their value at the NEW offset, removed
// fields are dropped, new fields stay zero (so `dst` should be zeroed first).
deserialize :: proc(dst: rawptr, dst_ti: ^rt.Type_Info, data: []byte) {

    split_ref :: proc(s: ^[]$T, index: int) -> []T {
        a, b := slice.split_at(s^, index)
        s^ = b
        return a
    }

    data := data

    header := transmute(^SaveHeader)(&split_ref(&data, size_of(SaveHeader))[0])
    header.types = slice.reinterpret([]TypeInfo, split_ref(&data, len(header.types) * size_of(TypeInfo)))
    header.strings = split_ref(&data, len(header.strings))

    body := data[:]

    start, ok := get_typeinfo_ptr(header, header.stored_type)
    assert(ok)

    deserialize_raw(header, uintptr(&body[0]), uintptr(dst), header.stored_type, dst_ti)
}

find_matching_field :: proc(header: ^SaveHeader, struct_info: ^TypeInfo_Struct, name: string) -> (^Struct_Field, bool) {
    for &field in sa.slice(&struct_info.fields){
        if resolve_to_string(header.strings, field.name) != name do continue
        return &field, true
    }
    return nil, false
}

// Read/write an integer of `size` bytes (an enum backing or a union tag) as i64. Enums
// carry a signedness; union tags are always unsigned (pass signed=false). Sizes other
// than 1/2/4/8 return 0 / no-op so callers can fall back to a raw copy.
read_int :: proc(ptr: uintptr, size: int, signed: bool) -> i64 {
    switch size {
    case 1: return signed ? i64((^i8 )(ptr)^) : i64((^u8 )(ptr)^)
    case 2: return signed ? i64((^i16)(ptr)^) : i64((^u16)(ptr)^)
    case 4: return signed ? i64((^i32)(ptr)^) : i64((^u32)(ptr)^)
    case 8: return (^i64)(ptr)^
    }
    return 0
}
read_uint :: proc(ptr: uintptr, size: int) -> i64 {
    return read_int(ptr, size, false)
}
write_int :: proc(ptr: uintptr, size: int, value: i64) {
    switch size {
    case 1: (^u8 )(ptr)^ = u8 (value)
    case 2: (^u16)(ptr)^ = u16(value)
    case 4: (^u32)(ptr)^ = u32(value)
    case 8: (^i64)(ptr)^ = value
    }
}
int_size_ok :: proc(size: int) -> bool {
    return size == 1 || size == 2 || size == 4 || size == 8
}

// Destination enum constants read from the type-info POINTER's own arrays, not via
// reflect.enum_fields_zipped(id): in hot code the id-based lookup drops back to the
// exe's OLD enum layout, so an enum whose constants changed would migrate wrong. Same
// crux adaptation as the struct path.
enum_arrays :: proc(dst: ^rt.Type_Info) -> (names: []string, values: []rt.Type_Info_Enum_Value) {
    e, ok := rt.type_info_base(dst).variant.(rt.Type_Info_Enum)
    if !ok do return
    return e.names, e.values
}

enum_identical :: proc(header: ^SaveHeader, a: ^TypeInfo, b: ^rt.Type_Info) -> bool {
    a := (&a.variant.(TypeInfo_Enum)) or_return
    a_fields := sa.slice(&a.fields)
    b_names, b_values := enum_arrays(b)

    if len(a_fields) != len(b_names) do return false
    for a_field, i in a_fields {
        if a_field.value != i64(b_values[i]) do return false
        a_name := resolve_to_string(header.strings, a_field.name)
        if a_name != b_names[i] do return false
    }
    return true
}

get_name :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (s: string, ok: bool) {
    info := get_typeinfo_ptr(header, handle) or_return
    named := (&info.variant.(TypeInfo_Named)) or_return
    s = resolve_to_string(header.strings, named.name)
    return s, true
}

get_name_info_ptr :: proc(t: ^rt.Type_Info) -> (s: string, ok: bool) {
    named := (&t.variant.(rt.Type_Info_Named)) or_return
    return named.name, true
}

deserialize_raw :: proc(header: ^SaveHeader, src, dst: uintptr, src_type: TypeInfo_Handle, dst_type: ^rt.Type_Info) -> (identical: bool){
    saved_type, found_saved := get_typeinfo_base(header, src_type)
    assert(found_saved)

    dst_type := rt.type_info_base(dst_type)

    defer {
        if saved_type.identical {
            saved_type.identical_id = dst_type.id
        }
    }

    if !saved_type.identical {

        saved_type.identical = true

        #partial switch v in dst_type.variant {
        case rt.Type_Info_Struct:
            saved_struct := (&saved_type.variant.(TypeInfo_Struct)) or_break

            // Walk the destination's fields via `dst_type`'s own arrays (the NEW layout),
            // NOT reflect.struct_fields_zipped(dst_type.id): in hot code the latter would
            // resolve back through the exe's OLD type table. This is the crux adaptation.
            field_count := int(v.field_count)
            identical_fields: int

            for i in 0 ..< field_count {
                field_name   := v.names[i]
                field_type   := v.types[i]      // ^Type_Info in the NEW graph
                field_offset := v.offsets[i]
                field_tag    := reflect.Struct_Tag(v.tags[i])

                tag_values: []string = {}

                if tag, ok := reflect.struct_tag_lookup(field_tag, "fs"); ok {
                    tag_values = strings.split(tag, ",", context.temp_allocator)

                    // ignore this field
                    if slice.contains(tag_values, "-") {
                        continue
                    }
                }

                saved_field, field_found := find_matching_field(header, saved_struct, field_name)

                // check aliases
                if !field_found {
                    for alias in tag_values {
                        saved_field = find_matching_field(header, saved_struct, alias) or_continue
                        field_found = true
                    }

                    if !field_found {
                        continue
                    }
                }

                if saved_field.offset != field_offset do saved_type.identical = false
                field_src := src + saved_field.offset
                field_dst := dst + field_offset
                if deserialize_raw(header, field_src, field_dst, saved_field.type, field_type){
                    identical_fields += 1
                }
            }
            if identical_fields != field_count do saved_type.identical = false

            return saved_type.identical

        case rt.Type_Info_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Array)) or_break
            count := min(saved_array.count, v.count)
            for i in 0..<count {
                elem_src := src + uintptr(i * saved_array.elem_size)
                elem_dst := dst + uintptr(i * v.elem_size)

                if !deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem) {
                    saved_type.identical = false
                }
            }
            return saved_type.identical

        case rt.Type_Info_Enum:
            saved_enum := (&saved_type.variant.(TypeInfo_Enum)) or_break
            if !int_size_ok(saved_type.size) || !int_size_ok(dst_type.size) do break // unusual backing: raw copy

            src_value := read_int(src, saved_type.size, saved_enum.signed)

            saved_fields := sa.slice(&saved_enum.fields)
            dst_names, dst_values := enum_arrays(dst_type)

            // identical check
            if enum_identical(header, saved_type, dst_type) do break

            // otherwise assumed to be a known, non identical enum, do the correct copy operation
            saved_type.identical = false

            saved_field: ^Enum_Field
            for &field in saved_fields {
                if field.value != src_value do continue
                saved_field = &field
                break
            }

            saved_name: string = resolve_to_string(header.strings, saved_field.name)
            for i in 0 ..< len(dst_names) {
                if dst_names[i] != saved_name do continue
                write_int(dst, dst_type.size, i64(dst_values[i]))
            }
            return saved_type.identical

        case rt.Type_Info_Enumerated_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Enumerated_Array)) or_break

            saved_index := get_typeinfo_base(header, saved_array.index) or_break

            if enum_identical(header, saved_index, v.index) {
                saved_index.identical = true
            }

            saved_elem := get_typeinfo_base(header, saved_array.elem) or_break
            if saved_index.identical && saved_elem.identical do break

            saved_type.identical = false

            saved_enum := (&saved_index.variant.(TypeInfo_Enum)) or_break
            count := min(sa.len(saved_enum.fields), v.count)

            idx_names, idx_values := enum_arrays(v.index)
            for &saved_field in sa.slice(&saved_enum.fields){
                saved_name := resolve_to_string(header.strings, saved_field.name)
                for i in 0 ..< len(idx_names){
                    if saved_name != idx_names[i] do continue
                    elem_src := src + uintptr(int(saved_field.value) * saved_elem.size)
                    elem_dst := dst + uintptr(int(idx_values[i]) * v.elem_size)
                    if !deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem){
                        saved_type.identical = false
                    }
                }
            }
            return saved_type.identical

        case rt.Type_Info_Bit_Set:
            saved_bitset := (&saved_type.variant.(TypeInfo_Bit_Set)) or_break
            saved_enum_base := get_typeinfo_base(header, saved_bitset.elem) or_break

            if enum_identical(header, saved_enum_base, v.elem) {
                saved_enum_base.identical = true
            }

            if saved_enum_base.identical && saved_type.size == dst_type.size do break

            saved_enum := (&saved_enum_base.variant.(TypeInfo_Enum)) or_break

            src_bytes := mem.byte_slice(rawptr(src), saved_type.size)
            dst_bytes := mem.byte_slice(rawptr(dst), dst_type.size)

            for &saved_field in sa.slice(&saved_enum.fields){
                byte_index: u64 = u64(saved_field.value / 8)
                bit_index: u64 = u64(saved_field.value % 8)

                src_byte := src_bytes[byte_index]
                is_set: bool = ((byte(1) << bit_index) & src_byte) > 0

                saved_name := resolve_to_string(header.strings, saved_field.name)

                elem_names, elem_values := enum_arrays(v.elem)
                for j in 0 ..< len(elem_names){
                    if elem_names[j] != saved_name do continue

                    byte_index_actual := u64(elem_values[j] / 8)
                    bit_index_actual := u64(elem_values[j] % 8)

                    if is_set {
                        dst_bytes[byte_index_actual] |= 1 << bit_index_actual
                    }
                    else {
                        dst_bytes[byte_index_actual] &= ~(1 << bit_index_actual)
                    }
                }
            }
            saved_type.identical = false

            return saved_type.identical

        case rt.Type_Info_Union:
            saved_union := (&saved_type.variant.(TypeInfo_Union)) or_break

            saved_variants := sa.slice(&saved_union.variants)
            actual_variants := v.variants

            check: {
                if len(saved_variants) != len(actual_variants) do break check

                for variant_handle, i in saved_variants {
                    saved_variant, found := get_typeinfo_base(header, variant_handle)
                    assert(found)
                    if !saved_variant.identical do break check
                    if saved_variant.identical_id != actual_variants[i].id do break check
                }
                break
            }
            saved_type.identical = false

            tag_type, found_tag_type := get_typeinfo_base(header, saved_union.tag_type)
            assert(found_tag_type)

            // Union tags are unsigned ints sized to the variant count (u8/u16/u32/...),
            // NOT always u32 — read/write at the real tag size. Unusual size: raw copy.
            if !int_size_ok(tag_type.size) || !int_size_ok(v.tag_type.size) do break

            src_tag := read_uint(src + saved_union.tag_offset, tag_type.size)
            if src_tag == 0 do break // nil union: nothing to migrate

            src_variant := saved_variants[int(src_tag) - 1]
            src_name, has_src_name := get_name(header, src_variant)
            assert(has_src_name)

            dst_tag: i64 = 0
            for variant, i in actual_variants {
                name, ok := get_name_info_ptr(variant)
                assert(ok)
                if name != src_name do continue
                dst_tag = i64(i + 1)
                break
            }
            if dst_tag == 0 do break // the active variant no longer exists: leave dst nil

            write_int(dst + v.tag_offset, v.tag_type.size, dst_tag)
            dst_variant := actual_variants[int(dst_tag) - 1]

            deserialize_raw(header, src, dst, src_variant, dst_variant)

            return saved_type.identical
        }
    }

    if saved_type.size != dst_type.size do saved_type.identical = false

    // fallback option

    size := min(saved_type.size, dst_type.size)
    mem.copy(rawptr(dst), rawptr(src), size)
    return saved_type.identical
}

// TYPE INFO

TypeInfo_Handle :: distinct int

Struct_Field :: struct {
    name: IndexString,
    offset: uintptr,
    type: TypeInfo_Handle
}

TypeInfo_Struct :: struct {
    fields: sa.Small_Array(MAX_STRUCT_FIELDS, Struct_Field)
}

Enum_Field :: struct {
    name: IndexString,
    value: i64
}

TypeInfo_Enum :: struct {
    fields: sa.Small_Array(MAX_ENUM_FIELDS, Enum_Field),
    signed: bool, // signedness of the backing integer (size is TypeInfo.size)
}

TypeInfo_Array :: struct {
    elem: TypeInfo_Handle,
    elem_size: int,
    count: int
}

TypeInfo_Enumerated_Array :: struct {
    elem: TypeInfo_Handle,
    index: TypeInfo_Handle,
    elem_size: int,
    count: int,
}

TypeInfo_Bit_Set :: struct {
    elem: TypeInfo_Handle,
    underlying: TypeInfo_Handle,
    lower: i64,
    upper: i64,
}

TypeInfo_Union :: struct {
    variants: sa.Small_Array(MAX_UNION_VARIANTS, TypeInfo_Handle),
    tag_offset: uintptr,
    tag_type: TypeInfo_Handle,
}

TypeInfo_Named :: struct {
    name: IndexString,
    type: TypeInfo_Handle
}

TypeInfo :: struct {
    size: int,
    id: typeid,
    variant: union {
        TypeInfo_Named,
        TypeInfo_Struct,
        TypeInfo_Enum,
        TypeInfo_Array,
        TypeInfo_Enumerated_Array,
        TypeInfo_Bit_Set,
        TypeInfo_Union
    },

    // deserialization info
    identical: bool,
    identical_id: typeid,
}

SaveHeader :: struct {
    types: []TypeInfo,
    strings: []byte,
    stored_type: TypeInfo_Handle,
}

// string stuff

to_index_string :: proc(buffer: ^[dynamic]byte, s: string) -> IndexString {

    index := len(buffer)
    length := len(s)
    append(buffer, ..transmute([]byte)s)
    return IndexString {
        index, length
    }
}

resolve_to_string :: proc(buffer: []byte, is: IndexString) -> string {
    return string(buffer[is.index: is.index + is.length])
}

IndexString :: struct {
    index, length: int
}
