#+build windows
package livepatch

import "core:strings"

// --- COFF symbol/section/relocation record sizes (bytes) ---
COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

IMAGE_SYM_CLASS_STATIC :: 3

// --- PE/COFF machine, section-characteristic and AMD64 relocation constants ---
IMAGE_FILE_MACHINE_AMD64 :: 0x8664
IMAGE_SCN_MEM_EXECUTE       :: 0x20000000
IMAGE_SCN_MEM_WRITE         :: 0x80000000
IMAGE_SCN_LNK_NRELOC_OVFL   :: 0x01000000
IMAGE_SCN_MEM_DISCARDABLE   :: 0x02000000
IMAGE_SCN_LNK_REMOVE        :: 0x00000800

IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03
IMAGE_REL_AMD64_REL32    :: 0x04
IMAGE_REL_AMD64_SECREL :: 0x0B

Coff_File_Header :: struct #packed {
	machine:                 u16le,
	number_of_sections:      u16le,
	time_date_stamp:         u32le,
	pointer_to_symbol_table: u32le,
	number_of_symbols:       u32le,
	size_of_optional_header: u16le,
	characteristics:         u16le,
}

Coff_Section_Header :: struct #packed {
	name:                    [8]u8,
	virtual_size:            u32le,
	virtual_address:         u32le,
	size_of_raw_data:        u32le,
	pointer_to_raw_data:     u32le,
	pointer_to_relocations:  u32le,
	pointer_to_line_numbers: u32le,
	number_of_relocations:   u16le,
	number_of_line_numbers:  u16le,
	characteristics:         u32le,
}

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32le,
	section_number:        i16le,
	type:                  u16le,
	storage_class:         u8,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32le,
	symbol_table_index: u32le,
	type:               u16le,
}

// Returns the i-th COFF section header in an object's section table.
@(private)
section_header :: proc(data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
	return (^Coff_Section_Header)(raw_data(data[sec_off + i*SECTION_HDR_SIZE:]))
}

// Returns the i-th COFF symbol table entry.
coff_symbol :: proc(data: []byte, sym_off, i: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[sym_off + i*COFF_SYMBOL_SIZE:]))
}

// Iterates the COFF symbol table, skipping past each symbol's aux records.
coff_symbols :: proc(data: []byte, sym_off, n_syms: int, cursor: ^int) -> (sym: ^Coff_Symbol, idx: int, ok: bool) {
	if cursor^ >= n_syms {
		return
	}
	idx = cursor^
	sym = coff_symbol(data, sym_off, idx)
	cursor^ += 1 + int(sym.number_of_aux_symbols)
	return sym, idx, true
}

// Returns a COFF section's name as a string.
section_name :: proc(sh: ^Coff_Section_Header) -> string {
	return strings.truncate_to_byte(string(sh.name[:]), 0)
}

// Reports whether a defined symbol must resolve within its own object rather
// than through the reload-wide symbol map.
//
// A COFF section symbol shares its section's name, and one object routinely
// holds several sections with the same name — a package object here carries ten
// `.rdata` COMDATs — so merging them by name binds one object's relocations to
// another object's (or another COMDAT's) bytes. Assembler temporaries (`.L…`)
// are object-local for the same reason.
//
// Odin's own file-local symbols (`pkg::name`, `__$equal$…`) are STATIC too, but
// each names the same logical entity in every object, so they keep merging —
// that is what points every object at one live copy of a procedure.
lp_is_object_local :: proc(sym: ^Coff_Symbol, name: string, sh: ^Coff_Section_Header) -> bool {
	if sym.storage_class != IMAGE_SYM_CLASS_STATIC {
		return false
	}
	return name == section_name(sh) || strings.has_prefix(name, ".L")
}

// Reports whether a section is dropped at link time — debug info (`.debug$S`,
// `.debug$T`) and linker directives (`.drectve`). Mapping them burns the scarce
// address space near the exe, and their relocations are types the runtime has no
// reason to apply, which is what buried the reloc diagnostics in false positives.
lp_is_discarded_section :: proc(sh: ^Coff_Section_Header) -> bool {
	return (u32(sh.characteristics) & (IMAGE_SCN_MEM_DISCARDABLE | IMAGE_SCN_LNK_REMOVE)) != 0
}

// Returns a COFF symbol's name, following the string-table indirection for long names.
symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {

	// if the first 4 bytes are 0 the name lives in the string table
	if name_zeroes := (^u32le)(&sym.name[0])^; name_zeroes == 0 {
		off := int((^u32le)(&sym.name[4])^) // offset
		p := strtab_off + off

		n := 0
		for p + n < len(data) && data[p + n] != 0 {
			n += 1
		}
		return string(data[p : p + n])
	}
	return strings.truncate_to_byte(string(sym.name[:]), 0)
}

// Finds a defined symbol by name in an object, returning its mapped address.
find_symbol_address :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr, name: string) -> (addr: rawptr, ok: bool) {
	cursor := 0
	for sym in coff_symbols(data, sym_off, n_syms, &cursor) {
		sn := int(sym.section_number)
		if sn > 0 && section_bases[sn] != nil && symbol_name(sym, data, strtab_off) == name {
			return rawptr(uintptr(section_bases[sn]) + uintptr(sym.value)), true
		}
	}
	return nil, false
}
