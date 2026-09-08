#+build windows
package livepatch

import "core:os"
import md5 "core:crypto/legacy/md5"

// Minimal PDB (Program Database) emitter.
//
// The loader is its own incremental linker; this makes it emit debug info for
// the code it maps, exactly as a real linker's PDB does, so an external debugger
// (RAD Debugger, VS Code / cppvsdbg, WinDbg) resolves patched functions to source
// and binds source-line breakpoints. Validated against dbghelp, DIA/msdia, and the
// LLVM readers (llvm-pdbutil, llvm-symbolizer).
//
// The non-obvious requirements a PDB must satisfy for Microsoft's readers:
//   1. named-stream-map hash capacity >= 1
//   2. DBI BuildNumber bit 15 set (new-version format)
//   3. a SourceInfo (file-info) substream, else zero modules are seen
//   4. each module stream ends with a GlobalRefsSize u32
//   5. Global/Public/SymRecord streams present (even if empty)
//   6. TPI/IPI hash streams present
//   7. the MSF superblock's FreeBlockMapBlock must name the block the FPM lives in
//      (DIA/dbghelp validate the free page map; the LLVM native reader does not)

PDB_BLOCK :: 4096

// One source line entry within a function: byte offset from the function start,
// and the 1-based source line number.
Pdb_Line :: struct {
	offset: u32,
	line:   u32,
}

// A function to describe: name, its RVA (relative to the image/module base = the
// mapped block), byte size, index into the files array, and its line table.
Pdb_Func :: struct {
	name:  string,
	rva:   u32,
	size:  u32,
	file:  int,
	lines: []Pdb_Line,
}

// A section of the mapped image, as it appears in the synthetic PE.
Pdb_Section :: struct {
	name:            string,
	rva:             u32,
	vsize:           u32,
	rawsize:         u32,
	raw_ptr:         u32,
	characteristics: u32,
}

// --- little byte buffer ---
Pbuf :: struct { b: [dynamic]u8 }
@(private="file") pb_raw  :: proc(s: ^Pbuf, d: []u8) { append(&s.b, ..d) }
@(private="file") pb_u8   :: proc(s: ^Pbuf, v: u8)   { append(&s.b, v) }
@(private="file") pb_u16  :: proc(s: ^Pbuf, v: u16)  { x:=v; pb_raw(s,(cast([^]u8)&x)[:2]) }
@(private="file") pb_u32  :: proc(s: ^Pbuf, v: u32)  { x:=v; pb_raw(s,(cast([^]u8)&x)[:4]) }
@(private="file") pb_i32  :: proc(s: ^Pbuf, v: i32)  { x:=v; pb_raw(s,(cast([^]u8)&x)[:4]) }
@(private="file") pb_str  :: proc(s: ^Pbuf, v: string) { pb_raw(s, transmute([]u8)v); pb_u8(s, 0) }
@(private="file") pb_pad4 :: proc(s: ^Pbuf) { for len(s.b) % 4 != 0 { pb_u8(s, 0) } }

// Stream indices (fixed layout).
@(private="file") PS_OLD :: 0
@(private="file") PS_INFO :: 1
@(private="file") PS_TPI :: 2
@(private="file") PS_DBI :: 3
@(private="file") PS_IPI :: 4
@(private="file") PS_NAMES :: 5
@(private="file") PS_SECHDR :: 6
@(private="file") PS_MOD0 :: 7
@(private="file") PS_GSI :: 8
@(private="file") PS_PSI :: 9
@(private="file") PS_SYM :: 10
@(private="file") PS_TPIHASH :: 11
@(private="file") PS_IPIHASH :: 12
@(private="file") PS_COUNT :: 13

@(private="file")
lp_pdb_info :: proc(guid: [16]u8, age: u32) -> []u8 {
	s: Pbuf
	g := guid
	pb_u32(&s, 20000404); pb_u32(&s, 1); pb_u32(&s, age); pb_raw(&s, g[:])
	// NamedStreamMap: "/names" -> PS_NAMES (capacity 1 => bucket 0 for any hash)
	nm := "/names"
	pb_u32(&s, u32(len(nm)+1)); pb_raw(&s, transmute([]u8)nm); pb_u8(&s, 0)
	pb_u32(&s, 1); pb_u32(&s, 1)        // hash Size, Capacity
	pb_u32(&s, 1); pb_u32(&s, 1)        // Present bitvec: 1 word, bit0
	pb_u32(&s, 0)                       // Deleted bitvec: 0 words
	pb_u32(&s, 0); pb_u32(&s, PS_NAMES) // bucket0: (nameOffset, streamIndex)
	pb_u32(&s, 0)                       // niMac
	pb_u32(&s, 20140508)                // feature: VC140
	return s.b[:]
}

@(private="file")
lp_pdb_tpi :: proc(hash_idx: u16) -> []u8 {
	s: Pbuf
	pb_u32(&s, 20040203); pb_u32(&s, 56); pb_u32(&s, 0x1000); pb_u32(&s, 0x1000); pb_u32(&s, 0)
	pb_u16(&s, hash_idx); pb_u16(&s, 0xFFFF); pb_u32(&s, 4); pb_u32(&s, 0x3FFFF)
	pb_i32(&s, 0); pb_u32(&s, 0); pb_i32(&s, 0); pb_u32(&s, 0); pb_i32(&s, 0); pb_u32(&s, 0)
	return s.b[:]
}

// /names global string table; returns (bytes, offset-of-each-file-name).
@(private="file")
lp_pdb_names :: proc(files: []string) -> (data: []u8, offs: []u32) {
	s: Pbuf
	pb_u32(&s, 0xEFFEEFFE); pb_u32(&s, 1)
	sb: Pbuf
	pb_u8(&sb, 0) // offset 0 = ""
	offs = make([]u32, len(files))
	for f, i in files {
		offs[i] = u32(len(sb.b))
		pb_str(&sb, f)
	}
	pb_u32(&s, u32(len(sb.b))); pb_raw(&s, sb.b[:])
	pb_u32(&s, 1); pb_u32(&s, 0); pb_u32(&s, u32(len(files))) // 1 bucket, name count
	return s.b[:], offs
}

@(private="file")
lp_pdb_sechdr :: proc(secs: []Pdb_Section) -> []u8 {
	s: Pbuf
	for sec in secs {
		nb: [8]u8; copy(nb[:], transmute([]u8)sec.name); pb_raw(&s, nb[:])
		pb_u32(&s, sec.vsize); pb_u32(&s, sec.rva); pb_u32(&s, sec.rawsize); pb_u32(&s, sec.raw_ptr)
		pb_u32(&s, 0); pb_u32(&s, 0); pb_u16(&s, 0); pb_u16(&s, 0); pb_u32(&s, sec.characteristics)
	}
	return s.b[:]
}

// A C13 subsection wrapper: kind, len, data, pad to 4.
@(private="file")
lp_pdb_c13 :: proc(s: ^Pbuf, kind: u32, data: []u8) {
	pb_u32(s, kind); pb_u32(s, u32(len(data))); pb_raw(s, data)
	for len(s.b)%4 != 0 { pb_u8(s, 0) }
}

// Module 0 symbol stream. Returns (bytes, symByteSize, c13ByteSize).
// `chk_off[i]` is the byte offset of file i's entry within the FileChecksums
// subsection (computed here as 8 bytes per file, in `files` order).
// Map an image RVA to a 1-based CodeView (segment, section-relative offset).
@(private="file")
lp_rva_seg :: proc(secs: []Pdb_Section, rva: u32) -> (seg: u16, off: u32) {
	for s, i in secs {
		if rva >= s.rva && rva < s.rva + s.vsize {
			return u16(i+1), rva - s.rva
		}
	}
	return 1, rva // fallback
}

// MD5 of a source file's raw bytes, or ok=false if it can't be read. The debugger
// recomputes the same hash on the file it opens and (under requireExactSource / VS's
// "require source files to exactly match") binds a source breakpoint only to a module
// whose checksum matches — so the current on-disk source binds to THIS patch, not the
// exe's stale copy which was built from an older version.
@(private="file")
lp_file_md5 :: proc(path: string) -> (digest: [16]u8, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	md5.final(&ctx, digest[:])
	return digest, true
}

@(private="file")
lp_pdb_mod :: proc(funcs: []Pdb_Func, secs: []Pdb_Section, file_offs: []u32, files: []string) -> (data: []u8, sym_size: u32, c13_size: u32) {
	s: Pbuf
	pb_u32(&s, 4) // CV_SIGNATURE_C13
	rec :: proc(s: ^Pbuf, kind: u16, body: []u8) { pb_u16(s, u16(2+len(body))); pb_u16(s, kind); pb_raw(s, body) }
	{ b: Pbuf; pb_u32(&b, 0); pb_str(&b, "mod0.obj"); pb_pad4(&b); rec(&s, 0x1101, b.b[:]) } // S_OBJNAME
	{ b: Pbuf; pb_u32(&b, 0); pb_u16(&b, 0xD0); for _ in 0..<8 { pb_u16(&b, 0) }; pb_str(&b, "odin-livepatch"); pb_pad4(&b); rec(&s, 0x113C, b.b[:]) } // S_COMPILE3

	for f in funcs {
		seg, off := lp_rva_seg(secs, f.rva)
		gp := len(s.b)
		{
			b: Pbuf
			pb_u32(&b, 0)                    // parent
			pb_u32(&b, 0)                    // end (patched below)
			pb_u32(&b, 0)                    // next
			pb_u32(&b, f.size)               // codeSize
			pb_u32(&b, 0)                    // dbgStart
			pb_u32(&b, f.size)               // dbgEnd
			pb_u32(&b, 0)                    // typeIndex
			pb_u32(&b, off)                  // offset within section
			pb_u16(&b, seg)                  // segment (1-based section index)
			pb_u8(&b, 0)                     // flags
			pb_str(&b, f.name); pb_pad4(&b)
			rec(&s, 0x1110, b.b[:])          // S_GPROC32
		}
		endp := len(s.b)
		rec(&s, 0x0006, {})                  // S_END
		ep := u32(endp); copy(s.b[gp+8:], (cast([^]u8)&ep)[:4]) // patch 'end'
	}
	sym_size = u32(len(s.b) - 4)

	c13_start := len(s.b)
	// FileChecksums: one entry per file. An entry is {nameOffset u32, cb u8, kind u8,
	// checksum[cb]} padded to 4 bytes — variable length now that a real MD5 (kind 1) is
	// emitted when the source is readable, so each file's byte offset is tracked in
	// chk_offs and referenced by the Lines subsection below (was a fixed file*8).
	fc: Pbuf
	chk_offs := make([]u32, len(file_offs), context.temp_allocator)
	for off, i in file_offs {
		chk_offs[i] = u32(len(fc.b))
		pb_u32(&fc, off)
		digest: [16]u8
		ok := false
		if i < len(files) {
			digest, ok = lp_file_md5(files[i])
		}
		if ok {
			pb_u8(&fc, 16); pb_u8(&fc, 1); pb_raw(&fc, digest[:]) // cb=16, kind=MD5
		} else {
			pb_u8(&fc, 0); pb_u8(&fc, 0)                          // cb=0, kind=None
		}
		for len(fc.b) % 4 != 0 { pb_u8(&fc, 0) }
	}
	lp_pdb_c13(&s, 0xF4, fc.b[:])
	// Lines: one subsection per function.
	for f in funcs {
		if len(f.lines) == 0 { continue }
		seg, off := lp_rva_seg(secs, f.rva)
		ln: Pbuf
		pb_u32(&ln, off); pb_u16(&ln, seg); pb_u16(&ln, 0); pb_u32(&ln, f.size)
		pb_u32(&ln, chk_offs[f.file])       // byte offset of file f's checksum entry
		pb_u32(&ln, u32(len(f.lines)))
		pb_u32(&ln, u32(12 + len(f.lines)*8))
		for l in f.lines { pb_u32(&ln, l.offset); pb_u32(&ln, l.line | 0x80000000) }
		lp_pdb_c13(&s, 0xF2, ln.b[:])
	}
	c13_size = u32(len(s.b) - c13_start)
	pb_u32(&s, 0) // trailing GlobalRefsSize
	return s.b[:], sym_size, c13_size
}

@(private="file")
lp_pdb_dbi :: proc(mod_sym_size, mod_c13_size: u32, secs: []Pdb_Section, files: []string, age: u32) -> []u8 {
	source_files := len(files)
	s: Pbuf
	// ModInfo (one module)
	mi: Pbuf
	pb_u32(&mi, 0)
	// SectionContribEntry (28 bytes) — cover the whole first section
	pb_u16(&mi, 1); pb_u16(&mi, 0); pb_u32(&mi, 0); pb_u32(&mi, secs[0].vsize if len(secs) > 0 else 0)
	pb_u32(&mi, secs[0].characteristics if len(secs) > 0 else 0); pb_u16(&mi, 0); pb_u16(&mi, 0); pb_u32(&mi, 0); pb_u32(&mi, 0)
	pb_u16(&mi, 0)                 // flags
	pb_u16(&mi, PS_MOD0)           // module sym stream
	pb_u32(&mi, mod_sym_size+4)    // symByteSize (incl signature)
	pb_u32(&mi, 0)                 // C11
	pb_u32(&mi, mod_c13_size)      // C13
	pb_u16(&mi, u16(source_files)) // source file count
	pb_u16(&mi, 0); pb_u32(&mi, 0); pb_u32(&mi, 0); pb_u32(&mi, 0)
	pb_str(&mi, "mod0.obj"); pb_str(&mi, "mod0.obj"); for len(mi.b)%4 != 0 { pb_u8(&mi, 0) }
	modinfo := mi.b[:]

	// SectionContribution substream
	sc: Pbuf
	pb_u32(&sc, 0xF12EBA2D)
	for sec, i in secs {
		pb_u16(&sc, u16(i+1)); pb_u16(&sc, 0); pb_u32(&sc, 0); pb_u32(&sc, sec.vsize)
		pb_u32(&sc, sec.characteristics); pb_u16(&sc, 0); pb_u16(&sc, 0); pb_u32(&sc, 0); pb_u32(&sc, 0)
	}
	seccontrib := sc.b[:]

	// SectionMap. Frame must be the 1-based segment (section) index — dbghelp uses
	// it to translate segment:offset into an RVA; all-zero frames break multi-section
	// resolution (and make dbghelp reject the PDB).
	sm: Pbuf
	pb_u16(&sm, u16(len(secs))); pb_u16(&sm, u16(len(secs)))
	for sec, i in secs {
		pb_u16(&sm, 0x10D); pb_u16(&sm, 0); pb_u16(&sm, 0); pb_u16(&sm, u16(i+1)); pb_u16(&sm, 0xFFFF); pb_u16(&sm, 0xFFFF); pb_u32(&sm, 0); pb_u32(&sm, sec.vsize)
	}
	sectionmap := sm.b[:]

	// SourceInfo (DBI "FileInfo" substream): NumModules, NumSourceFiles, ModIndices[],
	// ModFileCounts[], FileNameOffsets[], then the NamesBuffer of null-terminated names.
	// The names MUST be real: an external debugger (lldb/DIA/raddbg) builds each compile
	// unit's source-file list from HERE, and matches a source breakpoint's file against it.
	// Emitting empty names (offset 0 into an empty buffer) left the patch module with no
	// source file, so forward source→address binding silently failed even though reverse
	// lookup — which uses the C13 checksums/lines instead — worked.
	si: Pbuf
	pb_u16(&si, 1); pb_u16(&si, u16(source_files))
	pb_u16(&si, 0); pb_u16(&si, u16(source_files))
	nmb: Pbuf
	name_offs := make([]u32, source_files, context.temp_allocator)
	for f, i in files {
		name_offs[i] = u32(len(nmb.b))
		pb_raw(&nmb, transmute([]u8)f); pb_u8(&nmb, 0)
	}
	for o in name_offs { pb_u32(&si, o) }
	pb_raw(&si, nmb.b[:])
	for len(si.b)%4 != 0 { pb_u8(&si, 0) }
	sourceinfo := si.b[:]

	// OptionalDbgHeader: index 5 = section headers
	odh: Pbuf
	for i in 0..<11 { pb_u16(&odh, u16(PS_SECHDR) if i == 5 else 0xFFFF) }
	optdbg := odh.b[:]

	pb_i32(&s, -1); pb_u32(&s, 19990903); pb_u32(&s, age) // DBI Age must match RSDS/info age
	pb_u16(&s, PS_GSI); pb_u16(&s, 0x8e0a); pb_u16(&s, PS_PSI); pb_u16(&s, 0); pb_u16(&s, PS_SYM); pb_u16(&s, 0)
	pb_i32(&s, i32(len(modinfo))); pb_i32(&s, i32(len(seccontrib))); pb_i32(&s, i32(len(sectionmap)))
	pb_i32(&s, i32(len(sourceinfo))); pb_i32(&s, 0); pb_u32(&s, 0); pb_i32(&s, i32(len(optdbg))); pb_i32(&s, 0)
	pb_u16(&s, 1); pb_u16(&s, 0x8664); pb_u32(&s, 0)
	pb_raw(&s, modinfo); pb_raw(&s, seccontrib); pb_raw(&s, sectionmap); pb_raw(&s, sourceinfo); pb_raw(&s, optdbg)
	return s.b[:]
}

@(private="file")
lp_pdb_gsi :: proc() -> []u8 {
	s: Pbuf; pb_u32(&s, 0xFFFFFFFF); pb_u32(&s, 0xF12F091A); pb_u32(&s, 0); pb_u32(&s, 0); return s.b[:]
}
@(private="file")
lp_pdb_psi :: proc() -> []u8 {
	s: Pbuf
	pb_u32(&s, 16); pb_u32(&s, 0); pb_u32(&s, 0); pb_u32(&s, 0); pb_u16(&s, 0); pb_u16(&s, 0); pb_u32(&s, 0); pb_u32(&s, 0)
	pb_u32(&s, 0xFFFFFFFF); pb_u32(&s, 0xF12F091A); pb_u32(&s, 0); pb_u32(&s, 0)
	return s.b[:]
}

@(private="file")
pdb_nblocks :: proc(n: int) -> int { return (n + PDB_BLOCK - 1) / PDB_BLOCK }

// Emits a complete PDB describing `funcs` (with line info) laid out in `secs`,
// referencing source `files`, stamped with `guid`/`age`.
lp_emit_pdb :: proc(guid: [16]u8, age: u32, funcs: []Pdb_Func, files: []string, secs: []Pdb_Section) -> []u8 {
	names, name_offs := lp_pdb_names(files) // name_offs[i] = byte offset of file i's name in /names

	mod, sym_sz, c13_sz := lp_pdb_mod(funcs, secs, name_offs, files)

	streams := make([][]u8, PS_COUNT, context.temp_allocator)
	streams[PS_OLD] = {}
	streams[PS_INFO] = lp_pdb_info(guid, age)
	streams[PS_TPI] = lp_pdb_tpi(PS_TPIHASH)
	streams[PS_DBI] = lp_pdb_dbi(sym_sz, c13_sz, secs, files, age)
	streams[PS_IPI] = lp_pdb_tpi(PS_IPIHASH)
	streams[PS_NAMES] = names
	streams[PS_SECHDR] = lp_pdb_sechdr(secs)
	streams[PS_MOD0] = mod
	streams[PS_GSI] = lp_pdb_gsi()
	streams[PS_PSI] = lp_pdb_psi()
	streams[PS_SYM] = {}
	streams[PS_TPIHASH] = {}
	streams[PS_IPIHASH] = {}
	ns := len(streams)

	stream_blocks := make([][]u32, ns, context.temp_allocator)
	next := 3
	for st, i in streams {
		nb := pdb_nblocks(len(st)); blks := make([]u32, nb, context.temp_allocator)
		for j in 0..<nb { blks[j] = u32(next); next += 1 }
		stream_blocks[i] = blks
	}
	dir: Pbuf
	pb_u32(&dir, u32(ns))
	for st in streams { pb_u32(&dir, u32(len(st))) }
	for blks in stream_blocks { for b in blks { pb_u32(&dir, b) } }
	dir_bytes := dir.b[:]
	dir_nb := pdb_nblocks(len(dir_bytes)); dir_blocks := make([]u32, dir_nb, context.temp_allocator)
	for j in 0..<dir_nb { dir_blocks[j] = u32(next); next += 1 }
	block_map := next; next += 1
	total := next

	out := make([]u8, total * PDB_BLOCK)
	sb: Pbuf
	pb_raw(&sb, transmute([]u8)string("Microsoft C/C++ MSF 7.00\r\n")); pb_raw(&sb, []u8{0x1A,'D','S',0,0,0})
	pb_u32(&sb, PDB_BLOCK); pb_u32(&sb, 1); pb_u32(&sb, u32(total)); pb_u32(&sb, u32(len(dir_bytes))); pb_u32(&sb, 0); pb_u32(&sb, u32(block_map))
	copy(out[0:], sb.b[:])
	for i in PDB_BLOCK..<(3*PDB_BLOCK) { out[i] = 0xFF }         // FPM blocks 1,2 = all free
	for i in 0..<total { out[PDB_BLOCK + i/8] &= ~(u8(1) << u32(i%8)) } // mark used in block 1 (FreeBlockMapBlock=1)
	for st, i in streams {
		for j in 0..<len(stream_blocks[i]) {
			blk := int(stream_blocks[i][j]); off := j*PDB_BLOCK; n := min(PDB_BLOCK, len(st)-off)
			copy(out[blk*PDB_BLOCK:], st[off:off+n])
		}
	}
	for j in 0..<dir_nb {
		blk := int(dir_blocks[j]); off := j*PDB_BLOCK; n := min(PDB_BLOCK, len(dir_bytes)-off)
		copy(out[blk*PDB_BLOCK:], dir_bytes[off:off+n])
	}
	bm: Pbuf; for b in dir_blocks { pb_u32(&bm, b) }
	copy(out[block_map*PDB_BLOCK:], bm.b[:])
	return out
}
