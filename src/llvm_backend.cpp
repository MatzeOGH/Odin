#define MULTITHREAD_OBJECT_GENERATION 1
#ifndef MULTITHREAD_OBJECT_GENERATION
#define MULTITHREAD_OBJECT_GENERATION 0
#endif

#ifndef USE_SEPARATE_MODULES
#define USE_SEPARATE_MODULES build_context.use_separate_modules
#endif

#ifndef LLVM_IGNORE_VERIFICATION
#define LLVM_IGNORE_VERIFICATION build_context.internal_ignore_llvm_verification
#endif

#ifndef LLVM_WEAK_MONOMORPHIZATION
#define LLVM_WEAK_MONOMORPHIZATION (USE_SEPARATE_MODULES && build_context.internal_weak_monomorphization)
#endif

#define LLVM_SET_INTERNAL_WEAK_LINKAGE(value) LLVMSetLinkage(value, USE_SEPARATE_MODULES ? LLVMWeakAnyLinkage : LLVMInternalLinkage);


#include "llvm_backend.hpp"
#include "llvm_abi.cpp"
#include "llvm_backend_opt.cpp"
#include "llvm_backend_general.cpp"
#include "llvm_backend_debug.cpp"
#include "llvm_backend_const.cpp"
#include "llvm_backend_type.cpp"
#include "llvm_backend_utility.cpp"
#include "llvm_backend_expr.cpp"
#include "llvm_backend_stmt.cpp"
#include "llvm_backend_proc.cpp"
#include "llvm_backend_asm.cpp"

gb_internal String get_default_microarchitecture() {
	String default_march = str_lit("generic");
	if (build_context.metrics.arch == TargetArch_amd64) {
		// NOTE(bill): x86-64-v2 is more than enough for everyone
		//
		// x86-64: CMOV, CMPXCHG8B, FPU, FXSR, MMX, FXSR, SCE, SSE, SSE2
		// x86-64-v2: (close to Nehalem) CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSE4.1, SSE4.2, SSSE3
		// x86-64-v3: (close to Haswell) AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, XSAVE
		// x86-64-v4: AVX512F, AVX512BW, AVX512CD, AVX512DQ, AVX512VL
		if (build_context.metrics.os == TargetOs_freestanding) {
			default_march = str_lit("x86-64");
		} else {
			default_march = str_lit("x86-64-v2");
		}
	} else if (build_context.metrics.arch == TargetArch_riscv64) {
		default_march = str_lit("generic-rv64");
	} else if (build_context.metrics.arch == TargetArch_arm32) {
		// The arm32 triple is `gnueabihf`, and the hard-float ABI passes floating point in the
		// VFP registers. `generic` has no FPU at all. LLVM cannot honor the ABI its own
		// triple asks for and quietly falls back to the soft-float convention.
		//
		// `arm1176jzf-s` is what clang picks by default for this same triple.
		default_march = str_lit("arm1176jzf-s");
	}

	return default_march;
}

gb_internal String get_final_microarchitecture() {
	BuildContext *bc = &build_context;

	String microarch = bc->microarch;
	if (microarch.len == 0) {
		microarch = get_default_microarchitecture();
	} else if (microarch == str_lit("native")) {
		microarch = make_string_c(LLVMGetHostCPUName());
	}
	return microarch;
}

gb_internal String get_default_features() {
	BuildContext *bc = &build_context;

	if (bc->microarch == str_lit("native")) {
		String features = make_string_c(LLVMGetHostCPUFeatures());

		// Update the features string so LLVM uses it later.
		if (bc->target_features_string.len > 0) {
			bc->target_features_string = concatenate3_strings(permanent_allocator(), features, str_lit(","), bc->target_features_string);
		} else {
			bc->target_features_string = features;
		}

		return features;
	}

	int off = 0;
	for (int i = 0; i < bc->metrics.arch; i += 1) {
		off += target_microarch_counts[i];
	}

	String microarch = get_final_microarchitecture();

	// NOTE(laytan): for riscv64 to work properly with Odin, we need to enforce some features.
	// and we also overwrite the generic target to include more features so we don't default to
	// a potato feature set.
	if (bc->metrics.arch == TargetArch_riscv64) {
		if (microarch == str_lit("generic-rv64")) {
			// This is what clang does by default (on -march=rv64gc for General Computing), seems good to also default to.
			String features = str_lit("64bit,a,c,d,f,m,relax,zicsr,zifencei");

			// Update the features string so LLVM uses it later.
			if (bc->target_features_string.len > 0) {
				bc->target_features_string = concatenate3_strings(permanent_allocator(), features, str_lit(","), bc->target_features_string);
			} else {
				bc->target_features_string = features;
			}

			return features;
		}
	}

	for (int i = off; i < off+target_microarch_counts[bc->metrics.arch]; i += 1) {
		if (microarch_features_list[i].microarch == microarch) {
			return microarch_features_list[i].features;
		}
	}

	GB_PANIC("unknown microarch: %.*s", LIT(microarch));
	return {};
}

gb_internal void lb_add_foreign_library_path(lbModule *m, Entity *e) {
	if (e == nullptr) {
		return;
	}
	GB_ASSERT(e->kind == Entity_LibraryName);
	GB_ASSERT(e->flags & EntityFlag_Used);

	mutex_lock(&m->gen->foreign_mutex);
	if (!ptr_set_update(&m->gen->foreign_libraries_set, e)) {
		array_add(&m->gen->foreign_libraries, e);
	}
	mutex_unlock(&m->gen->foreign_mutex);
}

gb_internal GB_COMPARE_PROC(foreign_library_cmp) {
	int cmp = 0;
	Entity *x = *(Entity **)a;
	Entity *y = *(Entity **)b;
	if (x == y) {
		return 0;
	}
	GB_ASSERT(x->kind == Entity_LibraryName);
	GB_ASSERT(y->kind == Entity_LibraryName);

	cmp = i64_cmp(x->LibraryName.priority_index, y->LibraryName.priority_index);
	if (cmp) {
		return cmp;
	}

	if (x->pkg != y->pkg) {
		isize order_x = x->pkg ? x->pkg->order : 0;
		isize order_y = y->pkg ? y->pkg->order : 0;
		cmp = isize_cmp(order_x, order_y);
		if (cmp) {
			return cmp;
		}
	}
	if (x->file != y->file) {
		String fullpath_x = x->file ? x->file->fullpath : (String{});
		String fullpath_y = y->file ? y->file->fullpath : (String{});
		String file_x = filename_from_path(fullpath_x);
		String file_y = filename_from_path(fullpath_y);

		cmp = string_compare(file_x, file_y);
		if (cmp) {
			return cmp;
		}
	}

	cmp = u64_cmp(x->order_in_src, y->order_in_src);
	if (cmp) {
		return cmp;
	}
	return i32_cmp(x->token.pos.offset, y->token.pos.offset);
}

gb_internal void lb_set_entity_from_other_modules_linkage_correctly(lbModule *other_module, Entity *e, String const &name) {
	if (other_module == nullptr) {
		return;
	}
	char const *cname = alloc_cstring(permanent_allocator(), name);
	mpsc_enqueue(&other_module->gen->entities_to_correct_linkage, lbEntityCorrection{other_module, e, cname});
}

gb_internal void lb_correct_entity_linkage(lbGenerator *gen) {
	for (lbEntityCorrection ec = {}; mpsc_dequeue(&gen->entities_to_correct_linkage, &ec); /**/) {
		LLVMValueRef other_global = nullptr;
		if (ec.e->kind == Entity_Variable) {
			other_global = LLVMGetNamedGlobal(ec.other_module->mod, ec.cname);
			if (other_global && (LLVMGetInitializer(other_global) != nullptr || LLVMIsExternallyInitialized(other_global))) {
				LLVM_SET_INTERNAL_WEAK_LINKAGE(other_global);
				if (!ec.e->Variable.is_export && !ec.e->Variable.is_foreign) {
					LLVMSetVisibility(other_global, LLVMHiddenVisibility);
				}
			}
		} else if (ec.e->kind == Entity_Procedure) {
			other_global = LLVMGetNamedFunction(ec.other_module->mod, ec.cname);
			if (other_global && LLVMCountBasicBlocks(other_global) != 0) {
				LLVM_SET_INTERNAL_WEAK_LINKAGE(other_global);
				if (!ec.e->Procedure.is_export && !ec.e->Procedure.is_foreign) {
					LLVMSetVisibility(other_global, LLVMHiddenVisibility);
				}
			}
		}
	}
}


gb_internal void lb_emit_init_context(lbProcedure *p, lbAddr addr) {
	TEMPORARY_ALLOCATOR_GUARD();

	GB_ASSERT(addr.kind == lbAddr_Context);
	GB_ASSERT(addr.ctx.sel.index.count == 0);

	auto args = array_make<lbValue>(temporary_allocator(), 1);
	args[0] = addr.addr;
	lb_emit_runtime_call(p, "__init_context", args);
}

gb_internal lbContextData *lb_push_context_onto_stack_from_implicit_parameter(lbProcedure *p) {
	Type *pt = base_type(p->type);
	GB_ASSERT(pt->kind == Type_Proc);
	GB_ASSERT(pt->Proc.calling_convention == ProcCC_Odin);

	String name = str_lit("__.context_ptr");

	Entity *e = alloc_entity_param(nullptr, make_token_ident(name), t_context_ptr, false, false);
	e->flags |= EntityFlag_NoAlias;

	LLVMValueRef context_ptr = LLVMGetParam(p->value, LLVMCountParams(p->value)-1);
	LLVMSetValueName2(context_ptr, cast(char const *)name.text, name.len);
	context_ptr = LLVMBuildPointerCast(p->builder, context_ptr, lb_type(p->module, e->type), "");

	lbValue param = {context_ptr, e->type};
	lb_add_entity(p->module, e, param);
	lbAddr ctx_addr = {};
	ctx_addr.kind = lbAddr_Context;
	ctx_addr.addr = param;

	lbContextData *cd = array_add_and_get(&p->context_stack);
	cd->ctx = ctx_addr;
	cd->scope_index = -1;
	cd->uses = +1; // make sure it has been used already
	return cd;
}

gb_internal lbContextData *lb_push_context_onto_stack(lbProcedure *p, lbAddr ctx) {
	ctx.kind = lbAddr_Context;
	lbContextData *cd = array_add_and_get(&p->context_stack);
	cd->ctx = ctx;
	cd->scope_index = p->scope_index;
	return cd;
}


gb_internal String lb_internal_gen_name_from_type(char const *prefix, Type *type) {
	gbString str = gb_string_make(permanent_allocator(), prefix);
	str = gb_string_appendc(str, "$$");
	gbString ct = temp_canonical_string(type);
	str = gb_string_append_length(str, ct, gb_string_length(ct));
	String proc_name = make_string(cast(u8 const *)str, gb_string_length(str));
	return proc_name;
}

gb_internal void lb_equal_proc_generate_body(lbModule *m, lbProcedure *p) {
	Type *type = p->internal_gen_type;

	Type *pt = alloc_type_pointer(type);
	LLVMTypeRef ptr_type = lb_type(m, pt);

	lb_begin_procedure_body(p);

	LLVMSetLinkage(p->value, LLVMInternalLinkage);
	// lb_add_attribute_to_proc(m, p->value, "readonly");
	lb_add_attribute_to_proc(m, p->value, "nounwind");

	LLVMValueRef x = LLVMGetParam(p->value, 0);
	LLVMValueRef y = LLVMGetParam(p->value, 1);
	x = LLVMBuildPointerCast(p->builder, x, ptr_type, "");
	y = LLVMBuildPointerCast(p->builder, y, ptr_type, "");
	lbValue lhs = {x, pt};
	lbValue rhs = {y, pt};

	lb_add_proc_attribute_at_index(p, 1+0, "nonnull");
	lb_add_proc_attribute_at_index(p, 1+1, "nonnull");

	lbBlock *block_same_ptr = lb_create_block(p, "same_ptr");
	lbBlock *block_diff_ptr = lb_create_block(p, "diff_ptr");

	lbValue same_ptr = lb_emit_comp(p, Token_CmpEq, lhs, rhs);
	lb_emit_if(p, same_ptr, block_same_ptr, block_diff_ptr);
	lb_start_block(p, block_same_ptr);
	LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 1, false));

	lb_start_block(p, block_diff_ptr);

	if (type->kind == Type_Struct) {
		type_set_offsets(type);

		lbBlock *block_false = lb_create_block(p, "bfalse");
		lbValue res = lb_const_bool(m, t_bool, true);

		for_array(i, type->Struct.fields) {
			lbBlock *next_block = lb_create_block(p, "btrue");

			lbValue pleft  = lb_emit_struct_ep(p, lhs, cast(i32)i);
			lbValue pright = lb_emit_struct_ep(p, rhs, cast(i32)i);
			lbValue left = lb_emit_load(p, pleft);
			lbValue right = lb_emit_load(p, pright);
			lbValue ok = lb_emit_comp(p, Token_CmpEq, left, right);

			lb_emit_if(p, ok, next_block, block_false);

			lb_emit_jump(p, next_block);
			lb_start_block(p, next_block);
		}

		LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 1, false));

		lb_start_block(p, block_false);

		LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 0, false));
	} else if (type->kind == Type_Union) {
		if (type_size_of(type) == 0) {
			LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 1, false));
		} else if (is_type_union_maybe_pointer(type)) {
			Type *v = type->Union.variants[0];
			Type *pv = alloc_type_pointer(v);

			lbValue left = lb_emit_load(p, lb_emit_conv(p, lhs, pv));
			lbValue right = lb_emit_load(p, lb_emit_conv(p, rhs, pv));

			lbValue ok = lb_emit_comp(p, Token_CmpEq, left, right);
			ok = lb_emit_conv(p, ok, t_bool);
			LLVMBuildRet(p->builder, ok.value);
		} else {
			lbBlock *block_false  = lb_create_block(p, "bfalse");
			lbBlock *block_switch = lb_create_block(p, "bswitch");

			lbValue left_tag  = lb_emit_load(p, lb_emit_union_tag_ptr(p, lhs));
			lbValue right_tag = lb_emit_load(p, lb_emit_union_tag_ptr(p, rhs));

			lbValue tag_eq = lb_emit_comp(p, Token_CmpEq, left_tag, right_tag);
			lb_emit_if(p, tag_eq, block_switch, block_false);

			lb_start_block(p, block_switch);

			unsigned variant_count = cast(unsigned)type->Union.variants.count;
			if (type->Union.kind != UnionType_no_nil) {
				variant_count += 1;
			}
			LLVMValueRef v_switch = LLVMBuildSwitch(p->builder, left_tag.value, block_false->block, variant_count);

			if (type->Union.kind != UnionType_no_nil) {
				lbBlock *case_block = lb_create_block(p, "bcase");
				lb_start_block(p, case_block);

				lbValue case_tag = lb_const_int(p->module, union_tag_type(type), 0);

				LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 1, false));

				LLVMAddCase(v_switch, case_tag.value, case_block->block);
			}

			for (Type *v : type->Union.variants) {
				lbBlock *case_block = lb_create_block(p, "bcase");
				lb_start_block(p, case_block);

				lbValue case_tag = lb_const_union_tag(p->module, type, v);

				Type *vp = alloc_type_pointer(v);

				lbValue left  = lb_emit_load(p, lb_emit_conv(p, lhs, vp));
				lbValue right = lb_emit_load(p, lb_emit_conv(p, rhs, vp));
				lbValue ok = lb_emit_comp(p, Token_CmpEq, left, right);
				ok = lb_emit_conv(p, ok, t_bool);

				LLVMBuildRet(p->builder, ok.value);


				LLVMAddCase(v_switch, case_tag.value, case_block->block);
			}

			lb_start_block(p, block_false);

			LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_bool), 0, false));
		}

	} else {
		lbValue left = lb_emit_load(p, lhs);
		lbValue right = lb_emit_load(p, rhs);
		lbValue ok = lb_emit_comp(p, Token_CmpEq, left, right);
		ok = lb_emit_conv(p, ok, t_bool);
		LLVMBuildRet(p->builder, ok.value);
	}

	lb_end_procedure_body(p);
}

gb_internal lbValue lb_equal_proc_for_type(lbModule *m, Type *type) {
	type = base_type(type);
	GB_ASSERT(is_type_comparable(type));

	String proc_name = lb_internal_gen_name_from_type("__$equal", type);
	lbProcedure **found = string_map_get(&m->gen_procs, proc_name);
	if (found) {
		lbProcedure *p = *found;
		GB_ASSERT(p != nullptr);
		return {p->value, p->type};
	}

	lbProcedure *p = lb_create_dummy_procedure(m, proc_name, t_equal_proc);
	string_map_set(&m->gen_procs, proc_name, p);
	p->internal_gen_type = type;
	p->generate_body = lb_equal_proc_generate_body;

	// p->generate_body(m, p);
	mpsc_enqueue(&m->procedures_to_generate, p);

	return {p->value, p->type};
}

gb_internal lbValue lb_simple_compare_hash(lbProcedure *p, Type *type, lbValue data, lbValue seed) {
	TEMPORARY_ALLOCATOR_GUARD();

	GB_ASSERT_MSG(is_type_simple_compare(type), "%s", type_to_string(type));

	auto args = array_make<lbValue>(temporary_allocator(), 3);
	args[0] = data;
	args[1] = seed;
	args[2] = lb_const_int(p->module, t_int, type_size_of(type));
	return lb_emit_runtime_call(p, "default_hasher", args);
}

gb_internal void lb_add_callsite_force_inline(lbProcedure *p, lbValue ret_value) {
	LLVMAddCallSiteAttribute(ret_value.value, LLVMAttributeIndex_FunctionIndex, lb_create_enum_attribute(p->module->ctx, "alwaysinline"));
}

gb_internal lbValue lb_hasher_proc_for_type(lbModule *m, Type *type) {
	type = core_type(type);
	GB_ASSERT_MSG(is_type_comparable(type), "%s", type_to_string(type));

	Type *pt = alloc_type_pointer(type);

	String proc_name = lb_internal_gen_name_from_type("__$hasher", type);
	lbProcedure **found = string_map_get(&m->gen_procs, proc_name);
	if (found) {
		GB_ASSERT(*found != nullptr);
		return {(*found)->value, (*found)->type};
	}

	lbProcedure *p = lb_create_dummy_procedure(m, proc_name, t_hasher_proc);
	string_map_set(&m->gen_procs, proc_name, p);
	lb_begin_procedure_body(p);
	defer (lb_end_procedure_body(p));

	LLVMSetLinkage(p->value, LLVMInternalLinkage);
	// lb_add_attribute_to_proc(m, p->value, "readonly");
	lb_add_attribute_to_proc(m, p->value, "nounwind");

	LLVMValueRef x = LLVMGetParam(p->value, 0);
	LLVMValueRef y = LLVMGetParam(p->value, 1);
	lbValue data = {x, t_rawptr};
	lbValue seed = {y, t_uintptr};

	lb_add_proc_attribute_at_index(p, 1+0, "nonnull");
	// lb_add_proc_attribute_at_index(p, 1+0, "readonly");

	if (is_type_simple_compare(type)) {
		lbValue res = lb_simple_compare_hash(p, type, data, seed);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
		return {p->value, p->type};
	}

	TEMPORARY_ALLOCATOR_GUARD();

	if (type->kind == Type_Struct)  {
		type_set_offsets(type);
		data = lb_emit_conv(p, data, t_u8_ptr);

		auto args = array_make<lbValue>(temporary_allocator(), 2);
		for_array(i, type->Struct.fields) {
			GB_ASSERT(type->Struct.offsets != nullptr);
			i64 offset = type->Struct.offsets[i];
			Entity *field = type->Struct.fields[i];
			lbValue field_hasher = lb_hasher_proc_for_type(m, field->type);
			lbValue ptr = lb_emit_ptr_offset(p, data, lb_const_int(m, t_uintptr, offset));

			args[0] = ptr;
			args[1] = seed;
			seed = lb_emit_call(p, field_hasher, args);
		}
		LLVMBuildRet(p->builder, seed.value);
	} else if (type->kind == Type_Union)  {
		auto args = array_make<lbValue>(temporary_allocator(), 2);

		if (is_type_union_maybe_pointer(type)) {
			Type *v = type->Union.variants[0];
			lbValue variant_hasher = lb_hasher_proc_for_type(m, v);

			args[0] = data;
			args[1] = seed;
			lbValue res = lb_emit_call(p, variant_hasher, args);
			lb_add_callsite_force_inline(p, res);
			LLVMBuildRet(p->builder, res.value);
		}

		lbBlock *end_block = lb_create_block(p, "bend");
		data = lb_emit_conv(p, data, pt);

		lbValue tag_ptr = lb_emit_union_tag_ptr(p, data);
		lbValue tag = lb_emit_load(p, tag_ptr);

		LLVMValueRef v_switch = LLVMBuildSwitch(p->builder, tag.value, end_block->block, cast(unsigned)type->Union.variants.count);

		for (Type *v : type->Union.variants) {
			lbBlock *case_block = lb_create_block(p, "bcase");
			lb_start_block(p, case_block);

			lbValue case_tag = lb_const_union_tag(p->module, type, v);

			lbValue variant_hasher = lb_hasher_proc_for_type(m, v);

			args[0] = data;
			args[1] = seed;
			lbValue res = lb_emit_call(p, variant_hasher, args);
			LLVMBuildRet(p->builder, res.value);

			LLVMAddCase(v_switch, case_tag.value, case_block->block);
		}

		lb_start_block(p, end_block);
		LLVMBuildRet(p->builder, seed.value);

	} else if (type->kind == Type_Array) {
		lbAddr pres = lb_add_local_generated(p, t_uintptr, false);
		lb_addr_store(p, pres, seed);

		auto args = array_make<lbValue>(temporary_allocator(), 2);
		lbValue elem_hasher = lb_hasher_proc_for_type(m, type->Array.elem);

		auto loop_data = lb_loop_start(p, cast(isize)type->Array.count, t_i32);

		data = lb_emit_conv(p, data, pt);

		lbValue ptr = lb_emit_array_ep(p, data, loop_data.idx);
		args[0] = ptr;
		args[1] = lb_addr_load(p, pres);
		lbValue new_seed = lb_emit_call(p, elem_hasher, args);
		lb_addr_store(p, pres, new_seed);

		lb_loop_end(p, loop_data);

		lbValue res = lb_addr_load(p, pres);
		LLVMBuildRet(p->builder, res.value);
	} else if (type->kind == Type_EnumeratedArray) {
		lbAddr res = lb_add_local_generated(p, t_uintptr, false);
		lb_addr_store(p, res, seed);

		auto args = array_make<lbValue>(temporary_allocator(), 2);
		lbValue elem_hasher = lb_hasher_proc_for_type(m, type->EnumeratedArray.elem);

		auto loop_data = lb_loop_start(p, cast(isize)type->EnumeratedArray.count, t_i32);

		data = lb_emit_conv(p, data, pt);

		lbValue ptr = lb_emit_array_ep(p, data, loop_data.idx);
		args[0] = ptr;
		args[1] = lb_addr_load(p, res);
		lbValue new_seed = lb_emit_call(p, elem_hasher, args);
		lb_addr_store(p, res, new_seed);

		lb_loop_end(p, loop_data);

		lbValue vres = lb_addr_load(p, res);
		LLVMBuildRet(p->builder, vres.value);
	} else if (is_type_cstring(type)) {
		auto args = array_make<lbValue>(temporary_allocator(), 2);
		args[0] = data;
		args[1] = seed;
		lbValue res = lb_emit_runtime_call(p, "default_hasher_cstring", args);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
	} else if (is_type_string(type)) {
		auto args = array_make<lbValue>(temporary_allocator(), 2);
		args[0] = data;
		args[1] = seed;
		lbValue res = lb_emit_runtime_call(p, "default_hasher_string", args);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
	} else if (is_type_float(type)) {
		lbValue ptr = lb_emit_conv(p, data, pt);
		lbValue v = lb_emit_load(p, ptr);
		v = lb_emit_conv(p, v, t_f64);

		auto args = array_make<lbValue>(temporary_allocator(), 2);
		args[0] = v;
		args[1] = seed;
		lbValue res = lb_emit_runtime_call(p, "default_hasher_f64", args);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
	} else if (is_type_complex(type)) {
		lbValue ptr = lb_emit_conv(p, data, pt);
		lbValue xp = lb_emit_struct_ep(p, ptr, 0);
		lbValue yp = lb_emit_struct_ep(p, ptr, 1);

		lbValue x = lb_emit_conv(p, lb_emit_load(p, xp), t_f64);
		lbValue y = lb_emit_conv(p, lb_emit_load(p, yp), t_f64);

		auto args = array_make<lbValue>(temporary_allocator(), 3);
		args[0] = x;
		args[1] = y;
		args[2] = seed;
		lbValue res = lb_emit_runtime_call(p, "default_hasher_complex128", args);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
	} else if (is_type_quaternion(type)) {
		lbValue ptr = lb_emit_conv(p, data, pt);
		lbValue xp = lb_emit_struct_ep(p, ptr, 0);
		lbValue yp = lb_emit_struct_ep(p, ptr, 1);
		lbValue zp = lb_emit_struct_ep(p, ptr, 2);
		lbValue wp = lb_emit_struct_ep(p, ptr, 3);

		lbValue x = lb_emit_conv(p, lb_emit_load(p, xp), t_f64);
		lbValue y = lb_emit_conv(p, lb_emit_load(p, yp), t_f64);
		lbValue z = lb_emit_conv(p, lb_emit_load(p, zp), t_f64);
		lbValue w = lb_emit_conv(p, lb_emit_load(p, wp), t_f64);

		auto args = array_make<lbValue>(temporary_allocator(), 5);
		args[0] = x;
		args[1] = y;
		args[2] = z;
		args[3] = w;
		args[4] = seed;
		lbValue res = lb_emit_runtime_call(p, "default_hasher_quaternion256", args);
		lb_add_callsite_force_inline(p, res);
		LLVMBuildRet(p->builder, res.value);
	} else {
		GB_PANIC("Unhandled type for hasher: %s", type_to_string(type));
	}

	return {p->value, p->type};
}


#define LLVM_SET_VALUE_NAME(value, name) LLVMSetValueName2((value), (name), gb_count_of((name))-1);


gb_internal lbValue lb_map_get_proc_for_type(lbModule *m, Type *type) {
	GB_ASSERT(!build_context.dynamic_map_calls);
	type = base_type(type);
	GB_ASSERT(type->kind == Type_Map);

	String proc_name = lb_internal_gen_name_from_type("__$map_get", type);
	lbProcedure **found = string_map_get(&m->gen_procs, proc_name);
	if (found) {
		GB_ASSERT(*found != nullptr);
		return {(*found)->value, (*found)->type};
	}

	lbProcedure *p = lb_create_dummy_procedure(m, proc_name, t_map_get_proc);
	string_map_set(&m->gen_procs, proc_name, p);

	p->internal_gen_type = type;

	lb_begin_procedure_body(p);
	defer (lb_end_procedure_body(p));

	LLVMSetLinkage(p->value, LLVMInternalLinkage);
	lb_add_attribute_to_proc(m, p->value, "nounwind");
	if (build_context.ODIN_DEBUG) {
		lb_add_attribute_to_proc(m, p->value, "noinline");
	}

	LLVMValueRef x = LLVMGetParam(p->value, 0);
	LLVMValueRef y = LLVMGetParam(p->value, 1);
	LLVMValueRef z = LLVMGetParam(p->value, 2);
	lbValue map_ptr = {x, t_rawptr};
	lbValue h       = {y, t_uintptr};
	lbValue key_ptr = {z, t_rawptr};

	LLVM_SET_VALUE_NAME(h.value, "hash");

	lb_add_proc_attribute_at_index(p, 1+0, "nonnull");
	lb_add_proc_attribute_at_index(p, 1+0, "readonly");

	lb_add_proc_attribute_at_index(p, 1+2, "nonnull");
	lb_add_proc_attribute_at_index(p, 1+2, "readonly");

	lbBlock *loop_block         = lb_create_block(p, "loop");
	lbBlock *hash_block         = lb_create_block(p, "hash");
	lbBlock *probe_block        = lb_create_block(p, "probe");
	lbBlock *increment_block    = lb_create_block(p, "increment");
	lbBlock *hash_compare_block = lb_create_block(p, "hash_compare");
	lbBlock *key_compare_block  = lb_create_block(p, "key_compare");
	lbBlock *value_block        = lb_create_block(p, "value");
	lbBlock *nil_block          = lb_create_block(p, "nil");

	map_ptr = lb_emit_conv(p, map_ptr, t_raw_map_ptr);
	LLVM_SET_VALUE_NAME(map_ptr.value, "map_ptr");

	lbValue map = lb_emit_load(p, map_ptr);
	LLVM_SET_VALUE_NAME(map.value, "map");

	lbValue length = lb_map_len(p, map);
	LLVM_SET_VALUE_NAME(length.value, "length");

	lb_emit_if(p, lb_emit_comp(p, Token_CmpEq, length, lb_const_nil(m, t_int)), nil_block, hash_block);
	lb_start_block(p, hash_block);

	key_ptr = lb_emit_conv(p, key_ptr, alloc_type_pointer(type->Map.key));
	LLVM_SET_VALUE_NAME(key_ptr.value, "key_ptr");
	lbValue key = lb_emit_load(p, key_ptr);
	LLVM_SET_VALUE_NAME(key.value, "key");

	lbAddr pos = lb_add_local_generated(p, t_uintptr, false);
	lbAddr distance = lb_add_local_generated(p, t_uintptr, true);
	LLVM_SET_VALUE_NAME(pos.addr.value, "pos");
	LLVM_SET_VALUE_NAME(distance.addr.value, "distance");

	lbValue capacity = lb_map_cap(p, map);
	LLVM_SET_VALUE_NAME(capacity.value, "capacity");
	lbValue cap_minus_1 = lb_emit_arith(p, Token_Sub, capacity, lb_const_int(m, t_int, 1), t_int);
	lbValue mask = lb_emit_conv(p, cap_minus_1, t_uintptr);
	LLVM_SET_VALUE_NAME(mask.value, "mask");

	{
		// map_desired_position inlined
		lbValue the_pos = lb_emit_arith(p, Token_And, h, mask, t_uintptr);
		the_pos = lb_emit_conv(p, the_pos, t_uintptr);
		lb_addr_store(p, pos, the_pos);
	}
	lbValue zero_uintptr = lb_const_int(m, t_uintptr, 0);
	lbValue one_uintptr = lb_const_int(m, t_uintptr, 1);

	lbValue ks = lb_map_data_uintptr(p, map);
	lbValue vs = lb_map_cell_index_static(p, type->Map.key, ks, capacity);
	lbValue hs = lb_map_cell_index_static(p, type->Map.value, vs, capacity);

	ks = lb_emit_conv(p, ks, alloc_type_pointer(type->Map.key));
	vs = lb_emit_conv(p, vs, alloc_type_pointer(type->Map.value));
	hs = lb_emit_conv(p, hs, alloc_type_pointer(t_uintptr));

	LLVM_SET_VALUE_NAME(ks.value, "ks");
	LLVM_SET_VALUE_NAME(vs.value, "vs");
	LLVM_SET_VALUE_NAME(hs.value, "hs");

	lb_emit_jump(p, loop_block);
	lb_start_block(p, loop_block);

	lbValue element_hash = lb_emit_load(p, lb_emit_ptr_offset(p, hs, lb_addr_load(p, pos)));
	LLVM_SET_VALUE_NAME(element_hash.value, "element_hash");

	{
		// if element_hash == 0 { return nil }
		lb_emit_if(p, lb_emit_comp(p, Token_CmpEq, element_hash, zero_uintptr), nil_block, probe_block);
	}

	lb_start_block(p, probe_block);
	{
		// map_probe_distance inlined
		lbValue probe_distance = lb_emit_arith(p, Token_And, h, mask, t_uintptr);
		probe_distance = lb_emit_conv(p, probe_distance, t_uintptr);

		lbValue cap = lb_emit_conv(p, capacity, t_uintptr);
		lbValue base = lb_emit_arith(p, Token_Add, lb_addr_load(p, pos), cap, t_uintptr);
		probe_distance = lb_emit_arith(p, Token_Sub, base, probe_distance, t_uintptr);
		probe_distance = lb_emit_arith(p, Token_And, probe_distance, mask, t_uintptr);
		LLVM_SET_VALUE_NAME(probe_distance.value, "probe_distance");

		lbValue cond = lb_emit_comp(p, Token_Gt, lb_addr_load(p, distance), probe_distance);
		lb_emit_if(p, cond, nil_block, hash_compare_block);
	}

	lb_start_block(p, hash_compare_block);
	{
		lb_emit_if(p, lb_emit_comp(p, Token_CmpEq, element_hash, h), key_compare_block, increment_block);
	}

	lb_start_block(p, key_compare_block);
	{
		lbValue element_key = lb_map_cell_index_static(p, type->Map.key, ks, lb_addr_load(p, pos));
		element_key = lb_emit_conv(p, element_key, ks.type);

		LLVM_SET_VALUE_NAME(element_key.value, "element_key_ptr");
		lbValue cond = lb_emit_comp(p, Token_CmpEq, lb_emit_load(p, element_key), key);
		lb_emit_if(p, cond, value_block, increment_block);
	}

	lb_start_block(p, value_block);
	{
		lbValue element_value = lb_map_cell_index_static(p, type->Map.value, vs, lb_addr_load(p, pos));
		LLVM_SET_VALUE_NAME(element_value.value, "element_value_ptr");
		element_value = lb_emit_conv(p, element_value, t_rawptr);
		LLVMBuildRet(p->builder, element_value.value);
	}

	lb_start_block(p, increment_block);
	{
		lbValue pp = lb_addr_load(p, pos);
		pp = lb_emit_arith(p, Token_Add, pp, one_uintptr, t_uintptr);
		pp = lb_emit_arith(p, Token_And, pp, mask, t_uintptr);
		lb_addr_store(p, pos, pp);
		lb_emit_increment(p, distance.addr);
	}
	lb_emit_jump(p, loop_block);

	lb_start_block(p, nil_block);
	{
		lbValue res = lb_const_nil(m, t_rawptr);
		LLVMBuildRet(p->builder, res.value);
	}

	// gb_printf_err("%s\n", LLVMPrintValueToString(p->value));

	return {p->value, p->type};
}

// gb_internal void lb_debug_print(lbProcedure *p, String const &str) {
// 	auto args = array_make<lbValue>(heap_allocator(), 1);
// 	args[0] = lb_const_string(p->module, str);
// 	lb_emit_runtime_call(p, "print_string", args);
// }

gb_internal lbValue lb_map_set_proc_for_type(lbModule *m, Type *type) {
	TEMPORARY_ALLOCATOR_GUARD();

	GB_ASSERT(!build_context.dynamic_map_calls);
	type = base_type(type);
	GB_ASSERT(type->kind == Type_Map);

	String proc_name = lb_internal_gen_name_from_type("__$map_set", type);
	lbProcedure **found = string_map_get(&m->gen_procs, proc_name);
	if (found) {
		GB_ASSERT(*found != nullptr);
		return {(*found)->value, (*found)->type};
	}

	lbProcedure *p = lb_create_dummy_procedure(m, proc_name, t_map_set_proc);
	string_map_set(&m->gen_procs, proc_name, p);
	lb_begin_procedure_body(p);
	defer (lb_end_procedure_body(p));

	LLVMSetLinkage(p->value, LLVMInternalLinkage);
	lb_add_attribute_to_proc(m, p->value, "nounwind");
	if (build_context.ODIN_DEBUG) {
		lb_add_attribute_to_proc(m, p->value, "noinline");
	}

	lbValue map_ptr      = {LLVMGetParam(p->value, 0), t_rawptr};
	lbValue hash_param   = {LLVMGetParam(p->value, 1), t_uintptr};
	lbValue key_ptr      = {LLVMGetParam(p->value, 2), t_rawptr};
	lbValue value_ptr    = {LLVMGetParam(p->value, 3), t_rawptr};
	lbValue location_ptr = {LLVMGetParam(p->value, 4), t_source_code_location_ptr};

	map_ptr = lb_emit_conv(p, map_ptr, alloc_type_pointer(type));
	key_ptr = lb_emit_conv(p, key_ptr, alloc_type_pointer(type->Map.key));

	LLVM_SET_VALUE_NAME(map_ptr.value,      "map_ptr");
	LLVM_SET_VALUE_NAME(hash_param.value,   "hash_param");
	LLVM_SET_VALUE_NAME(key_ptr.value,      "key_ptr");
	LLVM_SET_VALUE_NAME(value_ptr.value,    "value_ptr");
	LLVM_SET_VALUE_NAME(location_ptr.value, "location");

	lb_add_proc_attribute_at_index(p, 1+0, "nonnull");
	lb_add_proc_attribute_at_index(p, 1+0, "noalias");

	lb_add_proc_attribute_at_index(p, 1+2, "nonnull");
	if (!are_types_identical(type->Map.key, type->Map.value)) {
		lb_add_proc_attribute_at_index(p, 1+2, "noalias");
	}
	lb_add_proc_attribute_at_index(p, 1+2, "readonly");

	lb_add_proc_attribute_at_index(p, 1+3, "nonnull");
	if (!are_types_identical(type->Map.key, type->Map.value)) {
		lb_add_proc_attribute_at_index(p, 1+3, "noalias");
	}
	lb_add_proc_attribute_at_index(p, 1+3, "readonly");

	lb_add_proc_attribute_at_index(p, 1+4, "nonnull");
	lb_add_proc_attribute_at_index(p, 1+4, "noalias");
	lb_add_proc_attribute_at_index(p, 1+4, "readonly");

	lbAddr hash_addr = lb_add_local_generated(p, t_uintptr, false);
	lb_addr_store(p, hash_addr, hash_param);
	LLVM_SET_VALUE_NAME(hash_addr.addr.value, "hash");

	////
	lbValue found_ptr = {};
	{
		lbValue map_get_proc = lb_map_get_proc_for_type(m, type);

		auto args = array_make<lbValue>(temporary_allocator(), 3);
		args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
		args[1] = lb_addr_load(p, hash_addr);
		args[2] = key_ptr;

		found_ptr = lb_emit_call(p, map_get_proc, args);
	}
	LLVM_SET_VALUE_NAME(found_ptr.value, "found_ptr");


	lbBlock *found_block      = lb_create_block(p, "found");
	lbBlock *check_grow_block = lb_create_block(p, "check-grow");
	lbBlock *grow_fail_block  = lb_create_block(p, "grow-fail");
	lbBlock *insert_block     = lb_create_block(p, "insert");
	lbBlock *check_has_grown_block = lb_create_block(p, "check-has-grown");
	lbBlock *rehash_block     = lb_create_block(p, "rehash");

	lb_emit_if(p, lb_emit_comp_against_nil(p, Token_NotEq, found_ptr), found_block, check_grow_block);
	lb_start_block(p, found_block);
	{
		lb_mem_copy_non_overlapping(p, found_ptr, value_ptr, lb_const_int(m, t_int, type_size_of(type->Map.value)));
		LLVMBuildRet(p->builder, lb_emit_conv(p, found_ptr, t_rawptr).value);
	}
	lb_start_block(p, check_grow_block);


	lbValue map_info = lb_gen_map_info_ptr(p->module, type);
	LLVM_SET_VALUE_NAME(map_info.value, "map_info");

	{
		auto args = array_make<lbValue>(temporary_allocator(), 3);
		args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
		args[1] = map_info;
		args[2] = lb_emit_load(p, location_ptr);
		lbValue grow_err_and_has_grown = lb_emit_runtime_call(p, "__dynamic_map_check_grow", args);
		lbValue grow_err = lb_emit_struct_ev(p, grow_err_and_has_grown, 0);
		lbValue has_grown = lb_emit_struct_ev(p, grow_err_and_has_grown, 1);
		LLVM_SET_VALUE_NAME(grow_err.value,  "grow_err");
		LLVM_SET_VALUE_NAME(has_grown.value, "has_grown");

		lb_emit_if(p, lb_emit_comp_against_nil(p, Token_NotEq, grow_err), grow_fail_block, check_has_grown_block);

		lb_start_block(p, grow_fail_block);
		LLVMBuildRet(p->builder, LLVMConstNull(lb_type(m, t_rawptr)));

		lb_start_block(p, check_has_grown_block);

		lb_emit_if(p, has_grown, rehash_block, insert_block);
		lb_start_block(p, rehash_block);
		lbValue key = lb_emit_load(p, key_ptr);
		lbValue new_hash = lb_gen_map_key_hash(p, map_ptr, key, nullptr);
		LLVM_SET_VALUE_NAME(new_hash.value, "new_hash");
		lb_addr_store(p, hash_addr, new_hash);
		lb_emit_jump(p, insert_block);
	}

	lb_start_block(p, insert_block);
	{
		auto args = array_make<lbValue>(temporary_allocator(), 5);
		args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
		args[1] = map_info;
		args[2] = lb_addr_load(p, hash_addr);
		args[3] = lb_emit_conv(p, key_ptr,   t_uintptr);
		args[4] = lb_emit_conv(p, value_ptr, t_uintptr);

		lbValue result = lb_emit_runtime_call(p, "map_insert_hash_dynamic", args);

		lb_emit_increment(p, lb_map_len_ptr(p, map_ptr));

		LLVMBuildRet(p->builder, lb_emit_conv(p, result, t_rawptr).value);
	}

	return {p->value, p->type};
}

gb_internal lbValue lb_gen_map_cell_info_ptr(lbModule *m, Type *type) {
	lbAddr *found = map_get(&m->map_cell_info_map, type);
	if (found) {
		return found->addr;
	}

	i64 size = 0, len = 0;
	map_cell_size_and_len(type, &size, &len);

	LLVMValueRef const_values[4] = {};
	const_values[0] = lb_const_int(m, t_uintptr, type_size_of(type)).value;
	const_values[1] = lb_const_int(m, t_uintptr, type_align_of(type)).value;
	const_values[2] = lb_const_int(m, t_uintptr, size).value;
	const_values[3] = lb_const_int(m, t_uintptr, len).value;
	LLVMValueRef llvm_res =  llvm_const_named_struct(m, t_map_cell_info, const_values, gb_count_of(const_values));
	lbValue res = {llvm_res, t_map_cell_info};

	lbAddr addr = lb_add_global_generated_with_name(m, t_map_cell_info, res, lb_internal_gen_name_from_type("ggv$map_cell_info", type));
	lb_make_global_private_const(addr);

	map_set(&m->map_cell_info_map, type, addr);

	return addr.addr;
}
gb_internal lbValue lb_gen_map_info_ptr(lbModule *m, Type *map_type) {
	map_type = base_type(map_type);
	GB_ASSERT(map_type->kind == Type_Map);

	lbAddr *found = map_get(&m->map_info_map, map_type);
	if (found) {
		return found->addr;
	}

	GB_ASSERT(t_map_info != nullptr);
	GB_ASSERT(t_map_cell_info != nullptr);

	LLVMValueRef key_cell_info   = lb_gen_map_cell_info_ptr(m, map_type->Map.key).value;
	LLVMValueRef value_cell_info = lb_gen_map_cell_info_ptr(m, map_type->Map.value).value;

	LLVMValueRef const_values[4] = {};
	const_values[0] = key_cell_info;
	const_values[1] = value_cell_info;
	const_values[2] = lb_hasher_proc_for_type(m, map_type->Map.key).value;
	const_values[3] = lb_equal_proc_for_type(m, map_type->Map.key).value;

	LLVMValueRef llvm_res = llvm_const_named_struct(m, t_map_info, const_values, gb_count_of(const_values));
	lbValue res = {llvm_res, t_map_info};

	lbAddr addr = lb_add_global_generated_with_name(m, t_map_info, res, lb_internal_gen_name_from_type("ggv$map_info", map_type));
	lb_make_global_private_const(addr);

	map_set(&m->map_info_map, map_type, addr);
	return addr.addr;
}

gb_internal lbValue lb_const_hash(lbModule *m, lbValue key, Type *key_type) {
	if (true) {
		return {};
	}

	lbValue hashed_key = {};

#if 0
	if (lb_is_const(key)) {
		u64 hash = 0xcbf29ce484222325;
		if (is_type_cstring(key_type)) {
			size_t length = 0;
			char const *text = LLVMGetAsString(key.value, &length);
			hash = fnv64a(text, cast(isize)length);
		} else if (is_type_string(key_type)) {
			unsigned data_indices[] = {0};
			unsigned len_indices[] = {1};
			LLVMValueRef data = LLVMConstExtractValue(key.value, data_indices, gb_count_of(data_indices));
			LLVMValueRef len  = LLVMConstExtractValue(key.value, len_indices,  gb_count_of(len_indices));
			i64 length = LLVMConstIntGetSExtValue(len);
			char const *text = nullptr;
			if (false && length != 0) {
			if (LLVMGetConstOpcode(data) != LLVMGetElementPtr) {
					return {};
				}
				// TODO(bill): THIS IS BROKEN! THIS NEEDS FIXING :P

				size_t ulength = 0;
				text = LLVMGetAsString(data, &ulength);
				gb_printf_err("%lld %llu %s\n", length, ulength, text);
				length = gb_min(length, cast(i64)ulength);
			}
			hash = fnv64a(text, cast(isize)length);
		} else {
			return {};
		}
		// TODO(bill): other const hash types

		if (build_context.word_size == 4) {
			hash &= 0xffffffffull;
		}
		hashed_key = lb_const_int(m, t_uintptr, hash);
	}
#endif
	return hashed_key;
}

gb_internal lbValue lb_gen_map_key_hash(lbProcedure *p, lbValue const &map_ptr, lbValue key, lbValue *key_ptr_) {
	TEMPORARY_ALLOCATOR_GUARD();

	Type* key_type = base_type(type_deref(map_ptr.type))->Map.key;

	lbValue real_key = lb_emit_conv(p, key, key_type);

	lbValue key_ptr = lb_address_from_load_or_generate_local(p, real_key);
	key_ptr = lb_emit_conv(p, key_ptr, t_rawptr);

	if (key_ptr_) *key_ptr_ = key_ptr;

	lbValue hashed_key = lb_const_hash(p->module, real_key, key_type);
	if (hashed_key.value == nullptr) {
		lbValue hasher = lb_hasher_proc_for_type(p->module, key_type);

		lbValue seed = {};
		{
			auto args = array_make<lbValue>(temporary_allocator(), 1);
			args[0] = lb_map_data_uintptr(p, lb_emit_load(p, map_ptr));
			seed = lb_emit_runtime_call(p, "map_seed_from_map_data", args);
		}

		auto args = array_make<lbValue>(temporary_allocator(), 2);
		args[0] = key_ptr;
		args[1] = seed;
		hashed_key = lb_emit_call(p, hasher, args);
	}

	return hashed_key;
}

gb_internal lbValue lb_internal_dynamic_map_get_ptr(lbProcedure *p, lbValue const &map_ptr, lbValue const &key) {
	TEMPORARY_ALLOCATOR_GUARD();

	Type *map_type = base_type(type_deref(map_ptr.type));
	GB_ASSERT(map_type->kind == Type_Map);

	lbValue ptr = {};
	lbValue key_ptr = {};
	lbValue hash = lb_gen_map_key_hash(p, map_ptr, key, &key_ptr);

	if (build_context.dynamic_map_calls) {
		auto args = array_make<lbValue>(temporary_allocator(), 4);
		args[0] = lb_emit_transmute(p, map_ptr, t_raw_map_ptr);
		args[1] = lb_gen_map_info_ptr(p->module, map_type);
		args[2] = hash;
		args[3] = key_ptr;

		ptr = lb_emit_runtime_call(p, "__dynamic_map_get", args);
	} else {
		lbValue map_get_proc = lb_map_get_proc_for_type(p->module, map_type);

		auto args = array_make<lbValue>(temporary_allocator(), 3);
		args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
		args[1] = hash;
		args[2] = key_ptr;

		ptr = lb_emit_call(p, map_get_proc, args);
	}
	return lb_emit_conv(p, ptr, alloc_type_pointer(map_type->Map.value));
}

gb_internal void lb_internal_dynamic_map_set(lbProcedure *p, lbValue const &map_ptr, Type *map_type,
                                             lbValue const &map_key, lbValue const &map_value, Ast *node) {
	TEMPORARY_ALLOCATOR_GUARD();

	map_type = base_type(map_type);
	GB_ASSERT(map_type->kind == Type_Map);

	lbValue key_ptr = {};
	lbValue hash = lb_gen_map_key_hash(p, map_ptr, map_key, &key_ptr);

	lbValue v = lb_emit_conv(p, map_value, map_type->Map.value);
	lbValue value_ptr = lb_address_from_load_or_generate_local(p, v);

	if (build_context.dynamic_map_calls) {
		auto args = array_make<lbValue>(temporary_allocator(), 6);
		args[0] = lb_emit_conv(p, map_ptr, t_raw_map_ptr);
		args[1] = lb_gen_map_info_ptr(p->module, map_type);
		args[2] = hash;
		args[3] = lb_emit_conv(p, key_ptr, t_rawptr);
		args[4] = lb_emit_conv(p, value_ptr, t_rawptr);
		args[5] = lb_emit_source_code_location_as_global(p, node);
		lb_emit_runtime_call(p, "__dynamic_map_set", args);
	} else {
		lbValue map_set_proc = lb_map_set_proc_for_type(p->module, map_type);

		auto args = array_make<lbValue>(temporary_allocator(), 5);
		args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
		args[1] = hash;
		args[2] = lb_emit_conv(p, key_ptr, t_rawptr);
		args[3] = lb_emit_conv(p, value_ptr, t_rawptr);
		args[4] = lb_emit_source_code_location_as_global(p, node);

		lb_emit_call(p, map_set_proc, args);
	}
}

gb_internal lbValue lb_dynamic_map_reserve(lbProcedure *p, lbValue const &map_ptr, isize const capacity, TokenPos const &pos) {
	TEMPORARY_ALLOCATOR_GUARD();

	String proc_name = {};
	if (p->entity) {
		proc_name = p->entity->token.string;
	}

	auto args = array_make<lbValue>(temporary_allocator(), 4);
	args[0] = lb_emit_conv(p, map_ptr, t_rawptr);
	args[1] = lb_gen_map_info_ptr(p->module, type_deref(map_ptr.type));
	args[2] = lb_const_int(p->module, t_uint, capacity);
	args[3] = lb_emit_source_code_location_as_global(p, proc_name, pos);
	return lb_emit_runtime_call(p, "__dynamic_map_reserve", args);
}

gb_internal lbProcedure *lb_create_objc_names(lbModule *main_module) {
	if (build_context.metrics.os != TargetOs_darwin) {
		return nullptr;
	}
	Type *proc_type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_CDecl);
	lbProcedure *p = lb_create_dummy_procedure(main_module, str_lit("__$init_objc_names"), proc_type);
	lb_add_attribute_to_proc(p->module, p->value, "nounwind");
	p->is_startup = true;
	return p;
}

String lb_get_objc_type_encoding(Type *t, isize pointer_depth = 0) {
	// NOTE(harold): See https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100

	// NOTE(harold): Darwin targets are always 64-bit. Should we drop this and assume "q" always?
	#define INT_SIZE_ENCODING (build_context.metrics.int_size == 4 ? "i" : "q")
	switch (t->kind) {
	case Type_Basic: {
		switch (t->Basic.kind) {
		case Basic_Invalid:
			return str_lit("?");

		case Basic_llvm_bool:
		case Basic_bool:
		case Basic_b8:
			return str_lit("B");

		case Basic_b16:
			return str_lit("C");
		case Basic_b32:
			return str_lit("I");
		case Basic_b64:
			return str_lit("q");
		case Basic_i8:
			return str_lit("c");
		case Basic_u8:
			return str_lit("C");
		case Basic_i16:
		case Basic_i16le:
		case Basic_i16be:
			return str_lit("s");
		case Basic_u16:
		case Basic_u16le:
		case Basic_u16be:
			return str_lit("S");
		case Basic_i32:
		case Basic_i32le:
		case Basic_i32be:
			return str_lit("i");
		case Basic_u32le:
		case Basic_u32:
		case Basic_u32be:
			return str_lit("I");
		case Basic_i64:
		case Basic_i64le:
		case Basic_i64be:
			return str_lit("q");
		case Basic_u64:
		case Basic_u64le:
		case Basic_u64be:
			return str_lit("Q");
		case Basic_i128:
		case Basic_i128le:
		case Basic_i128be:
			return str_lit("t");
		case Basic_u128:
		case Basic_u128le:
		case Basic_u128be:
			return str_lit("T");
		case Basic_rune:
			return str_lit("I");
		case Basic_f16:
		case Basic_f16le:
		case Basic_f16be:
			return str_lit("s");    // @harold: Closest we've got?
		case Basic_f32:
		case Basic_f32le:
		case Basic_f32be:
			return str_lit("f");
		case Basic_f64:
		case Basic_f64le:
		case Basic_f64be:
			return str_lit("d");

		case Basic_complex32:		return str_lit("{complex32=ss}");	// No f16 encoding, so fallback to i16, as above in Basic_f16*
		case Basic_complex64:		return str_lit("{complex64=ff}");
		case Basic_complex128:		return str_lit("{complex128=dd}");
		case Basic_quaternion64:    return str_lit("{quaternion64=ssss}");
		case Basic_quaternion128:   return str_lit("{quaternion128=ffff}");
		case Basic_quaternion256:   return str_lit("{quaternion256=dddd}");

		case Basic_int:
			return str_lit(INT_SIZE_ENCODING);
		case Basic_uint:
			return build_context.metrics.int_size == 4 ? str_lit("I") : str_lit("Q");
		case Basic_uintptr:
		case Basic_rawptr:
			return str_lit("^v");

		case Basic_string:
			return build_context.metrics.int_size == 4 ? str_lit("{string=*i}") : str_lit("{string=*q}");

		case Basic_string16:
			return build_context.metrics.int_size == 4 ? str_lit("{string16=*i}") : str_lit("{string16=*q}");

		case Basic_cstring: return str_lit("*");
		case Basic_cstring16: return str_lit("*");


		case Basic_any:     return str_lit("{any=^v^v}");  // rawptr + ^Type_Info

		case Basic_typeid:
			GB_ASSERT(t->Basic.size == 8);
			return str_lit("q");

		// Untyped types
		case Basic_UntypedBool:
		case Basic_UntypedInteger:
		case Basic_UntypedFloat:
		case Basic_UntypedComplex:
		case Basic_UntypedQuaternion:
		case Basic_UntypedString:
		case Basic_UntypedRune:
		case Basic_UntypedNil:
		case Basic_UntypedUninit:
			GB_PANIC("Untyped types cannot be @encoded()");
			return str_lit("?");
		}
		break;
	}

	case Type_Named:
	case Type_Struct:
	case Type_Union: {
		Type* base = t;
		if (base->kind == Type_Named) {
			base = base_type(base);
			if(base->kind != Type_Struct && base->kind != Type_Union) {
				return lb_get_objc_type_encoding(base, pointer_depth);
			}
		}

		const bool is_union = base->kind == Type_Union;
		if (!is_union) {
			// Treat struct as an Objective-C Class?
			if (has_type_got_objc_class_attribute(t) && pointer_depth == 0) {
				return str_lit("#");
			}
		}

		if (is_type_objc_object(base)) {
			return str_lit("@");
		}


		gbString s = gb_string_make_reserve(temporary_allocator(), 16);
		s = gb_string_append_length(s, is_union ? "(" :"{", 1);
		if (t->kind == Type_Named) {
			s = gb_string_append_length(s, t->Named.name.text, t->Named.name.len);
		}

		// Write fields
		if (pointer_depth < 2) {
			s = gb_string_append_length(s, "=", 1);

			if (!is_union) {
				for (auto &f : base->Struct.fields) {
					String field_type = lb_get_objc_type_encoding(f->type, pointer_depth);
					s = gb_string_append_length(s, field_type.text, field_type.len);
				}
			} else {
				for (auto &v : base->Union.variants) {
					String variant_type = lb_get_objc_type_encoding(v, pointer_depth);
					s = gb_string_append_length(s, variant_type.text, variant_type.len);
				}
			}
		}

		s = gb_string_append_length(s, is_union ? ")" :"}", 1);

		return make_string_c(s);
	}

	case Type_Generic:
		GB_PANIC("Generic types cannot be @encoded()");
		return str_lit("?");

	case Type_Pointer: {
		// NOTE: These types are pointers, so we must check here for special cases
		// Check for objc_SEL
		if (internal_check_is_assignable_to(t, t_objc_SEL)) {
			return str_lit(":");
		}

		// Check for objc_Class
		if (internal_check_is_assignable_to(t, t_objc_Class)) {
			return str_lit("#");
		}

		String pointee = lb_get_objc_type_encoding(t->Pointer.elem, pointer_depth +1);
		// Special case for Objective-C Objects
		if (pointer_depth == 0 && pointee == "@") {
			return pointee;
		}

		return concatenate_strings(temporary_allocator(), str_lit("^"), pointee);
	}

	case Type_MultiPointer:
		return concatenate_strings(temporary_allocator(), str_lit("^"), lb_get_objc_type_encoding(t->Pointer.elem, pointer_depth +1));

	case Type_Array: {
		String type_str = lb_get_objc_type_encoding(t->Array.elem, pointer_depth);

		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 8);
		s = gb_string_append_fmt(s, "[%lld%.*s]", t->Array.count, LIT(type_str));
		return make_string_c(s);
	}

	case Type_EnumeratedArray: {
		String type_str = lb_get_objc_type_encoding(t->EnumeratedArray.elem, pointer_depth);

		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 8);
		s = gb_string_append_fmt(s, "[%lld%.*s]", t->EnumeratedArray.count, LIT(type_str));
		return make_string_c(s);
	}

	case Type_Slice: {
		String type_str = lb_get_objc_type_encoding(t->Slice.elem, pointer_depth);
		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 8);
		s = gb_string_append_fmt(s, "{slice=^%.*s%s}", LIT(type_str), INT_SIZE_ENCODING);
		return make_string_c(s);
	}

	case Type_DynamicArray: {
		String type_str = lb_get_objc_type_encoding(t->DynamicArray.elem, pointer_depth);
		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 8);
		s = gb_string_append_fmt(s, "{dynamic=^%.*s%s%sAllocator={?^v}}", LIT(type_str), INT_SIZE_ENCODING, INT_SIZE_ENCODING);
		return make_string_c(s);
	}

	case Type_Map:
		return str_lit("{^v^v{Allocator=?^v}}");
	case Type_Enum:
		return lb_get_objc_type_encoding(t->Enum.base_type, pointer_depth);
	case Type_Tuple:
		// NOTE(harold): Is this type allowed here?
		return str_lit("?");
	case Type_Proc:
		return str_lit("?");
	case Type_BitSet: {
		Type *bitset_integer_type = t->BitSet.underlying;
		if (!bitset_integer_type) {
			switch (t->cached_size) {
				case 1:  bitset_integer_type = t_u8;   break;
				case 2:  bitset_integer_type = t_u16;  break;
				case 4:  bitset_integer_type = t_u32;  break;
				case 8:  bitset_integer_type = t_u64;  break;
				case 16: bitset_integer_type = t_u128; break;
			}
		}
		GB_ASSERT_MSG(bitset_integer_type, "Could not determine bit_set integer size for objc_type_encoding");

		return lb_get_objc_type_encoding(bitset_integer_type, pointer_depth);
	}

	case Type_SimdVector: {
		String type_str = lb_get_objc_type_encoding(t->SimdVector.elem, pointer_depth);
		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 5);
		gb_string_append_fmt(s, "[%lld%.*s]", t->SimdVector.count, LIT(type_str));
		return make_string_c(s);
	}

	case Type_Matrix: {
		String type_str = lb_get_objc_type_encoding(t->Matrix.elem, pointer_depth);
		gbString s = gb_string_make_reserve(temporary_allocator(), type_str.len + 5);
		i64 element_count = t->Matrix.column_count * t->Matrix.row_count;
		gb_string_append_fmt(s, "[%lld%.*s]", element_count, LIT(type_str));
		return make_string_c(s);
	}

	case Type_BitField:
		return lb_get_objc_type_encoding(t->BitField.backing_type, pointer_depth);
	case Type_SoaPointer: {
		gbString s = gb_string_make_reserve(temporary_allocator(), 8);
		s = gb_string_append_fmt(s, "{=^v%s}", INT_SIZE_ENCODING);
		return make_string_c(s);
	}

	} // End switch t->kind
	#undef INT_SIZE_ENCODING

	GB_PANIC("Unreachable");
	return str_lit("");
}

struct lbObjCGlobalClass {
	lbObjCGlobal g;
	union {
		lbValue      class_value;    // Local registered class value
		lbAddr       class_global;   // Global class pointer. Placeholder for class implementations which are registered in order of definition.
	};
};

gb_internal void lb_register_objc_thing(
	StringSet &handled,
	lbModule *m,
	Array<lbValue> &args,
	Array<lbObjCGlobalClass> &class_impls,
	StringMap<lbObjCGlobalClass> &class_map,
	lbProcedure *p,
	lbObjCGlobal const &g,
	char const *call
) {
	if (string_set_update(&handled, g.name)) {
		return;
	}

	lbAddr addr = {};
	lbValue *found = string_map_get(&m->members, g.global_name);
	if (found) {
		addr = lb_addr(*found);
	} else {
		lbValue v = {};
		LLVMTypeRef t = lb_type(m, g.type);
		v.value = LLVMAddGlobal(m->mod, t, g.global_name);
		v.type = alloc_type_pointer(g.type);
		addr = lb_addr(v);
		LLVMSetInitializer(v.value, LLVMConstNull(t));
	}

	// If this class requires an implementation, save it for registration below.
	if (g.class_impl_type != nullptr) {

		// Make sure the superclass has been initialized before us
		auto &tn = g.class_impl_type->Named.type_name->TypeName;
		Type *superclass = tn.objc_superclass;
		if (superclass != nullptr) {
			auto &superclass_global = string_map_must_get(&class_map, superclass->Named.type_name->TypeName.objc_class_name);
			lb_register_objc_thing(handled, m, args, class_impls, class_map, p, superclass_global.g, call);
			GB_ASSERT(superclass_global.class_global.addr.value);
		}

		lbObjCGlobalClass impl_global = {};
		impl_global.g            = g;
		impl_global.class_global = addr;

		array_add(&class_impls, impl_global);

		lbObjCGlobalClass* class_global = string_map_get(&class_map, g.name);
		if (class_global != nullptr) {
			class_global->class_global = addr;
		}
	}
	else {
		lbValue class_ptr  = {};
		lbValue class_name = lb_const_value(m, t_cstring, exact_value_string(g.name));

		args.count = 1;
		args[0] = class_name;
		class_ptr = lb_emit_runtime_call(p, call, args);

		lb_addr_store(p, addr, class_ptr);

		lbObjCGlobalClass* class_global = string_map_get(&class_map, g.name);
		if (class_global != nullptr) {
			class_global->class_value = class_ptr;
		}
	}
}

gb_internal void lb_finalize_objc_names(lbGenerator *gen, lbProcedure *p) {
	if (p == nullptr) {
		return;
	}
	lbModule *m = p->module;
	GB_ASSERT(m == &p->module->gen->default_module);

	TEMPORARY_ALLOCATOR_GUARD();

	StringSet handled = {};
	string_set_init(&handled);
	defer (string_set_destroy(&handled));

	auto args        = array_make<lbValue>(temporary_allocator(), 3, 8);
	auto class_impls = array_make<lbObjCGlobalClass>(temporary_allocator(), 0, 16);

	// Register all class implementations unconditionally, even if not statically referenced
	for (Entity *e = {}; mpsc_dequeue(&gen->info->objc_class_implementations, &e); /**/) {
		GB_ASSERT(e->kind == Entity_TypeName && e->TypeName.objc_is_implementation);
		lb_handle_objc_find_or_register_class(p, e->TypeName.objc_class_name, e->type);

		if (build_context.bedrock) {
			error(e->token, "Objective-C related things are not allowed with '-bedrock'");
		}
	}

	// Ensure classes that have been implicitly referenced through
	// the objc_superclass attribute have a global variable available for them.
	TypeSet class_set{};
	type_set_init(&class_set, gen->objc_classes.count+16);
	defer (type_set_destroy(&class_set));

	auto referenced_classes = array_make<lbObjCGlobal>(temporary_allocator());
	for (lbObjCGlobal g = {}; mpsc_dequeue(&gen->objc_classes, &g); /**/) {
		array_add(&referenced_classes, g);

		Type *cls = g.class_impl_type;
		while (cls) {
			if (type_set_update(&class_set, cls)) {
				break;
			}
			GB_ASSERT(cls->kind == Type_Named);

			cls = cls->Named.type_name->TypeName.objc_superclass;
		}
	}

	for (auto pair : class_set) {
		Entity *e = pair.type->Named.type_name;
		GB_ASSERT(e->kind == Entity_TypeName);
		auto &tn = e->TypeName;
		Type *class_impl = !tn.objc_is_implementation ? nullptr : pair.type;
		lb_handle_objc_find_or_register_class(p, tn.objc_class_name, class_impl);

		if (build_context.bedrock) {
			error(e->token, "Objective-C related things are not allowed with '-bedrock'");
		}
	}
	for (lbObjCGlobal g = {}; mpsc_dequeue(&gen->objc_classes, &g); /**/) {
		array_add(&referenced_classes, g);
	}

	// Add all class globals to a map so that we can look them up dynamically
	// in order to resolve out-of-order because classes that are being implemented
	// require their superclasses to be registered before them.
	StringMap<lbObjCGlobalClass> global_class_map{};
	string_map_init(&global_class_map, (usize)gen->objc_classes.count);
	defer (string_map_destroy(&global_class_map));

	for (lbObjCGlobal g : referenced_classes) {
		string_map_set(&global_class_map, g.name, lbObjCGlobalClass{g});
	}

	LLVMSetLinkage(p->value, LLVMInternalLinkage);
	lb_begin_procedure_body(p);

	// Register class globals, gathering classes that must be implemented
	for (auto &kv : global_class_map) {
		lb_register_objc_thing(handled, m, args, class_impls, global_class_map, p, kv.value.g, "objc_lookUpClass");
	}

	// Prefetch selectors for implemented methods so that they can also be registered.
	for (auto const &cd : class_impls) {
		auto &g = cd.g;
		Type *class_type = g.class_impl_type;

		Array<ObjcMethodData> *methods = map_get(&m->info->objc_method_implementations, class_type);
		if (!methods) {
			continue;
		}

		for (ObjcMethodData const &md : *methods) {
			lb_handle_objc_find_or_register_selector(p, md.ac.objc_selector);
		}
	}

	// Now we can register all referenced selectors
	for (lbObjCGlobal g = {}; mpsc_dequeue(&gen->objc_selectors, &g); /**/) {
		lb_register_objc_thing(handled, m, args, class_impls, global_class_map, p, g, "sel_registerName");
	}


	// Emit method wrapper implementations and registration
	auto wrapper_args     = array_make<Type *>(temporary_allocator(), 2, 8);
	auto get_context_args = array_make<lbValue>(temporary_allocator(), 1);


	PtrMap<Type *, lbObjCGlobal> ivar_map{};
	map_init(&ivar_map, gen->objc_ivars.count);

	for (lbObjCGlobal g = {}; mpsc_dequeue(&gen->objc_ivars, &g); /**/) {
		map_set(&ivar_map, g.class_impl_type, g);
	}

	for (auto const &cd : class_impls) {
		auto &g = cd.g;

		Type *class_type     = g.class_impl_type;
		Type *class_ptr_type = alloc_type_pointer(class_type);
		Entity *e = class_type->Named.type_name;
		GB_ASSERT(e->kind == Entity_TypeName);

		if (build_context.bedrock) {
			error(e->token, "Objective-C related things are not allowed with '-bedrock'");
		}

		// Begin class registration: create class pair and update global reference
		lbValue class_value = {};

		{
			lbValue superclass_value = lb_const_nil(m, t_objc_Class);

			auto &tn = e->TypeName;
			Type *superclass = tn.objc_superclass;

			if (superclass != nullptr) {
				auto &superclass_global = string_map_must_get(&global_class_map, superclass->Named.type_name->TypeName.objc_class_name);
				superclass_value = superclass_global.class_value;
			}

			args.count = 3;
			args[0] = superclass_value;
			args[1] = lb_const_value(m, t_cstring, exact_value_string(g.name));
			args[2] = lb_const_int(m, t_uint, 0);
			class_value = lb_emit_runtime_call(p, "objc_allocateClassPair", args);

			lbObjCGlobalClass &mapped_global = string_map_must_get(&global_class_map, tn.objc_class_name);
			lb_addr_store(p, mapped_global.class_global, class_value);

			mapped_global.class_value = class_value;
		}


		Type *ivar_type = class_type->Named.type_name->TypeName.objc_ivar;

		Entity *context_provider = class_type->Named.type_name->TypeName.objc_context_provider;
		Type *contex_provider_self_ptr_type = nullptr;
		Type *contex_provider_self_named_type = nullptr;
		bool is_context_provider_ivar = false;
		lbValue context_provider_proc_value{};

		if (context_provider) {
			context_provider_proc_value = lb_find_procedure_value_from_entity(m, context_provider);

			contex_provider_self_ptr_type = base_type(context_provider->type->Proc.params->Tuple.variables[0]->type);
			GB_ASSERT(contex_provider_self_ptr_type->kind == Type_Pointer);
			contex_provider_self_named_type = base_named_type(type_deref(contex_provider_self_ptr_type));

			is_context_provider_ivar = ivar_type != nullptr && internal_check_is_assignable_to(contex_provider_self_named_type, ivar_type);
		}

		Array<ObjcMethodData> *methods = map_get(&m->info->objc_method_implementations, class_type);
		if (!methods) {
			continue;
		}

		// Check if it has any class methods ahead of time so that we know to grab the meta_class
		lbValue meta_class_value = {};
		for (const ObjcMethodData &md : *methods) {
			if (!md.ac.objc_is_class_method) {
				continue;
			}

			// Get the meta_class
			args.count       = 1;
			args[0]          = class_value;
			meta_class_value = lb_emit_runtime_call(p, "object_getClass", args);

			break;
		}

		for (const ObjcMethodData &md : *methods) {
			GB_ASSERT(md.proc_entity->kind == Entity_Procedure);
			Type *method_type = md.proc_entity->type;

			String proc_name = make_string_c("__$objc_method::");
			proc_name = concatenate_strings(temporary_allocator(), proc_name, g.name);
			proc_name = concatenate_strings(temporary_allocator(), proc_name, str_lit("::"));
			proc_name = concatenate_strings(permanent_allocator(), proc_name, md.ac.objc_name);

			wrapper_args.count = 2;
			wrapper_args[0] = md.ac.objc_is_class_method ? t_objc_Class : class_ptr_type;
			wrapper_args[1] = t_objc_SEL;

			isize method_param_count  = method_type->Proc.param_count;
			isize method_param_offset = 0;

			if (!md.ac.objc_is_class_method) {
				GB_ASSERT(method_param_count >= 1);
				method_param_count -= 1;
				method_param_offset = 1;
			}

			for (isize i = 0; i < method_param_count; i++) {
				array_add(&wrapper_args, method_type->Proc.params->Tuple.variables[method_param_offset+i]->type);
			}

			Type *wrapper_args_tuple = alloc_type_tuple_from_field_types(wrapper_args.data, wrapper_args.count, false, true);
			Type *wrapper_results_tuple = nullptr;

			if (method_type->Proc.result_count > 0) {
				GB_ASSERT(method_type->Proc.result_count == 1);
				wrapper_results_tuple = alloc_type_tuple_from_field_types(&method_type->Proc.results->Tuple.variables[0]->type, 1, false, true);
			}

			Type *wrapper_proc_type = alloc_type_proc(nullptr, wrapper_args_tuple, wrapper_args_tuple->Tuple.variables.count,
														wrapper_results_tuple, method_type->Proc.result_count, false, ProcCC_CDecl);

			lbProcedure *wrapper_proc = lb_create_dummy_procedure(m, proc_name, wrapper_proc_type);

			lb_add_function_type_attributes(wrapper_proc->value, lb_get_function_type(m, wrapper_proc_type), ProcCC_CDecl);

			// Emit the wrapper
			// LLVMSetLinkage(wrapper_proc->value, LLVMInternalLinkage);
			LLVMSetDLLStorageClass(wrapper_proc->value, LLVMDLLExportStorageClass);
			lb_add_attribute_to_proc(wrapper_proc->module, wrapper_proc->value, "nounwind");

			lb_begin_procedure_body(wrapper_proc);
			{
				LLVMValueRef context_addr = nullptr;
				if (method_type->Proc.calling_convention == ProcCC_Odin) {
					GB_ASSERT(context_provider);

					// Emit the get odin context call
					get_context_args[0] = lbValue {
						wrapper_proc->raw_input_parameters[0],
						contex_provider_self_ptr_type,
					};

					if (is_context_provider_ivar) {
						// The context provider takes the ivar's type.
						// Emit an objc_ivar_get call and use that pointer for 'self' instead.
						lbValue real_self {
							wrapper_proc->raw_input_parameters[0],
							class_ptr_type
						};
						get_context_args[0] = lb_handle_objc_ivar_for_objc_object_pointer(wrapper_proc, real_self);
					}

					lbValue context = lb_emit_call(wrapper_proc, context_provider_proc_value, get_context_args);
					context_addr    = lb_address_from_load(wrapper_proc, context).value;//lb_address_from_load_or_generate_local(wrapper_proc, context));
					// context_addr = LLVMGetOperand(context.value, 0);
				}

				isize method_forward_arg_count = method_param_count + method_param_offset;
				isize method_forward_return_arg_offset = 0;
				auto raw_method_args = array_make<LLVMValueRef>(temporary_allocator(), 0, method_forward_arg_count+1);

				lbValue method_proc_value = lb_find_procedure_value_from_entity(m, md.proc_entity);
				lbFunctionType* ft = lb_get_function_type(m, method_type);
				bool has_return = false;
				lbArgKind return_kind = {};

				if (wrapper_results_tuple != nullptr) {
					has_return = true;
					return_kind = ft->ret.kind;

					if (return_kind == lbArg_Indirect) {
						method_forward_return_arg_offset = 1;
						array_add(&raw_method_args, wrapper_proc->return_ptr.addr.value);
					}
				}

				if (!md.ac.objc_is_class_method) {
					array_add(&raw_method_args, wrapper_proc->raw_input_parameters[method_forward_return_arg_offset]);
				}

				for (isize i = 0; i < method_param_count; i++) {
					array_add(&raw_method_args, wrapper_proc->raw_input_parameters[i+2+method_forward_return_arg_offset]);
				}

				if (method_type->Proc.calling_convention == ProcCC_Odin) {
					array_add(&raw_method_args, context_addr);
				}

				// Call real procedure for method from here, passing the parameters expected, if any.
				LLVMTypeRef fnp = lb_type_internal_for_procedures_raw(m, method_type);
				LLVMValueRef ret_val_raw = LLVMBuildCall2(wrapper_proc->builder, fnp, method_proc_value.value, raw_method_args.data, (unsigned)raw_method_args.count, "");

				if (has_return && return_kind != lbArg_Indirect) {
					LLVMBuildRet(wrapper_proc->builder, ret_val_raw);
				}
				else {
					LLVMBuildRetVoid(wrapper_proc->builder);
				}
			}
			lb_end_procedure_body(wrapper_proc);

			// Add the method to the class
			String method_encoding = str_lit("v");

			GB_ASSERT(method_type->Proc.result_count <= 1);
			if (method_type->Proc.result_count != 0) {
				method_encoding = lb_get_objc_type_encoding(method_type->Proc.results->Tuple.variables[0]->type);
			}

			if (!md.ac.objc_is_class_method) {
				method_encoding = concatenate_strings(temporary_allocator(), method_encoding, str_lit("@:"));
			} else {
				method_encoding = concatenate_strings(temporary_allocator(), method_encoding, str_lit("#:"));
			}

			for (isize i = 0; i < method_param_count; i++) {
				Type *param_type = method_type->Proc.params->Tuple.variables[i + method_param_offset]->type;
				String param_encoding = lb_get_objc_type_encoding(param_type);

				method_encoding = concatenate_strings(temporary_allocator(), method_encoding, param_encoding);
			}

			// Emit method registration
			lbAddr* sel_address = string_map_get(&m->objc_selectors, md.ac.objc_selector);
			GB_ASSERT(sel_address);
			lbValue selector_value = lb_addr_load(p, *sel_address);

			lbValue target_class = !md.ac.objc_is_class_method ? class_value : meta_class_value;

			args.count = 4;
			args[0] = target_class;   // Class
			args[1] = selector_value; // SEL
			args[2] = lbValue { wrapper_proc->value, wrapper_proc->type };
			args[3] = lb_const_value(m, t_cstring, exact_value_string(method_encoding));

			// TODO(harold): Emit check BOOL result and panic if false?
			lb_emit_runtime_call(p, "class_addMethod", args);

		} // End methods

		// Add ivar if we have one
		if (ivar_type != nullptr) {
			// Register a single ivar for this class
			Type *ivar_base = ivar_type->Named.base;

			// @note(harold): The alignment is supposed to be passed as log2(alignment): https://developer.apple.com/documentation/objectivec/class_addivar(_:_:_:_:_:)?language=objc
			const i64 size      = type_size_of(ivar_base);
			const i64 alignment = (i64)floor_log2((u64)type_align_of(ivar_base));

			// NOTE(harold): I've opted to not emit the type encoding for ivars in order to keep the data private.
			//               If there is desire in the future to emit the type encoding for introspection through the Obj-C runtime,
			//               then perhaps an option can be added for it then.
			// Should we pass the actual type encoding? Might not be ideal for obfuscation.
			String ivar_name  = str_lit("__$ivar");
			String ivar_types = str_lit("{= }");	//lb_get_objc_type_encoding(ivar_type);
			args.count = 5;
			args[0] = class_value;
			args[1] = lb_const_value(m, t_cstring, exact_value_string(ivar_name));
			args[2] = lb_const_value(m, t_uint, exact_value_u64((u64)size));
			args[3] = lb_const_value(m, t_u8, exact_value_u64((u64)alignment));
			args[4] = lb_const_value(m, t_cstring, exact_value_string(ivar_types));
			lb_emit_runtime_call(p, "class_addIvar", args);
		}

		// Complete the class registration
		args.count = 1;
		args[0] = class_value;
		lb_emit_runtime_call(p, "objc_registerClassPair", args);
	}

	// Register ivar offsets for any `objc_ivar_get` expressions emitted.
	for (auto const& kv : ivar_map) {
		lbObjCGlobal const& g = kv.value;
		lbAddr ivar_addr = {};
		lbValue *found = string_map_get(&m->members, g.global_name);

		if (found) {
			ivar_addr = lb_addr(*found);
			GB_ASSERT(ivar_addr.addr.type == t_int_ptr);
		} else {
			// Defined in an external package, define it now in the main package
			LLVMTypeRef t = lb_type(m, t_int);

			lbValue global = {};
			global.value = LLVMAddGlobal(m->mod, t, g.global_name);
			global.type  = t_int_ptr;

			LLVMSetInitializer(global.value, LLVMConstInt(t, 0, true));

			ivar_addr = lb_addr(global);
		}

		Entity *e = g.class_impl_type->Named.type_name;
		GB_ASSERT(e->kind == Entity_TypeName);

		String class_name = e->TypeName.objc_class_name;
		lbValue class_value = string_map_must_get(&global_class_map, class_name).class_value;

		args.count = 2;
		args[0] = class_value;
		args[1] = lb_const_value(m, t_cstring, exact_value_string(str_lit("__$ivar")));
		lbValue ivar = lb_emit_runtime_call(p, "class_getInstanceVariable", args);

		args.count = 1;
		args[0] = ivar;
		lbValue ivar_offset     = lb_emit_runtime_call(p, "ivar_getOffset", args);
		lbValue ivar_offset_int = lb_emit_conv(p, ivar_offset, t_int);

		lb_addr_store(p, ivar_addr, ivar_offset_int);

		if (build_context.bedrock) {
			error(e->token, "Objective-C related things are not allowed with '-bedrock'");
		}
	}

	lb_end_procedure_body(p);
}

gb_internal void lb_verify_function(lbModule *m, lbProcedure *p, bool dump_ll=false) {
	if (LLVM_IGNORE_VERIFICATION) {
		return;
	}

	if (!m->debug_builder && LLVMVerifyFunction(p->value, LLVMReturnStatusAction)) {
		char *llvm_error = nullptr;

		gb_printf_err("LLVM CODE GEN FAILED FOR PROCEDURE: %.*s\n", LIT(p->name));
		LLVMDumpValue(p->value);
		gb_printf_err("\n");
		if (dump_ll) {
			gb_printf_err("\n\n\n");
			String filepath_ll = lb_filepath_ll_for_module(m);
			if (LLVMPrintModuleToFile(m->mod, cast(char const *)filepath_ll.text, &llvm_error)) {
				gb_printf_err("LLVM Error: %s\n", llvm_error);
			}
		}
		LLVMVerifyFunction(p->value, LLVMPrintMessageAction);
		lb_record_worker_failure();
		return;
	}
}

gb_internal WORKER_TASK_PROC(lb_llvm_module_verification_worker_proc) {
	if (LLVM_IGNORE_VERIFICATION) {
		return 0;
	}

	char *llvm_error = nullptr;
	defer (LLVMDisposeMessage(llvm_error));
	lbModule *m = cast(lbModule *)data;

	if (LLVMVerifyModule(m->mod, LLVMReturnStatusAction, &llvm_error)) {
		gb_printf_err("LLVM Error in module %s:\n%s\n", m->module_name, llvm_error);
		if (build_context.keep_temp_files) {
			TIME_SECTION("LLVM Print Module to File");
			String filepath_ll = lb_filepath_ll_for_module(m);
			if (LLVMPrintModuleToFile(m->mod, cast(char const *)filepath_ll.text, &llvm_error)) {
				gb_printf_err("LLVM Error: %s\n", llvm_error);
				lb_record_worker_failure();
				return 1;
			}
		}
		lb_record_worker_failure();
		return 1;
	}
	return 0;
}

gb_internal bool lb_init_global_var(lbModule *m, lbProcedure *p, Entity *e, Ast *init_expr, lbGlobalVariable &var) {
	if (init_expr != nullptr)  {
		lbValue init = lb_build_expr(p, init_expr);
		if (init.value == nullptr) {
			LLVMTypeRef global_type = llvm_addr_type(p->module, var.var);
			if (is_type_untyped_nil(init.type)) {
				LLVMSetInitializer(var.var.value, LLVMConstNull(global_type));
				var.is_initialized = true;

				if (e->Variable.is_rodata) {
					LLVMSetGlobalConstant(var.var.value, true);
				}
				return true;
			}
			GB_PANIC("Invalid init value, got %s", expr_to_string(init_expr));
		}

		if (is_type_any(e->type)) {
			var.init = init;
		} else if (lb_is_const_or_global(init)) {
			if (!var.is_initialized) {
				if (is_type_proc(init.type)) {
					init.value = LLVMConstPointerCast(init.value, lb_type(p->module, init.type));
				}
				LLVMSetInitializer(var.var.value, init.value);
				var.is_initialized = true;

				if (e->Variable.is_rodata) {
					LLVMSetGlobalConstant(var.var.value, true);
				}
				return true;
			}
		} else {
			var.init = init;
		}
	}

	if (var.init.value != nullptr) {
		GB_ASSERT(!var.is_initialized);
		Type *t = type_deref(var.var.type);

		// NOTE: 'any' literals or 'any's that point to other variables can be handled by the generic path
		if (is_type_any(t) && !is_type_any(var.init.type) && init_expr->tav.mode != Addressing_Variable) {
			// NOTE(bill): Edge case for 'any' type
			Type *var_type = default_type(var.init.type);
			gbString var_name = gb_string_make(permanent_allocator(), "__$global_any::");
			gbString e_str = string_canonical_entity_name(temporary_allocator(), e);
			var_name = gb_string_append_length(var_name, e_str, gb_strlen(e_str));
			lbAddr g = lb_add_global_generated_with_name(m, var_type, {}, make_string_c(var_name));
			lb_addr_store(p, g, var.init);
			lbValue gp = lb_addr_get_ptr(p, g);

			lbValue data = lb_emit_struct_ep(p, var.var, 0);
			lbValue ti   = lb_emit_struct_ep(p, var.var, 1);
			lb_emit_store(p, data, lb_emit_conv(p, gp, t_rawptr));
			lb_emit_store(p, ti,   lb_typeid(p->module, var_type));
		} else {
			i64 sz = type_size_of(e->type);
			if (sz >= 4 * 1024) {
				warning(init_expr, "[Possible Code Generation Issue] Non-constant initialization is large (%lld bytes), and might cause problems with LLVM", cast(long long)sz);
			}

			LLVMTypeRef vt = llvm_addr_type(p->module, var.var);
			lbValue src0 = lb_emit_conv(p, var.init, t);
			LLVMValueRef src = OdinLLVMBuildTransmute(p, src0.value, vt);
			LLVMValueRef dst = var.var.value;
			LLVMBuildStore(p->builder, src, dst);
		}

		var.is_initialized = true;

		if (build_context.disable_non_constant_globals) {
			error(e->token, "Non-constant initialization of a global variable is disallowed with '-disable_non_constant_globals'");
		}
	}
	return false;
}


gb_internal void lb_create_startup_runtime_generate_body(lbModule *m, lbProcedure *p) {
	lb_begin_procedure_body(p);

	lb_setup_type_info_data(m);

	if (p->objc_names) {
		LLVMBuildCall2(p->builder, lb_type_internal_for_procedures_raw(m, p->objc_names->type), p->objc_names->value, nullptr, 0, "");
	}
	Type *dummy_type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_Odin);
	LLVMTypeRef raw_dummy_type = lb_type_internal_for_procedures_raw(m, dummy_type);

	for (auto &var : *p->global_variables) {
		if (var.is_initialized) {
			continue;
		}

		lbModule *entity_module = m;

		Entity *e = var.decl->entity;
		GB_ASSERT(e->kind == Entity_Variable);
		e->code_gen_module = entity_module;
		Ast *init_expr = var.decl->init_expr;

		if (init_expr == nullptr && var.init.value == nullptr) {
			continue;
		}

		if (false && type_size_of(e->type) > 8) {
			String ename = lb_get_entity_name(m, e);
			gbString name = gb_string_make(permanent_allocator(), "");
			name = gb_string_appendc(name, "__$startup$");
			name = gb_string_append_length(name, ename.text, ename.len);

			lbProcedure *dummy = lb_create_dummy_procedure(m, make_string_c(name), dummy_type);
			dummy->is_startup = true;
			LLVMSetVisibility(dummy->value, LLVMHiddenVisibility);
			LLVM_SET_INTERNAL_WEAK_LINKAGE(p->value);

			lb_begin_procedure_body(dummy);
			lb_init_global_var(m, dummy, e, init_expr, var);
			lb_end_procedure_body(dummy);

			LLVMValueRef context_ptr = lb_find_or_generate_context_ptr(p).addr.value;
			LLVMValueRef cast_ctx = LLVMBuildBitCast(p->builder, context_ptr, LLVMPointerType(LLVMInt8TypeInContext(m->ctx), 0), "");
			LLVMBuildCall2(p->builder, raw_dummy_type, dummy->value, &cast_ctx, 1, "");
		} else {
			lb_init_global_var(m, p, e, init_expr, var);
		}
	}
	CheckerInfo *info = m->gen->info;

	for (Entity *e : info->init_procedures) {
		lbValue value = lb_find_procedure_value_from_entity(m, e);
		lb_emit_call(p, value, {}, ProcInlining_none, ProcTailing_none);
	}


	lb_end_procedure_body(p);
}


gb_internal lbProcedure *lb_create_startup_runtime(lbModule *main_module, lbProcedure *objc_names, Array<lbGlobalVariable> &global_variables) { // Startup Runtime
	Type *proc_type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_Odin);

	lbProcedure *p = lb_create_dummy_procedure(main_module, str_lit(LB_STARTUP_RUNTIME_PROC_NAME), proc_type);
	p->is_startup = true;
	if (build_context.no_plt) {
		lb_add_attribute_to_proc(p->module, p->value, "nonlazybind");
	}
	lb_add_attribute_to_proc(p->module, p->value, "optnone");
	lb_add_attribute_to_proc(p->module, p->value, "noinline");

	// Make sure shared libraries call their own runtime startup on Linux.
	LLVMSetVisibility(p->value, LLVMHiddenVisibility);
	LLVM_SET_INTERNAL_WEAK_LINKAGE(p->value);

	p->global_variables = &global_variables;
	p->objc_names       = objc_names;

	lb_create_startup_runtime_generate_body(main_module, p);

	return p;
}

gb_internal lbProcedure *lb_create_cleanup_runtime(lbModule *main_module) { // Cleanup Runtime
	Type *proc_type = alloc_type_proc(nullptr, nullptr, 0, nullptr, 0, false, ProcCC_Odin);

	lbProcedure *p = lb_create_dummy_procedure(main_module, str_lit(LB_CLEANUP_RUNTIME_PROC_NAME), proc_type);
	p->is_startup = true;
	if (build_context.no_plt) {
		lb_add_attribute_to_proc(p->module, p->value, "nonlazybind");
	}
	lb_add_attribute_to_proc(p->module, p->value, "optnone");
	lb_add_attribute_to_proc(p->module, p->value, "noinline");

	// Make sure shared libraries call their own runtime cleanup on Linux.
	LLVMSetVisibility(p->value, LLVMHiddenVisibility);
	LLVM_SET_INTERNAL_WEAK_LINKAGE(p->value);

	lb_begin_procedure_body(p);

	CheckerInfo *info = main_module->gen->info;

	for (Entity *e : info->fini_procedures) {
		lbValue value = lb_find_procedure_value_from_entity(main_module, e);
		lb_emit_call(p, value, {}, ProcInlining_none, ProcTailing_none);
	}

	lb_end_procedure_body(p);

	lb_verify_function(main_module, p);
	return p;
}


gb_internal WORKER_TASK_PROC(lb_generate_procedures_and_types_per_module) {
	lbModule *m = cast(lbModule *)data;
	for (Entity *e : m->global_types_to_create) {
		(void)lb_get_entity_name(m, e);
		(void)lb_type(m, e->type);
	}

	for (Entity *e : m->global_procedures_to_create) {
		(void)lb_get_entity_name(m, e);
		mpsc_enqueue(&m->procedures_to_generate, lb_create_procedure(m, e));
	}
	return 0;
}

gb_internal GB_COMPARE_PROC(llvm_global_entity_cmp) {
	Entity *x = *cast(Entity **)a;
	Entity *y = *cast(Entity **)b;
	if (x == y) {
		return 0;
	}
	if (x->kind != y->kind) {
		return cast(i32)(x->kind - y->kind);
	}

	i32 cmp = 0;
	cmp = token_pos_cmp(x->token.pos, y->token.pos);
	if (!cmp) {
		return cmp;
	}
	return cmp;
}

gb_internal void lb_create_global_procedures_and_types(lbGenerator *gen, CheckerInfo *info, bool do_threading) {
	for (Entity *e : info->entities) {
		String  name  = e->token.string;
		Scope * scope = e->scope;

		if ((scope->flags & ScopeFlag_File) == 0) {
			continue;
		}

		Scope *package_scope = scope->parent;
		GB_ASSERT(package_scope->flags & ScopeFlag_Pkg);

		switch (e->kind) {
		case Entity_Variable:
			// NOTE(bill): Handled above as it requires a specific load order
			continue;
		case Entity_ProcGroup:
			continue;

		case Entity_TypeName:
		case Entity_Procedure:
			break;
		case Entity_Constant:
			if (build_context.ODIN_DEBUG) {
				lb_add_debug_info_for_global_constant_from_entity(gen, e);
			}
			break;
		}

		bool polymorphic_struct = false;
		if (e->type != nullptr && e->kind == Entity_TypeName) {
			Type *bt = base_type(e->type);
			if (bt->kind == Type_Struct) {
				polymorphic_struct = is_type_polymorphic(bt);
			}
		}

		if (!polymorphic_struct && e->min_dep_count.load(std::memory_order_relaxed) == 0) {
			// NOTE(bill): Nothing depends upon it so doesn't need to be built
			continue;
		}

		// if (!polymorphic_struct && !ptr_set_exists(min_dep_set, e)) {
		// 	// NOTE(bill): Nothing depends upon it so doesn't need to be built
		// 	continue;
		// }

		lbModule *m = &gen->default_module;
		if (USE_SEPARATE_MODULES) {
			m = lb_module_of_entity(gen, e, m);
		}
		GB_ASSERT(m != nullptr);

		if (e->kind == Entity_Procedure) {
			if (e->Procedure.is_foreign && e->Procedure.is_objc_impl_or_import) {
				// Do not generate declarations for foreign Objective-C methods. These are called indirectly through the Objective-C runtime.
				continue;
			}

			array_add(&m->global_procedures_to_create, e);
		} else if (e->kind == Entity_TypeName) {
			array_add(&m->global_types_to_create, e);
		}
	}

	for (auto const &entry : gen->modules) {
		lbModule *m = entry.value;
		array_sort(m->global_types_to_create, llvm_global_entity_cmp);
		array_sort(m->global_procedures_to_create, llvm_global_entity_cmp);
	}

	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			thread_pool_add_task(lb_generate_procedures_and_types_per_module, m);
		}
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			lb_generate_procedures_and_types_per_module(m);
		}

	}

	thread_pool_wait();
}

gb_internal void lb_generate_procedure(lbModule *m, lbProcedure *p);


gb_internal bool lb_is_module_empty(lbModule *m) {
	if (LLVMGetFirstFunction(m->mod) == nullptr &&
	    LLVMGetFirstGlobal(m->mod) == nullptr) {
		return true;
	}
	for (auto fn = LLVMGetFirstFunction(m->mod); fn != nullptr; fn = LLVMGetNextFunction(fn)) {
		if (LLVMGetFirstBasicBlock(fn) != nullptr) {
			return false;
		}
	}

	for (auto g = LLVMGetFirstGlobal(m->mod); g != nullptr; g = LLVMGetNextGlobal(g)) {
		LLVMLinkage linkage = LLVMGetLinkage(g);
		if (linkage == LLVMExternalLinkage ||
		    linkage == LLVMWeakAnyLinkage) {
			continue;
		}
		if (!LLVMIsExternallyInitialized(g)) {
			return false;
		}
	}
	return true;
}

struct lbLLVMEmitWorker {
	LLVMTargetMachineRef target_machine;
	LLVMCodeGenFileType code_gen_file_type;
	String filepath_obj;
	lbModule *m;
};

gb_internal WORKER_TASK_PROC(lb_llvm_emit_worker_proc) {
	GB_ASSERT(MULTITHREAD_OBJECT_GENERATION);

	char *llvm_error = nullptr;

	auto wd = cast(lbLLVMEmitWorker *)data;

	if (build_context.lto_kind != LTO_None) {
		if (LLVMWriteBitcodeToFile(wd->m->mod, cast(char *)wd->filepath_obj.text)) {
			gb_printf_err("Failed to write bitcode file: %.*s\n", LIT(wd->filepath_obj));
			lb_record_worker_failure();
			return 1;
		}
	} else if (LLVMTargetMachineEmitToFile(wd->target_machine, wd->m->mod, cast(char *)wd->filepath_obj.text, wd->code_gen_file_type, &llvm_error)) {
		gb_printf_err("LLVM Error: %s\n", llvm_error);
		lb_record_worker_failure();
		return 1;
	}
	debugf("Generated File: %.*s\n", LIT(wd->filepath_obj));
	return 0;
}


gb_internal void lb_llvm_function_pass_per_function_internal(lbModule *module, lbProcedure *p, lbFunctionPassManagerKind pass_manager_kind = lbFunctionPassManager_default) {
	LLVMPassManagerRef pass_manager = module->function_pass_managers[pass_manager_kind];
	lb_run_function_pass_manager(pass_manager, p, pass_manager_kind);
}

gb_internal WORKER_TASK_PROC(lb_llvm_function_pass_per_module) {
	lbModule *m = cast(lbModule *)data;
	{
		GB_ASSERT(m->function_pass_managers[lbFunctionPassManager_default] == nullptr);

		for (i32 i = 0; i < lbFunctionPassManager_COUNT; i++) {
			m->function_pass_managers[i] = LLVMCreateFunctionPassManagerForModule(m->mod);
		}

		for (i32 i = 0; i < lbFunctionPassManager_COUNT; i++) {
			LLVMInitializeFunctionPassManager(m->function_pass_managers[i]);
		}

		for (i32 i = 0; i < lbFunctionPassManager_COUNT; i++) {
			LLVMFinalizeFunctionPassManager(m->function_pass_managers[i]);
		}
	}

	if (m == &m->gen->default_module) {
		lb_llvm_function_pass_per_function_internal(m, m->gen->startup_runtime);
		lb_llvm_function_pass_per_function_internal(m, m->gen->cleanup_runtime);
		lb_llvm_function_pass_per_function_internal(m, m->gen->objc_names);
	}

	MUTEX_GUARD_BLOCK(&m->generated_procedures_mutex) for (lbProcedure *p : m->generated_procedures) {
		if (p->body != nullptr) { // Build Procedure
			lbFunctionPassManagerKind pass_manager_kind = lbFunctionPassManager_default;
			if (p->flags & lbProcedureFlag_WithoutMemcpyPass) {
				pass_manager_kind = lbFunctionPassManager_default_without_memcpy;
				lb_remove_attribute_from_proc(p->module, p->value, "optsize"); // incompatible with optnone
				lb_add_attribute_to_proc(p->module, p->value, "optnone");
				lb_add_attribute_to_proc(p->module, p->value, "noinline");
			} else {
				if (p->entity && p->entity->kind == Entity_Procedure) {
					switch (p->entity->Procedure.optimization_mode) {
					case ProcedureOptimizationMode_None:
						pass_manager_kind = lbFunctionPassManager_none;
						GB_ASSERT(lb_proc_has_attribute(p->module, p->value, "optnone"));
						GB_ASSERT(lb_proc_has_attribute(p->module, p->value, "noinline"));
						break;
					case ProcedureOptimizationMode_FavorSize:
						GB_ASSERT(lb_proc_has_attribute(p->module, p->value, "optsize"));
						break;
					}
				}
			}

			lb_llvm_function_pass_per_function_internal(m, p, pass_manager_kind);
		}
	}

	for (auto const &entry : m->gen_procs) {
		lbProcedure *p = entry.value;
		if (string_starts_with(p->name, str_lit("__$map"))) {
			lb_llvm_function_pass_per_function_internal(m, p, lbFunctionPassManager_none);
		} else {
			lb_llvm_function_pass_per_function_internal(m, p);
		}
	}

	return 0;
}


void lb_remove_unused_functions_and_globals(lbGenerator *gen) {
	for (auto &entry : gen->modules) {
		lbModule *m = entry.value;
		lb_run_remove_unused_function_pass(m);
		lb_run_remove_unused_globals_pass(m);
	}
}

struct lbLLVMModulePassWorkerData {
	lbModule *m;
	LLVMTargetMachineRef target_machine;
	bool do_threading;
};

gb_internal WORKER_TASK_PROC(lb_llvm_module_pass_worker_proc) {
	auto wd = cast(lbLLVMModulePassWorkerData *)data;

	LLVMPassManagerRef module_pass_manager = LLVMCreatePassManager();
	LLVMRunPassManager(module_pass_manager, wd->m->mod);

	auto passes = array_make<char const *>(heap_allocator(), 0, 64);
	defer (array_free(&passes));

	LLVMPassBuilderOptionsRef pb_options = LLVMCreatePassBuilderOptions();
	defer (LLVMDisposePassBuilderOptions(pb_options));

	#include "llvm_backend_passes.cpp"

	// asan - Linux, Darwin, Windows
	// msan - linux
	// tsan - Linux, Darwin
	// ubsan - Linux, Darwin, Windows (NOT SUPPORTED WITH LLVM C-API)

	// With LTO, sanitizer passes run at link time (via -fsanitize= linker flags)
	// where the linker has whole-program visibility. Running them here too would
	// double-instrument every module, producing "Redundant instrumentation" warnings.
	// Per-function sanitize attributes in the bitcode are preserved and respected
	// by the linker's sanitizer pass.
	if (build_context.lto_kind == LTO_None) {
		if (build_context.sanitizer_flags & SanitizerFlag_Address) {
			array_add(&passes, "asan");
		}
		if (build_context.sanitizer_flags & SanitizerFlag_Memory) {
			array_add(&passes, "msan");
		}
		if (build_context.sanitizer_flags & SanitizerFlag_Thread) {
			array_add(&passes, "tsan");
		}
	}

	if (passes.count == 0) {
		array_add(&passes, "verify");
	}

	gbString passes_str = gb_string_make_reserve(heap_allocator(), 1024);
	defer (gb_string_free(passes_str));
	for_array(i, passes) {
		if (i != 0) {
			passes_str = gb_string_appendc(passes_str, ",");
		}
		passes_str = gb_string_appendc(passes_str, passes[i]);
	}
	for (isize i = 0; i < gb_string_length(passes_str); /**/) {
		switch (passes_str[i]) {
		case ' ':
		case '\n':
		case '\t':
			gb_memmove(&passes_str[i], &passes_str[i+1], gb_string_length(passes_str)-i);
			GB_STRING_HEADER(passes_str)->length -= 1;
			continue;
		default:
			i += 1;
			break;
		}
	}

	LLVMErrorRef llvm_err = LLVMRunPasses(wd->m->mod, passes_str, wd->target_machine, pb_options);

	defer (LLVMConsumeError(llvm_err));
	if (llvm_err != nullptr) {
		char *llvm_error = LLVMGetErrorMessage(llvm_err);
		gb_printf_err("LLVM Error:\n%s\n", llvm_error);
		LLVMDisposeErrorMessage(llvm_error);
		llvm_error = nullptr;

		if (build_context.keep_temp_files) {
			TIME_SECTION("LLVM Print Module to File");
			String filepath_ll = lb_filepath_ll_for_module(wd->m);
			if (LLVMPrintModuleToFile(wd->m->mod, cast(char const *)filepath_ll.text, &llvm_error)) {
				gb_printf_err("LLVM Error: %s\n", llvm_error);
			}
		}
		lb_record_worker_failure();
		return 1;
	}

	if (LLVM_IGNORE_VERIFICATION) {
		return 0;
	}

	if (wd->do_threading) {
		thread_pool_add_task(lb_llvm_module_verification_worker_proc, wd->m);
	} else {
		lb_llvm_module_verification_worker_proc(wd->m);
	}

	return 0;
}



gb_internal WORKER_TASK_PROC(lb_generate_procedures_worker_proc) {
	lbModule *m = cast(lbModule *)data;
	for (lbProcedure *p = nullptr; mpsc_dequeue(&m->procedures_to_generate, &p); /**/) {
		lb_generate_procedure(p->module, p);
	}
	return 0;
}

gb_internal void lb_generate_procedures(lbGenerator *gen, bool do_threading) {
	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			thread_pool_add_task(lb_generate_procedures_worker_proc, m);
		}

		thread_pool_wait();
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			lb_generate_procedures_worker_proc(m);
		}
	}

	lb_exit_if_worker_failed();
}

gb_internal WORKER_TASK_PROC(lb_generate_missing_procedures_to_check_worker_proc) {
	lbModule *m = cast(lbModule *)data;
	for (lbProcedure *p = nullptr; mpsc_dequeue(&m->missing_procedures_to_check, &p); /**/) {
		if (!p->is_done.load(std::memory_order_relaxed)) {
			debugf("Generate missing procedure: %.*s module %p\n", LIT(p->name), m);
			lb_generate_procedure(m, p);
		}

		for (lbProcedure *nested = nullptr; mpsc_dequeue(&m->procedures_to_generate, &nested); /**/) {
			mpsc_enqueue(&m->missing_procedures_to_check, nested);
		}
	}
	return 0;
}

gb_internal void lb_generate_missing_procedures(lbGenerator *gen, bool do_threading) {
	isize retry_count = 0;
retry:;
	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			// NOTE(bill): procedures may be added during generation
			thread_pool_add_task(lb_generate_missing_procedures_to_check_worker_proc, m);
		}
		thread_pool_wait();
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			// NOTE(bill): procedures may be added during generation
			lb_generate_missing_procedures_to_check_worker_proc(m);
		}
	}

	for (auto const &entry : gen->modules) {
		lbModule *m = entry.value;
		if (m->missing_procedures_to_check.count != 0) {
			if (retry_count > gen->modules.count) {
				GB_ASSERT(m->missing_procedures_to_check.count == 0);
			}

			retry_count += 1;
			goto retry;
		}
		GB_ASSERT(m->missing_procedures_to_check.count == 0);
		GB_ASSERT(m->procedures_to_generate.count == 0);
	}
}

gb_internal void lb_debug_info_complete_types_and_finalize(lbGenerator *gen) {
	for (auto const &entry : gen->modules) {
		lbModule *m = entry.value;
		if (m->debug_builder != nullptr) {
			LLVMDIBuilderFinalize(m->debug_builder);
		}
	}
}

gb_internal void lb_llvm_function_passes(lbGenerator *gen, bool do_threading) {
	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			thread_pool_add_task(lb_llvm_function_pass_per_module, m);
		}
		thread_pool_wait();
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			lb_llvm_function_pass_per_module(m);
		}
	}

	lb_exit_if_worker_failed();
}


gb_internal void lb_llvm_module_passes_and_verification(lbGenerator *gen, bool do_threading) {
	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			auto wd = permanent_alloc_item<lbLLVMModulePassWorkerData>();
			wd->m = m;
			wd->target_machine = m->target_machine;
			wd->do_threading = true;

			thread_pool_add_task(lb_llvm_module_pass_worker_proc, wd);
		}
		thread_pool_wait();
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			auto wd = permanent_alloc_item<lbLLVMModulePassWorkerData>();
			wd->m = m;
			wd->target_machine = m->target_machine;
			wd->do_threading = false;
			lb_llvm_module_pass_worker_proc(wd);
		}
	}

	lb_exit_if_worker_failed();
}

gb_internal String lb_filepath_ll_for_module(lbModule *m) {
	String path = concatenate_strings(permanent_allocator(),
		build_context.build_paths[BuildPath_Output].basename,
		STR_LIT("/")
	);

	GB_ASSERT(m->module_name != nullptr);
	String s = make_string_c(m->module_name);
	String prefix = str_lit("odin_package-");
	if (string_starts_with(s, prefix)) {
		s.text += prefix.len;
		s.len  -= prefix.len;
	}

	if (build_context.out_filepath.len > 0) {
		path = concatenate_strings(permanent_allocator(), path, s);
		path = concatenate_strings(permanent_allocator(), path, STR_LIT(".ll"));
	} else {
		path = concatenate_strings(permanent_allocator(), s, STR_LIT(".ll"));
	}
	return path;
}

gb_internal String lb_filepath_obj_for_module(lbModule *m) {
	String basename = build_context.build_paths[BuildPath_Output].basename;
	String name = build_context.build_paths[BuildPath_Output].name;

	bool use_temporary_directory = false;
	if (USE_SEPARATE_MODULES && build_context.build_mode == BuildMode_Executable) {
		// NOTE(bill): use a temporary directory
		String dir = temporary_directory(permanent_allocator());
		if (dir.len != 0) {
			basename = dir;
			use_temporary_directory = true;
		}
	}

	gbString path = gb_string_make_length(heap_allocator(), basename.text, basename.len);
	path = gb_string_appendc(path, "/");

	bool output_is_directory = path_is_directory(build_context.build_paths[BuildPath_Output]);

	if (USE_SEPARATE_MODULES) {
		GB_ASSERT(m->module_name != nullptr);
		String s = make_string_c(m->module_name);
		String prefix = str_lit("odin_package");
		if (string_starts_with(s, prefix)) {
			s.text += prefix.len;
			s.len  -= prefix.len;
		}

		path = gb_string_append_length(path, s.text, s.len);
	} else {
		path = gb_string_append_length(path, name.text, name.len);
	}

	if (use_temporary_directory) {
		// NOTE(bill): this must be suffixed to ensure it is not conflicting with anything else in the temporary directory
		path = gb_string_append_fmt(path, "-%p", m);
	}

	String ext = {};

	if (build_context.lto_kind != LTO_None) {
		ext = STR_LIT("bc");
	} else if (build_context.build_mode == BuildMode_Assembly) {
		// Allow a user override for the asm extension.
		// If that's a directory, we force the `.S` extension
		ext = output_is_directory ? STR_LIT("S") : build_context.build_paths[BuildPath_Output].ext;
	} else if (build_context.build_mode == BuildMode_Object) {
		// Allow a user override for the object extension.
		// If that's a directory, we force the `.obj` extension
		ext = output_is_directory ? STR_LIT("obj") : build_context.build_paths[BuildPath_Output].ext;

	} else {
		ext = infer_object_extension_from_build_context();
	}

	path = gb_string_append_length(path, ".", 1);
	path = gb_string_append_length(path, ext.text, ext.len);

	return make_string(cast(u8 *)path, gb_string_length(path));

}

gb_internal void lb_add_foreign_library_paths(lbGenerator *gen) {
	for (auto const &entry : gen->modules) {
		lbModule *m = entry.value;
		for (Entity *e : m->info->required_foreign_imports_through_force) {
			lb_add_foreign_library_path(m, e);
		}

		if (lb_is_module_empty(m)) {
			continue;
		}
	}
}

gb_internal bool lb_llvm_object_generation(lbGenerator *gen, bool do_threading) {
	LLVMCodeGenFileType code_gen_file_type = LLVMObjectFile;
	if (build_context.build_mode == BuildMode_Assembly) {
		code_gen_file_type = LLVMAssemblyFile;
	}

	char *llvm_error = nullptr;
	defer (LLVMDisposeMessage(llvm_error));

	if (do_threading) {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			if (lb_is_module_empty(m)) {
				continue;
			}

			String filepath_ll = lb_filepath_ll_for_module(m);
			String filepath_obj = lb_filepath_obj_for_module(m);
			array_add(&gen->output_object_paths, filepath_obj);
			array_add(&gen->output_temp_paths, filepath_ll);

			auto *wd = permanent_alloc_item<lbLLVMEmitWorker>();
			wd->target_machine = m->target_machine;
			wd->code_gen_file_type = code_gen_file_type;
			wd->filepath_obj = filepath_obj;
			wd->m = m;
			thread_pool_add_task(lb_llvm_emit_worker_proc, wd);
		}

		thread_pool_wait(&global_thread_pool);
		lb_exit_if_worker_failed();
	} else {
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			if (lb_is_module_empty(m)) {
				continue;
			}

			String filepath_obj = lb_filepath_obj_for_module(m);
			array_add(&gen->output_object_paths, filepath_obj);

			String short_name = remove_directory_from_path(filepath_obj);
			gbString section_name = gb_string_make(permanent_allocator(), "LLVM Generate Object: ");
			section_name = gb_string_append_length(section_name, short_name.text, short_name.len);

			TIME_SECTION_WITH_LEN(section_name, gb_string_length(section_name));

			if (build_context.lto_kind != LTO_None) {
				if (LLVMWriteBitcodeToFile(m->mod, cast(char *)filepath_obj.text)) {
					gb_printf_err("Failed to write bitcode file: %.*s\n", LIT(filepath_obj));
					exit_with_errors();
					return false;
				}
			} else if (LLVMTargetMachineEmitToFile(m->target_machine, m->mod, cast(char *)filepath_obj.text, code_gen_file_type, &llvm_error)) {
				gb_printf_err("LLVM Error: %s\n", llvm_error);
				exit_with_errors();
				return false;
			}
			debugf("Generated File: %.*s\n", LIT(filepath_obj));
		}
	}
	return true;
}



gb_internal lbProcedure *lb_create_main_procedure(lbModule *m, lbProcedure *startup_runtime, lbProcedure *cleanup_runtime) {
	LLVMPassManagerRef default_function_pass_manager = LLVMCreateFunctionPassManagerForModule(m->mod);
	LLVMFinalizeFunctionPassManager(default_function_pass_manager);

	Type *params  = alloc_type_tuple();
	Type *results = alloc_type_tuple();

	Type *t_ptr_cstring = alloc_type_pointer(t_cstring);

	bool call_cleanup = true;

	bool has_args = false;
	bool is_dll_main = false;
	String name = str_lit("main");
	if (build_context.metrics.os == TargetOs_windows && build_context.build_mode == BuildMode_DynamicLibrary) {
		is_dll_main = true;
		name = str_lit("DllMain");
		slice_init(&params->Tuple.variables, permanent_allocator(), 3);
		params->Tuple.variables[0] = alloc_entity_param(nullptr, make_token_ident("hinstDLL"),   t_rawptr, false, true);
		params->Tuple.variables[1] = alloc_entity_param(nullptr, make_token_ident("fdwReason"),  t_u32,    false, true);
		params->Tuple.variables[2] = alloc_entity_param(nullptr, make_token_ident("lpReserved"), t_rawptr, false, true);
		call_cleanup = false;
	} else if (build_context.metrics.os == TargetOs_windows && build_context.no_crt) {
		name = str_lit("mainCRTStartup");
	} else if (build_context.metrics.os == TargetOs_windows && build_context.metrics.arch == TargetArch_i386 && !build_context.no_crt) {
		// Windows i386 with CRT: libcmt expects _main (main with underscore prefix)
		name = str_lit("main");
		has_args = true;
		slice_init(&params->Tuple.variables, permanent_allocator(), 2);
		params->Tuple.variables[0] = alloc_entity_param(nullptr, make_token_ident("argc"), t_i32, false, true);
		params->Tuple.variables[1] = alloc_entity_param(nullptr, make_token_ident("argv"), t_ptr_cstring, false, true);
	} else if (is_arch_wasm()) {
		name = str_lit("_start");
		call_cleanup = false;
	} else {
		has_args = true;
		slice_init(&params->Tuple.variables, permanent_allocator(), 2);
		params->Tuple.variables[0] = alloc_entity_param(nullptr, make_token_ident("argc"), t_i32, false, true);
		params->Tuple.variables[1] = alloc_entity_param(nullptr, make_token_ident("argv"), t_ptr_cstring, false, true);
	}

	slice_init(&results->Tuple.variables, permanent_allocator(), 1);
	results->Tuple.variables[0] = alloc_entity_param(nullptr, blank_token, t_i32, false, true);

	Type *proc_type = alloc_type_proc(nullptr,
		params, params->Tuple.variables.count,
		results, results->Tuple.variables.count, false, ProcCC_CDecl);


	lbProcedure *p = lb_create_dummy_procedure(m, name, proc_type);
	p->is_startup = true;

	lb_begin_procedure_body(p);

	if (has_args) { // initialize `runtime.args__`
		lbValue argc = {LLVMGetParam(p->value, 0), t_i32};
		lbValue argv = {LLVMGetParam(p->value, 1), t_ptr_cstring};
		LLVMSetValueName2(argc.value, "argc", 4);
		LLVMSetValueName2(argv.value, "argv", 4);
		argc = lb_emit_conv(p, argc, t_int);
		lbAddr args = lb_addr(lb_find_runtime_value(p->module, str_lit("args__")));
		lb_fill_slice(p, args, argv, argc);
	}

	lbValue startup_runtime_value = {startup_runtime->value, startup_runtime->type};
	lb_emit_call(p, startup_runtime_value, {}, ProcInlining_none, ProcTailing_none);

	if (build_context.command_kind == Command_test) {
		Type *t_Internal_Test = find_type_in_pkg(m->info, str_lit("testing"), str_lit("Internal_Test"));
		Type *array_type = alloc_type_array(t_Internal_Test, m->info->testing_procedures.count);
		Type *slice_type = alloc_type_slice(t_Internal_Test);
		lbAddr all_tests_array_addr = lb_add_global_generated_with_name(p->module, array_type, {}, str_lit("__$all_tests_array"));
		lbValue all_tests_array = lb_addr_get_ptr(p, all_tests_array_addr);

		LLVMValueRef indices[2] = {};
		indices[0] = LLVMConstInt(lb_type(m, t_i32), 0, false);

		isize testing_proc_index = 0;
		for (Entity *testing_proc : m->info->testing_procedures) {
			String name = testing_proc->token.string;

			String pkg_name = {};
			if (testing_proc->pkg != nullptr) {
				pkg_name = testing_proc->pkg->name;
			}
			lbValue v_pkg  = lb_find_or_add_entity_string(m, pkg_name, false);
			lbValue v_name = lb_find_or_add_entity_string(m, name,     false);
			lbValue v_proc = lb_find_procedure_value_from_entity(m, testing_proc);

			indices[1] = LLVMConstInt(lb_type(m, t_int), testing_proc_index++, false);

			LLVMValueRef vals[3] = {};
			vals[0] = v_pkg.value;
			vals[1] = v_name.value;
			vals[2] = v_proc.value;
			GB_ASSERT(LLVMIsConstant(vals[0]));
			GB_ASSERT(LLVMIsConstant(vals[1]));
			GB_ASSERT(LLVMIsConstant(vals[2]));

			LLVMValueRef dst = LLVMConstInBoundsGEP2(llvm_addr_type(m, all_tests_array), all_tests_array.value, indices, gb_count_of(indices));
			LLVMValueRef src = llvm_const_named_struct(m, t_Internal_Test, vals, gb_count_of(vals));

			LLVMBuildStore(p->builder, src, dst);
		}

		lbAddr all_tests_slice = lb_add_local_generated(p, slice_type, true);
		lb_fill_slice(p, all_tests_slice,
		              lb_array_elem(p, all_tests_array),
		              lb_const_int(m, t_int, m->info->testing_procedures.count));


		lbValue runner = lb_find_package_value(m, str_lit("testing"), str_lit("runner"));

		TEMPORARY_ALLOCATOR_GUARD();
		auto args = array_make<lbValue>(temporary_allocator(), 1);
		args[0] = lb_addr_load(p, all_tests_slice);
		lbValue result = lb_emit_call(p, runner, args);

		lbValue exit_runner = {};
		{
			AstPackage *pkg = get_runtime_package(m->info);

			String name = str_lit("exit");
			Entity *e = scope_lookup_current(pkg->scope, string_interner_insert(name));
			if (e == nullptr) {
				compiler_error("Could not find type declaration for '%.*s.%.*s'\n", LIT(pkg->name), LIT(name));
			}
			exit_runner = lb_find_value_from_entity(m, e);
		}

		auto exit_args = array_make<lbValue>(temporary_allocator(), 1);
		exit_args[0] = lb_emit_select(p, result, lb_const_int(m, t_int, 0), lb_const_int(m, t_int, 1));
		lb_emit_call(p, exit_runner, exit_args, ProcInlining_none, ProcTailing_none);
	} else {
		if (m->info->entry_point != nullptr) {
			lbValue entry_point = lb_find_procedure_value_from_entity(m, m->info->entry_point);
			lb_emit_call(p, entry_point, {}, ProcInlining_no_inline, ProcTailing_none);
		}

		if (call_cleanup) {
			lbValue cleanup_runtime_value = {cleanup_runtime->value, cleanup_runtime->type};
			lb_emit_call(p, cleanup_runtime_value, {}, ProcInlining_none, ProcTailing_none);
		}

		if (is_dll_main) {
			LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_i32), 1, false));
		} else {
			LLVMBuildRet(p->builder, LLVMConstInt(lb_type(m, t_i32), 0, false));
		}
	}

	lb_end_procedure_body(p);


	LLVMSetLinkage(p->value, LLVMExternalLinkage);
	if (is_arch_wasm()) {
		lb_set_wasm_export_attributes(p->value, p->name);
	}


	lb_verify_function(m, p);

	lb_run_function_pass_manager(default_function_pass_manager, p, lbFunctionPassManager_default);
	return p;
}

gb_internal void lb_generate_procedure(lbModule *m, lbProcedure *p) {
	if (p->is_done.load(std::memory_order_relaxed)) {
		return;
	}

	if (p->body != nullptr) { // Build Procedure
		m->curr_procedure = p;
		lb_begin_procedure_body(p);
		lb_build_stmt(p, p->body);
		lb_end_procedure_body(p);
		p->is_done.store(true, std::memory_order_relaxed);
		m->curr_procedure = nullptr;
	} else if (p->generate_body != nullptr) {
		p->generate_body(m, p);
	}

	// Add Flags
	if (p->entity && p->entity->kind == Entity_Procedure && p->entity->Procedure.is_memcpy_like) {
		p->flags |= lbProcedureFlag_WithoutMemcpyPass;
	}

	lb_verify_function(m, p, true);

	MUTEX_GUARD(&m->generated_procedures_mutex);
	array_add(&m->generated_procedures, p);
}


// ---------------------------------------------------------------------------
// Hot reload: arena for new globals + build-to-build manifest
//
// A reload object may introduce globals that did not exist when the exe was
// built. They cannot live in the object's own data (it is remapped every reload,
// so state would be lost) and there is no room for them in the exe's fixed data
// sections. Instead the exe reserves a zero-init arena and reload objects place
// new globals into it at fixed byte offsets, so their state persists across every
// reload. The manifest is the compiler's persistent record of each new global's
// offset, kept between builds.
// ---------------------------------------------------------------------------

gb_internal u64 lb_hot_reload_parse_u64(String s) {
	u64 v = 0;
	for (isize i = 0; i < s.len; i++) {
		u8 c = s[i];
		if (c < '0' || c > '9') break;
		v = v*10 + cast(u64)(c - '0');
	}
	return v;
}

// The reserved storage new globals are placed into. Defined (zero-init) in the
// base exe build; an external declaration (resolved by the loader to the exe's
// arena) in a reload object build.
gb_internal LLVMValueRef lb_hot_reload_arena(lbModule *m) {
	LLVMValueRef existing = LLVMGetNamedGlobal(m->mod, "__odin_hot_reload_global_arena");
	if (existing != nullptr) {
		return existing;
	}
	i64 size = build_context.hot_reload_arena_size;
	if (size <= 0) {
		size = 1;
	}
	LLVMTypeRef arena_t = LLVMArrayType(lb_type(m, t_u8), cast(unsigned)size);
	LLVMValueRef arena = LLVMAddGlobal(m->mod, arena_t, "__odin_hot_reload_global_arena");
	if (build_context.hot_reload_is_reload) {
		LLVMSetLinkage(arena, LLVMExternalLinkage); // reference the exe's arena
	} else {
		LLVMSetInitializer(arena, LLVMConstNull(arena_t));
		// External (public) so the loader can find the arena by name in the exe's PDB
		// (the baked symbol table that used to carry its address is gone).
		LLVMSetLinkage(arena, LLVMExternalLinkage);
	}
	// Over-align the arena so aggregate / f64 / SIMD globals placed at aligned
	// offsets within it are correctly aligned relative to the (aligned) base.
	LLVMSetAlignment(arena, 16);
	return arena;
}

// A constant pointer of `ptr_type` into the arena at byte `offset`.
gb_internal LLVMValueRef lb_hot_reload_arena_ptr(lbModule *m, i64 offset, Type *ptr_type) {
	LLVMValueRef arena = lb_hot_reload_arena(m);
	i64 size = build_context.hot_reload_arena_size;
	if (size <= 0) {
		size = 1;
	}
	LLVMTypeRef arena_t = LLVMArrayType(lb_type(m, t_u8), cast(unsigned)size);
	LLVMValueRef indices[2] = {};
	indices[0] = LLVMConstInt(lb_type(m, t_i32), 0, false);
	indices[1] = LLVMConstInt(lb_type(m, t_int), offset, false);
	LLVMValueRef gep = LLVMConstInBoundsGEP2(arena_t, arena, indices, 2);
	return LLVMConstPointerCast(gep, lb_type(m, ptr_type));
}

// Per-thread reserved storage for thread-locals introduced across a reload. This is
// a `@thread_local` array in the exe, so every thread (existing and future) gets its
// own zeroed copy at a fixed offset within its TLS block. New thread-locals are
// placed at offsets inside it; because access goes through this thread_local symbol,
// the loader's existing SECREL handler resolves them to the exe's TLS block (the
// arena is published in the symbol table as a HOT_RELOAD_KIND_TLS accessor). Defined
// (zero-init) in BOTH base and reload builds: TLS references resolve by SECREL name
// rewrite, not by symbol address, so the reload object's own (unused) copy is fine.
gb_internal LLVMValueRef lb_hot_reload_tls_arena(lbModule *m) {
	LLVMValueRef existing = LLVMGetNamedGlobal(m->mod, "__odin_hot_reload_tls_arena");
	if (existing != nullptr) {
		return existing;
	}
	i64 size = build_context.hot_reload_tls_arena_size;
	if (size <= 0) {
		size = 1;
	}
	LLVMTypeRef arena_t = LLVMArrayType(lb_type(m, t_u8), cast(unsigned)size);
	LLVMValueRef arena = LLVMAddGlobal(m->mod, arena_t, "__odin_hot_reload_tls_arena");
	LLVMSetInitializer(arena, LLVMConstNull(arena_t));
	LLVMSetLinkage(arena, LLVMInternalLinkage);
	LLVMSetThreadLocal(arena, true);
	LLVMSetThreadLocalMode(arena, LLVMGeneralDynamicTLSModel);
	LLVMSetAlignment(arena, 16);
	return arena;
}

// A constant (thread-local) pointer of `ptr_type` into the TLS arena at byte `offset`.
gb_internal LLVMValueRef lb_hot_reload_tls_arena_ptr(lbModule *m, i64 offset, Type *ptr_type) {
	LLVMValueRef arena = lb_hot_reload_tls_arena(m);
	i64 size = build_context.hot_reload_tls_arena_size;
	if (size <= 0) {
		size = 1;
	}
	LLVMTypeRef arena_t = LLVMArrayType(lb_type(m, t_u8), cast(unsigned)size);
	LLVMValueRef indices[2] = {};
	indices[0] = LLVMConstInt(lb_type(m, t_i32), 0, false);
	indices[1] = LLVMConstInt(lb_type(m, t_int), offset, false);
	LLVMValueRef gep = LLVMConstInBoundsGEP2(arena_t, arena, indices, 2);
	return LLVMConstPointerCast(gep, lb_type(m, ptr_type));
}

// HotReloadNewEntry, HotReloadManifest, and HotReloadInitEntry are defined in
// llvm_backend.hpp so llvm_backend_stmt.cpp can see them (unity build order).

gb_internal void hot_reload_manifest_read(HotReloadManifest *hm) {
	string_map_init(&hm->orig);
	string_map_init(&hm->sig);
	string_map_init(&hm->fhash);
	string_map_init(&hm->newg);
	string_map_init(&hm->tls_newg);
	hm->exists = false;
	hm->build_id = 0;
	hm->next_free = 0;
	hm->arena_size = build_context.hot_reload_arena_size;
	hm->tls_next_free = 0;
	hm->tls_arena_size = build_context.hot_reload_tls_arena_size;

	if (build_context.hot_reload_manifest.len == 0) {
		return;
	}
	char const *path_c = alloc_cstring(temporary_allocator(), build_context.hot_reload_manifest);
	gbFileContents fc = gb_file_read_contents(permanent_allocator(), true, path_c);
	if (fc.data == nullptr || fc.size == 0) {
		return; // no manifest yet: this is the base (exe) build
	}
	hm->exists = true;
	build_context.hot_reload_is_reload = true;

	String content = make_string(cast(u8 const *)fc.data, cast(isize)fc.size);
	isize i = 0;
	while (i < content.len) {
		isize start = i;
		while (i < content.len && content[i] != '\n') { i++; }
		String line = make_string(content.text + start, i - start);
		if (i < content.len) { i++; }
		if (line.len > 0 && line[line.len-1] == '\r') { line.len--; }
		if (line.len == 0) { continue; }

		// Tokens are space separated; the (possibly space-containing) name is the
		// remainder of the line after the fixed numeric fields.
		isize p = 0;
		auto tok = [](String s, isize *pp) -> String {
			isize st = *pp;
			while (st < s.len && s[st] == ' ') { st++; }
			isize en = st;
			while (en < s.len && s[en] != ' ') { en++; }
			*pp = en;
			return make_string(s.text + st, en - st);
		};
		auto rest = [](String s, isize p) -> String {
			while (p < s.len && s[p] == ' ') { p++; }
			return make_string(s.text + p, s.len - p);
		};

		String tag = tok(line, &p);
		if (tag == "arena_size") {
			hm->arena_size = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
			build_context.hot_reload_arena_size = hm->arena_size;
		} else if (tag == "next_free") {
			hm->next_free = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
		} else if (tag == "tls_arena_size") {
			hm->tls_arena_size = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
			build_context.hot_reload_tls_arena_size = hm->tls_arena_size;
		} else if (tag == "tls_next_free") {
			hm->tls_next_free = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
		} else if (tag == "build_id") {
			hm->build_id = lb_hot_reload_parse_u64(tok(line, &p));
		} else if (tag == "orig") {
			u64 th = lb_hot_reload_parse_u64(tok(line, &p));
			String name = rest(line, p);
			if (name.len > 0) { string_map_set(&hm->orig, name, th); }
		} else if (tag == "sig") {
			u64 sh = lb_hot_reload_parse_u64(tok(line, &p));
			String name = rest(line, p);
			if (name.len > 0) { string_map_set(&hm->sig, name, sh); }
		} else if (tag == "fhash") {
			u64 ch = lb_hot_reload_parse_u64(tok(line, &p));
			String name = rest(line, p);
			if (name.len > 0) { string_map_set(&hm->fhash, name, ch); }
		} else if (tag == "new") {
			i64 off     = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
			u64 th      = lb_hot_reload_parse_u64(tok(line, &p));
			i64 flag_p1 = cast(i64)lb_hot_reload_parse_u64(tok(line, &p)); // stored as offset+1 (0 == none)
			String name = rest(line, p);
			if (name.len > 0) {
				HotReloadNewEntry ne = {off, th, flag_p1 - 1};
				string_map_set(&hm->newg, name, ne);
			}
		} else if (tag == "tls_new") {
			i64 off     = cast(i64)lb_hot_reload_parse_u64(tok(line, &p));
			u64 th      = lb_hot_reload_parse_u64(tok(line, &p));
			i64 flag_p1 = cast(i64)lb_hot_reload_parse_u64(tok(line, &p)); // per-thread guard offset+1 (0 == none)
			String name = rest(line, p);
			if (name.len > 0) {
				HotReloadNewEntry ne = {off, th, flag_p1 - 1};
				string_map_set(&hm->tls_newg, name, ne);
			}
		}
	}
}

gb_internal void hot_reload_manifest_write(HotReloadManifest *hm) {
	if (build_context.hot_reload_manifest.len == 0) {
		return;
	}
	// A rejected build (e.g. the ABI guard below, or an exhausted arena) must not persist
	// its state: overwriting the manifest with a bad `sig`/offsets would make the guard
	// "sticky" and reject even a subsequent corrected build. Leave the manifest untouched.
	if (any_errors()) {
		return;
	}
	char const *path_c = alloc_cstring(temporary_allocator(), build_context.hot_reload_manifest);
	gbFile f = {};
	if (gb_file_open_mode(&f, gbFileMode_Write, path_c) != gbFileError_None) {
		return;
	}
	defer (gb_file_close(&f));
	gb_fprintf(&f, "arena_size %llu\n", cast(unsigned long long)hm->arena_size);
	gb_fprintf(&f, "next_free %llu\n", cast(unsigned long long)hm->next_free);
	gb_fprintf(&f, "tls_arena_size %llu\n", cast(unsigned long long)hm->tls_arena_size);
	gb_fprintf(&f, "tls_next_free %llu\n", cast(unsigned long long)hm->tls_next_free);
	gb_fprintf(&f, "build_id %llu\n", cast(unsigned long long)hm->build_id);
	for (u32 idx = 0; idx < hm->orig.count; idx++) {
		StringMapEntry<u64> const &e = hm->orig.entries[idx];
		gb_fprintf(&f, "orig %llu %.*s\n", cast(unsigned long long)e.value, LIT(e.key));
	}
	for (u32 idx = 0; idx < hm->sig.count; idx++) {
		StringMapEntry<u64> const &e = hm->sig.entries[idx];
		gb_fprintf(&f, "sig %llu %.*s\n", cast(unsigned long long)e.value, LIT(e.key));
	}
	for (u32 idx = 0; idx < hm->fhash.count; idx++) {
		StringMapEntry<u64> const &e = hm->fhash.entries[idx];
		gb_fprintf(&f, "fhash %llu %.*s\n", cast(unsigned long long)e.value, LIT(e.key));
	}
	for (u32 idx = 0; idx < hm->newg.count; idx++) {
		StringMapEntry<HotReloadNewEntry> const &e = hm->newg.entries[idx];
		gb_fprintf(&f, "new %llu %llu %llu %.*s\n", cast(unsigned long long)e.value.offset, cast(unsigned long long)e.value.type_hash, cast(unsigned long long)(e.value.init_flag_offset + 1), LIT(e.key));
	}
	for (u32 idx = 0; idx < hm->tls_newg.count; idx++) {
		StringMapEntry<HotReloadNewEntry> const &e = hm->tls_newg.entries[idx];
		gb_fprintf(&f, "tls_new %llu %llu %llu %.*s\n", cast(unsigned long long)e.value.offset, cast(unsigned long long)e.value.type_hash, cast(unsigned long long)(e.value.init_flag_offset + 1), LIT(e.key));
	}
}

// Emit the hot-reload support symbols the loader resolves from the running exe via
// its PDB. No name->address table is baked into the exe anymore — the loader finds
// every running procedure and global with DbgHelp `SymFromNameW`, so ordinary
// symbols are left to normal dead-code elimination (which the old baked table
// disabled by taking the address of every symbol). Only the few symbols the loader
// looks up by a *fixed, source-derived name* are force-kept here via `llvm.used` +
// external linkage, so they survive DCE and appear in the PDB:
//   - the new-global arena `__odin_hot_reload_global_arena`;
//   - the per-thread TLS arena (kept transitively via its accessor);
//   - a per-thread-local accessor `__odin_hrtls$<link-name>`.
// A procedure's `@(hot_reload)`-ness and a thread-local's identity are recovered by
// the loader structurally (the patchable prologue) and by naming convention (the
// accessor name), respectively, so no metadata section is needed.
// A stable, debug-normalized content hash of a procedure's emitted code, used for
// hot-reload change detection. We hash the function's LLVM IR text with debug info
// removed: skip debug-record lines and truncate each line at its first " !" (metadata
// operand). This is SOUND for change detection — a real instruction/operand change alters
// the kept text, so the hash differs — while debug-only differences (which do not change
// machine code) and metadata-ID renumbering from unrelated edits hash equal, so an
// unchanged procedure keeps the same hash across builds.
// Append a little-endian u64 to a byte buffer (for the self-contained loader tables).
gb_internal void lb_hot_reload_put_u64_le(Array<u8> *buf, u64 v) {
	for (int b = 0; b < 8; b++) {
		array_add(buf, cast(u8)((v >> (8*b)) & 0xff));
	}
}

// If `expr` is directly a `#name(...)` basic-directive call, return `name`; else "".
gb_internal String lb_call_basic_directive_name(Ast *expr) {
	if (expr == nullptr) {
		return str_lit("");
	}
	Ast *init = unparen_expr(expr);
	if (init != nullptr && init->kind == Ast_CallExpr &&
	    init->CallExpr.proc != nullptr && init->CallExpr.proc->kind == Ast_BasicDirective) {
		return init->CallExpr.proc->BasicDirective.name.string;
	}
	return str_lit("");
}

// Whether `expr` is a compile-time embedded-data directive call whose result is baked into
// the binary and should be re-provided fresh on reload: `#load`/`#load_directory` (file bytes)
// and `#hash`/`#load_hash` (a constant integer hash of a string literal / file contents). All
// but `#load_directory` already produce a constant the global loop bakes directly; a
// `#load_directory` global is baked via lb_const_load_directory_slice (see the global loop).
gb_internal bool lb_is_load_directive_expr(Ast *expr) {
	String n = lb_call_basic_directive_name(expr);
	return n == "load" || n == "load_directory" || n == "hash" || n == "load_hash";
}

// Build the constant `[]Load_Directory_File` slice value for a `#load_directory(call)` at
// MODULE scope (the codegen path in lb_build_builtin_proc is procedure-scoped). Used to bake
// a #load_directory global's initializer under -hot-reload so its static storage holds a real
// slice header the loader can repoint (a runtime-initialized global's storage would be zero).
gb_internal lbValue lb_const_load_directory_slice(lbModule *m, Ast *call) {
	TEMPORARY_ALLOCATOR_GUARD();
	LoadDirectoryCache *cache = map_must_get(&m->info->load_directory_map, call);
	isize count = cache->files.count;

	LLVMValueRef *elements = gb_alloc_array(temporary_allocator(), LLVMValueRef, count);
	for_array(i, cache->files) {
		LoadFileCache *file = cache->files[i];
		String file_name = filename_without_directory(file->path);
		LLVMValueRef values[2] = {};
		values[0] = lb_const_string(m, file_name).value;
		values[1] = lb_const_value(m, t_u8_slice, exact_value_string(file->data)).value;
		elements[i] = llvm_const_named_struct(m, t_load_directory_file, values, gb_count_of(values));
	}
	LLVMValueRef backing_array = llvm_const_array(m, lb_type(m, t_load_directory_file), elements, count);

	Type *array_type = alloc_type_array(t_load_directory_file, count);
	char const *bn = gb_bprintf("ldir$%s$%x", m->module_name, m->global_array_index.fetch_add(1));
	lbAddr backing = lb_add_global_generated_with_name(m, array_type, {backing_array, array_type}, make_string_c(bn));
	lb_make_global_private_const(backing);

	LLVMValueRef backing_ptr = LLVMConstPointerCast(backing.addr.value, lb_type(m, t_load_directory_file_ptr));
	LLVMValueRef const_slice = llvm_const_slice_internal(m, backing_ptr, LLVMConstInt(lb_type(m, t_int), count, false));

	lbValue res = {};
	res.value = const_slice;
	res.type  = t_load_directory_file_slice;
	return res;
}

// Whether a file-scope global (or local `@(static)`) holds immutable embedded data
// that the hot-reload loader must re-provide fresh on each reload rather than preserve:
//   * an `@(rodata)` variable, or
//   * a variable whose initializer is directly a `#load(...)` / `#load_directory(...)` directive.
// The bytes are read-only in either case (writing through them faults), so there is no
// runtime state to protect; the loader repoints the exe's copy at the reload's data.
gb_internal bool lb_is_hot_reload_refresh_global(Entity *e, DeclInfo *decl) {
	if (e != nullptr && e->kind == Entity_Variable && e->Variable.is_rodata) {
		return true;
	}
	return decl != nullptr && lb_is_load_directive_expr(decl->init_expr);
}

gb_internal u64 lb_hot_reload_proc_content_hash(lbProcedure *p) {
	// Free the normalized-IR scratch (`norm` below) per procedure. Without this, the
	// whole program's normalized IR text accumulates in the temporary allocator (this
	// runs for EVERY hot-reloadable proc under -hot-reload / single-module), spiking
	// compile memory in proportion to total program size.
	TEMPORARY_ALLOCATOR_GUARD();
	char *ir = LLVMPrintValueToString(p->value);
	if (ir == nullptr) {
		return 0;
	}
	// Compiler-generated constant globals (string backing stores etc.) are named
	// `<prefix>$<module_name>$<hex-index>` (llvm_backend_general.cpp), where BOTH the
	// module name (from -out) and the atomic index vary between builds. A procedure that
	// references a string literal would otherwise hash differently every build. Strip the
	// build-specific `$<module_name>$<hex>` suffix wherever it appears so such references
	// canonicalize (the referenced length stays, so a length change is still detected).
	char const *mod = p->module ? p->module->module_name : nullptr;
	isize mod_len = (mod != nullptr) ? cast(isize)gb_strlen(mod) : 0;

	gbString norm = gb_string_make(temporary_allocator(), "");
	char const *s = ir;
	while (*s) {
		char const *line = s;
		char const *nl = line;
		while (*nl && *nl != '\n') { nl++; }
		isize line_len = nl - line;

		// Drop debug-record lines entirely (llvm.dbg.* intrinsics / #dbg_ records).
		bool is_dbg = false;
		for (isize i = 0; i < line_len; i++) {
			if (line[i] == '#' && (line_len - i) >= 5 && gb_strncmp(line+i, "#dbg_", 5) == 0) { is_dbg = true; break; }
			if (line[i] == 'l' && (line_len - i) >= 9 && gb_strncmp(line+i, "llvm.dbg.", 9) == 0) { is_dbg = true; break; }
		}
		if (!is_dbg) {
			// Truncate at the first " !" or " #": in LLVM IR text '!' introduces trailing
			// metadata operands (e.g. `, !dbg !12`) and '#' introduces attribute-group
			// references (e.g. `... #0 ...`). Both are module-globally numbered and renumber
			// between builds when unrelated code is added/removed, so an unchanged procedure
			// would otherwise hash differently. Instruction operands always precede them, so
			// truncating keeps the semantically-relevant prefix.
			isize keep = line_len;
			for (isize i = 0; i + 1 < line_len; i++) {
				if (line[i] == ' ' && (line[i+1] == '!' || line[i+1] == '#')) { keep = i; break; }
			}
			// Trim trailing spaces/commas left where metadata was stripped, so a -debug
			// instruction (`br label %e, !dbg !N` -> `br label %e,`) hashes identically to
			// its non-debug counterpart (`br label %e`). The base exe is built -debug while
			// the reload object usually is not, so the two forms must reconcile.
			while (keep > 0 && (line[keep-1] == ' ' || line[keep-1] == ',')) {
				keep--;
			}
			// Append the kept text, collapsing any `$<module_name>$<hex>` run (the
			// build-specific tail of a compiler-generated constant global's name).
			isize i = 0;
			while (i < keep) {
				if (mod_len > 0 && line[i] == '$' && (keep - i) >= (mod_len + 2) &&
				    gb_strncmp(line + i + 1, mod, mod_len) == 0 && line[i + 1 + mod_len] == '$') {
					isize j = i + 1 + mod_len + 1; // past "$<module_name>$"
					while (j < keep) {
						char c = line[j];
						bool is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
						if (!is_hex) { break; }
						j++;
					}
					i = j; // drop "$<module_name>$<hex>" entirely
				} else {
					norm = gb_string_append_length(norm, line + i, 1);
					i++;
				}
			}
			norm = gb_string_appendc(norm, "\n");
		}
		s = (*nl == '\n') ? nl+1 : nl;
	}
	u64 h = fnv64a(norm, gb_string_length(norm));
	LLVMDisposeMessage(ir);
	return h;
}

// Emit `__odin_hot_reload_func_hashes` — a table of {u64 name_hash, u64 content_hash} for
// every hot-reloadable procedure (same set the patchable prologue is emitted for). It carries
// NO addresses and roots nothing, so dead-code elimination stays enabled. The reload loader
// reads the exe's copy (via the PDB) as the change-detection baseline and the reload object's
// copy (via its COFF symbol) each reload, and patches only procedures whose content hash
// changed. `name_hash` is FNV-1a-64 of the link name (matches the loader's `hr_fnv64`).
gb_internal void lb_hot_reload_emit_func_hashes(lbGenerator *gen) {
	lbModule *m = &gen->default_module;

	LLVMTypeRef u64t = lb_type(m, t_u64);
	LLVMTypeRef i64t = lb_type(m, t_i64);
	LLVMTypeRef entry_field_types[2] = { u64t, u64t }; // { name_hash, content_hash }
	LLVMTypeRef entry_t = LLVMStructTypeInContext(m->ctx, entry_field_types, 2, false);

	HotReloadManifest &hm = gen->hot_reload_manifest;
	auto entries = array_make<LLVMValueRef>(temporary_allocator(), 0, 1024);
	for (lbProcedure *p : m->generated_procedures) {
		if (!lb_proc_is_hot_reloadable(p)) {
			continue;
		}
		u64 name_hash    = fnv64a(p->name.text, p->name.len);
		u64 content_hash = lb_hot_reload_proc_content_hash(p);

		// Persist this build's per-proc content hash into the manifest (item 3 cheap half):
		// the base build's fhash is the exe's per-proc baseline, which a future reload build
		// can diff against at compile time to decide which procedures to emit. Inert today
		// (the loader still diffs at runtime); groundwork for minimal object emission.
		string_map_set(&hm.fhash, p->name, content_hash);

		// Hot-proc ABI guard (F8): the frozen host's call sites marshal the ORIGINAL
		// signature into the patched-in body, so a hot proc's parameter/return types must
		// not change across a reload. Record each hot proc's canonical signature hash in
		// the manifest (base build); on a reload build reject any proc whose signature
		// changed — mirrors the existing global type-hash guard.
		if (p->type != nullptr) {
			u64 sig_hash = type_hash_canonical_type(p->type);
			if (hm.exists) {
				u64 *prev = string_map_get(&hm.sig, p->name);
				if (prev != nullptr && *prev != sig_hash) {
					Token tok = (p->entity != nullptr) ? p->entity->token : empty_token;
					error(tok, "hot-reload: procedure '%.*s' changed its signature (parameter/return types); the frozen host still calls it with the original ABI, so this is rejected. Revert the signature or restart the program", LIT(p->name));
				}
			}
			string_map_set(&hm.sig, p->name, sig_hash);
		}
		LLVMValueRef fields[2] = {
			LLVMConstInt(u64t, name_hash,    false),
			LLVMConstInt(u64t, content_hash, false),
		};
		array_add(&entries, LLVMConstStructInContext(m->ctx, fields, 2, false));
	}

	LLVMTypeRef arr_t = LLVMArrayType(entry_t, cast(unsigned)entries.count);
	LLVMValueRef arr  = LLVMConstArray(entry_t, entries.data, cast(unsigned)entries.count);

	LLVMTypeRef tbl_field_types[2] = { i64t, arr_t }; // { count, entries[] }
	LLVMTypeRef tbl_t = LLVMStructTypeInContext(m->ctx, tbl_field_types, 2, false);
	LLVMValueRef tbl_fields[2] = { LLVMConstInt(i64t, cast(u64)entries.count, false), arr };
	LLVMValueRef tbl_val = LLVMConstStructInContext(m->ctx, tbl_fields, 2, false);

	LLVMValueRef tbl = LLVMAddGlobal(m->mod, tbl_t, "__odin_hot_reload_func_hashes");
	LLVMSetInitializer(tbl, tbl_val);
	LLVMSetGlobalConstant(tbl, true);
	LLVMSetLinkage(tbl, LLVMExternalLinkage); // public: PDB-resolvable baseline in the exe
	lb_append_to_used(m, tbl);                // survive DCE; the loader reads it by name
}

// Emit `__odin_hot_reload_build_id : u64` — a fingerprint of the exe's reload-relevant
// layout (arena sizes + the original globals' and hot procs' canonical hashes). The same
// value is baked into the exe (base build) and every reload object (read back from the
// manifest), and the loader refuses a reload whose id differs from the running exe's — so a
// stale object built against a since-rebuilt exe (arena relaid) is rejected instead of
// silently corrupting memory at now-wrong arena offsets (F6). Call AFTER
// `lb_hot_reload_emit_func_hashes` so the manifest's `sig` map is fully populated.
gb_internal void lb_hot_reload_emit_build_id(lbGenerator *gen) {
	lbModule *m = &gen->default_module;
	HotReloadManifest &hm = gen->hot_reload_manifest;

	if (!hm.exists) {
		// Base (exe) build: derive the id from the layout the reload contract depends on.
		// Fold entries with commutative addition so the value is independent of map/thread
		// iteration order (reproducible across separate base builds of the same source).
		u64 id = 0;
		id += 0x9E3779B97F4A7C15ull ^ cast(u64)hm.arena_size;
		id += 0xC2B2AE3D27D4EB4Full ^ cast(u64)hm.tls_arena_size;
		for (u32 idx = 0; idx < hm.orig.count; idx++) {
			StringMapEntry<u64> const &e = hm.orig.entries[idx];
			id += fnv64a(e.key.text, e.key.len) * 1099511628211ull + e.value;
		}
		for (u32 idx = 0; idx < hm.sig.count; idx++) {
			StringMapEntry<u64> const &e = hm.sig.entries[idx];
			id += (fnv64a(e.key.text, e.key.len) ^ 0xD6E8FEB86659FD93ull) * 1099511628211ull + e.value;
		}
		hm.build_id = id;
	}
	// Reload build: hm.build_id already holds the value read from the manifest (the exe's).

	LLVMTypeRef u64t = lb_type(m, t_u64);
	LLVMValueRef g = LLVMAddGlobal(m->mod, u64t, "__odin_hot_reload_build_id");
	LLVMSetInitializer(g, LLVMConstInt(u64t, hm.build_id, false));
	LLVMSetGlobalConstant(g, true);
	LLVMSetLinkage(g, LLVMExternalLinkage); // public: PDB-resolvable in the exe, defined in the object
	lb_append_to_used(m, g);                // survive DCE; the loader reads it by name
}

gb_internal void lb_hot_reload_emit_support(lbGenerator *gen) {
	lbModule *m = &gen->default_module;
	LLVMTypeRef rawptr_llvm = lb_type(m, t_rawptr);

	// Reserve the per-thread TLS arena and record it so a new thread-local (a GEP into
	// it) resolves through this arena's accessor. Every thread's static TLS block then
	// includes the arena, so new thread-locals introduced by a reload have per-thread
	// storage.
	if (build_context.hot_reload_tls_arena_size > 0) {
		LLVMValueRef tls_arena = lb_hot_reload_tls_arena(m);
		lbHotReloadStaticSym s = {str_lit("__odin_hot_reload_tls_arena"), tls_arena, 0};
		array_add(&gen->hot_reload_tls_syms, s);
	}

	// Thread-locals (file-scope globals, local `@(static)`, and the TLS arena). A
	// thread-local is accessed via `_tls_index` + a per-variable SECREL offset into the
	// TLS block, so it has no plain address. For each we emit a tiny accessor
	// `__odin_hrtls$<link-name>() -> rawptr { return &var }`; a use of the thread_local
	// inside a function lowers to the exe's TLS access sequence, so it returns the
	// per-thread address. The loader derives this name from a SECREL relocation's
	// target variable, finds the accessor in the exe's PDB, and calls it to learn the
	// variable's offset in the exe's TLS block — no baked mapping required, because the
	// name is a pure function of the variable's (build-stable) link name.
	{
		LLVMTypeRef acc_ty = LLVMFunctionType(rawptr_llvm, nullptr, 0, false);
		for (lbHotReloadStaticSym const &s : gen->hot_reload_tls_syms) {
			if (s.name.len == 0 || s.value == nullptr) {
				continue;
			}
			char const *acc_name = gb_bprintf("__odin_hrtls$%.*s", LIT(s.name));
			LLVMValueRef acc = LLVMAddFunction(m->mod, acc_name, acc_ty);
			LLVMSetLinkage(acc, LLVMExternalLinkage); // public: found via the exe's PDB
			LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(m->ctx, acc, "entry");
			LLVMBuilderRef b = LLVMCreateBuilderInContext(m->ctx);
			LLVMPositionBuilderAtEnd(b, bb);
			LLVMValueRef addr = LLVMBuildPointerCast(b, s.value, rawptr_llvm, "");
			LLVMBuildRet(b, addr);
			LLVMDisposeBuilder(b);
			lb_append_to_used(m, acc); // loader calls it by name; survive linker DCE
		}
	}

	// Reserve the new-global arena and force-keep it. A reload object references it as
	// an external symbol (new globals compile to relocations against it), so it must
	// exist in the exe and be resolvable by name in the exe's PDB for every subsequent
	// reload — even a base build that has no new globals of its own.
	if (build_context.hot_reload_arena_size > 0) {
		LLVMValueRef arena = lb_hot_reload_arena(m);
		lb_append_to_used(m, arena);
	}
}

// Emit `sym_name : { i64 count; { i8* name; i64 name_len }[count] }` listing the
// EXPORTED SYMBOL NAME of every procedure flagged `want_pre`/`want_post` (a
// @(pre_patch_hook)/@(post_patch_hook)). The same table is baked into the exe and
// every reload object. The loader resolves each name itself — pre-patch hooks against
// the running exe (old code), post-patch hooks against the reloaded object (new code,
// its fresh copy). Storing names rather than pointers means a post hook does NOT need
// to be a patchable/hot procedure to reach its fresh copy: `find_symbol_address` on the
// object returns the object-local definition directly. Force-kept by name.
gb_internal void lb_hot_reload_emit_patch_hook_table(lbGenerator *gen, CheckerInfo *info, bool want_pre, char const *sym_name) {
	lbModule *m = &gen->default_module;
	LLVMTypeRef ptrt = lb_type(m, t_rawptr);
	LLVMTypeRef i64t = lb_type(m, t_i64);
	LLVMTypeRef entry_field_types[2] = { ptrt, i64t };
	LLVMTypeRef entry_t = LLVMStructTypeInContext(m->ctx, entry_field_types, 2, false);

	auto entry_vals = array_make<LLVMValueRef>(temporary_allocator(), 0, 8);
	for (Entity *e : info->entities) {
		if (e->kind != Entity_Procedure) {
			continue;
		}
		bool match = want_pre ? e->Procedure.is_pre_patch_hook : e->Procedure.is_post_patch_hook;
		if (!match) {
			continue;
		}
		lbValue fn = lb_find_value_from_entity(m, e);
		if (fn.value == nullptr) {
			continue;
		}
		size_t name_len = 0;
		char const *name_c = LLVMGetValueName2(fn.value, &name_len);
		String name = make_string(cast(u8 const *)name_c, cast(isize)name_len);
		LLVMValueRef name_ptr = LLVMConstPointerCast(lb_find_or_add_entity_string_ptr(m, name, false), ptrt);
		LLVMValueRef fields[2] = { name_ptr, LLVMConstInt(i64t, cast(u64)name_len, false) };
		array_add(&entry_vals, LLVMConstStructInContext(m->ctx, fields, 2, false));
	}

	LLVMTypeRef arr_t = LLVMArrayType(entry_t, cast(unsigned)entry_vals.count);
	LLVMValueRef arr = LLVMConstArray(entry_t, entry_vals.data, cast(unsigned)entry_vals.count);
	LLVMTypeRef tbl_field_types[2] = { i64t, arr_t };
	LLVMTypeRef tbl_t = LLVMStructTypeInContext(m->ctx, tbl_field_types, 2, false);
	LLVMValueRef tbl_fields[2] = { LLVMConstInt(i64t, cast(u64)entry_vals.count, false), arr };
	LLVMValueRef tbl_val = LLVMConstStructInContext(m->ctx, tbl_fields, 2, false);

	LLVMValueRef tbl = LLVMAddGlobal(m->mod, tbl_t, sym_name);
	LLVMSetInitializer(tbl, tbl_val);
	LLVMSetGlobalConstant(tbl, true);
	// External + llvm.used so it survives linker DCE and lands in the exe's PDB.
	LLVMSetLinkage(tbl, LLVMExternalLinkage);
	lb_append_to_used(m, tbl);
}

gb_internal bool lb_generate_code(lbGenerator *gen) {
	TIME_SECTION("LLVM Initializtion");

	isize thread_count = gb_max(build_context.thread_count, 1);
	isize worker_count = thread_count-1;

	bool do_threading = !!(LLVMIsMultithreaded() && USE_SEPARATE_MODULES && MULTITHREAD_OBJECT_GENERATION && worker_count > 0);

	lbModule *default_module = &gen->default_module;
	CheckerInfo *info = gen->info;

	switch (build_context.metrics.arch) {
	case TargetArch_amd64: 
	case TargetArch_i386:
		LLVMInitializeX86TargetInfo();
		LLVMInitializeX86Target();
		LLVMInitializeX86TargetMC();
		LLVMInitializeX86AsmPrinter();
		LLVMInitializeX86AsmParser();
		LLVMInitializeX86Disassembler();
		break;
	case TargetArch_arm64:
		LLVMInitializeAArch64TargetInfo();
		LLVMInitializeAArch64Target();
		LLVMInitializeAArch64TargetMC();
		LLVMInitializeAArch64AsmPrinter();
		LLVMInitializeAArch64AsmParser();
		LLVMInitializeAArch64Disassembler();
		break;
	case TargetArch_wasm32:
	case TargetArch_wasm64p32:
		LLVMInitializeWebAssemblyTargetInfo();
		LLVMInitializeWebAssemblyTarget();
		LLVMInitializeWebAssemblyTargetMC();
		LLVMInitializeWebAssemblyAsmPrinter();
		LLVMInitializeWebAssemblyAsmParser();
		LLVMInitializeWebAssemblyDisassembler();
		break;
	case TargetArch_riscv64:
		LLVMInitializeRISCVTargetInfo();
		LLVMInitializeRISCVTarget();
		LLVMInitializeRISCVTargetMC();
		LLVMInitializeRISCVAsmPrinter();
		LLVMInitializeRISCVAsmParser();
		LLVMInitializeRISCVDisassembler();
		break;
	case TargetArch_arm32:
		LLVMInitializeARMTargetInfo();
		LLVMInitializeARMTarget();
		LLVMInitializeARMTargetMC();
		LLVMInitializeARMAsmPrinter();
		LLVMInitializeARMAsmParser();
		LLVMInitializeARMDisassembler();
		break;
	default:
		GB_PANIC("Unimplemented LLVM target initialization");
		break;
	}

	
	if (build_context.microarch == "native") {
		LLVMInitializeNativeTarget();
	}

	char const *target_triple = alloc_cstring(permanent_allocator(), build_context.metrics.target_triplet);
	for (auto const &entry : gen->modules) {
		LLVMSetTarget(entry.value->mod, target_triple);
	}

	LLVMTargetRef target = {};
	char *llvm_error = nullptr;
	LLVMGetTargetFromTriple(target_triple, &target, &llvm_error);
	GB_ASSERT(target != nullptr);



	TIME_SECTION("LLVM Create Target Machine");

	LLVMCodeModel code_mode = LLVMCodeModelDefault;
	if (is_arch_wasm()) {
		code_mode = LLVMCodeModelJITDefault;
		debugf("LLVM code mode: LLVMCodeModelJITDefault\n");
	} else if (is_arch_x86() && build_context.metrics.os == TargetOs_freestanding) {
		code_mode = LLVMCodeModelKernel;
		debugf("LLVM code mode: LLVMCodeModelKernel\n");
	}

	if (code_mode == LLVMCodeModelDefault) {
		debugf("LLVM code mode: LLVMCodeModelDefault\n");
	}

	String llvm_cpu = get_final_microarchitecture();

	gbString llvm_features = gb_string_make(temporary_allocator(), "");
	String_Iterator it = {build_context.target_features_string, 0};
	String str = {};
	bool first = true;
	while (string_split_iterator_next(&it, ',', &str)) {
		if (!first) {
			llvm_features = gb_string_appendc(llvm_features, ",");
		}
		first = false;

		if (*str.text != '+' && *str.text != '-') {
			llvm_features = gb_string_appendc(llvm_features, "+");
		}

		llvm_features = gb_string_append_length(llvm_features, str.text, str.len);
	}

	debugf("CPU: %.*s, Features: %s\n", LIT(llvm_cpu), llvm_features);	

	// GB_ASSERT_MSG(LLVMTargetHasAsmBackend(target));

	LLVMCodeGenOptLevel code_gen_level = LLVMCodeGenLevelNone;
	switch (build_context.optimization_level) {
	default:/*fallthrough*/
	case 0: code_gen_level = LLVMCodeGenLevelNone;       break;
	case 1: code_gen_level = LLVMCodeGenLevelLess;       break;
	case 2: code_gen_level = LLVMCodeGenLevelDefault;    break;
	case 3: code_gen_level = LLVMCodeGenLevelAggressive; break;
	}

	// NOTE(bill): Target Machine Creation
	// NOTE(bill, 2021-05-04): Target machines must be unique to each module because they are not thread safe
	auto target_machines = array_make<LLVMTargetMachineRef>(permanent_allocator(), 0, gen->modules.count);

	for (auto const &entry : gen->modules) {
		LLVMTargetMachineRef target_machine = LLVMCreateTargetMachine(
			target, target_triple, (const char *)llvm_cpu.text,
			llvm_features,
			code_gen_level,
			get_reloc_mode(),
			code_mode);
		lbModule *m = entry.value;
		m->target_machine = target_machine;
		LLVMTargetDataRef data_layout = LLVMCreateTargetDataLayout(target_machine);
		LLVMSetModuleDataLayout(m->mod, data_layout);
		LLVMDisposeTargetData(data_layout);

	#if LLVM_VERSION_MAJOR >= 18
		if (build_context.fast_isel) {
			LLVMSetTargetMachineFastISel(m->target_machine, true);
		}
	#endif

		array_add(&target_machines, target_machine);
	}

	for (auto const &entry : gen->modules) {
		lbModule *m = entry.value;
		if (m->debug_builder) { // Debug Info
			for (auto const &file_entry : info->files) {
				AstFile *f = file_entry.value;
				LLVMMetadataRef res = LLVMDIBuilderCreateFile(m->debug_builder,
					cast(char const *)f->filename.text, f->filename.len,
					cast(char const *)f->directory.text, f->directory.len);
				lb_set_llvm_metadata(m, f, res);
			}

			TEMPORARY_ALLOCATOR_GUARD();

			gbString producer = gb_string_make(temporary_allocator(), "odin");
			// producer = gb_string_append_fmt(producer, " version %.*s", LIT(ODIN_VERSION));
			// #ifdef NIGHTLY
			// producer = gb_string_appendc(producer, "-nightly");
			// #endif
			// #ifdef GIT_SHA
			// producer = gb_string_append_fmt(producer, "-%s", GIT_SHA);
			// #endif

			gbString split_name = gb_string_make(temporary_allocator(), "");

			LLVMBool is_optimized = build_context.optimization_level > 0;
			AstFile *init_file = m->info->init_package->files[0];

			if (Entity *entry_point = m->info->entry_point) {
				if (Ast *ident = entry_point->identifier.load()) {
					if (ident->file_id) {
						init_file = ident->file();
					}
				}
			}

			LLVMBool split_debug_inlining = build_context.build_mode == BuildMode_Assembly;
			LLVMBool debug_info_for_profiling = false;

			m->debug_compile_unit = LLVMDIBuilderCreateCompileUnit(m->debug_builder, LLVMDWARFSourceLanguageC99,
				lb_get_llvm_metadata(m, init_file),
				producer, gb_string_length(producer),
				is_optimized, "", 0,
				1, split_name, gb_string_length(split_name),
				LLVMDWARFEmissionFull,
				0, split_debug_inlining,
				debug_info_for_profiling,
				"", 0, // sys_root
				"", 0  // SDK
			);
			GB_ASSERT(m->debug_compile_unit != nullptr);
		}
	}

	TIME_SECTION("LLVM Global Variables");

	if (!build_context.no_rtti) {
		lbModule *m = default_module;

		{ // Add type info data
			// GB_ASSERT_MSG(info->minimum_dependency_type_info_index_map.count == info->type_info_types.count, "%tu vs %tu", info->minimum_dependency_type_info_index_map.count, info->type_info_types.count);

			// isize max_type_info_count = info->minimum_dependency_type_info_index_map.count+1;
			isize max_type_info_count = info->type_info_types_hash_map.count;
			Type *t = alloc_type_array(t_type_info_ptr, max_type_info_count);

			// IMPORTANT NOTE(bill): As LLVM does not have a union type, an array of unions cannot be initialized
			// at compile time without cheating in some way. This means to emulate an array of unions is to use
			// a giant packed struct of "corrected" data types.

			LLVMTypeRef internal_llvm_type = lb_type(m, t);

			LLVMValueRef g = LLVMAddGlobal(m->mod, internal_llvm_type, LB_TYPE_INFO_DATA_NAME);
			LLVMSetInitializer(g, LLVMConstNull(internal_llvm_type));
			LLVMSetLinkage(g, USE_SEPARATE_MODULES ? LLVMExternalLinkage : LLVMInternalLinkage);
			LLVMSetUnnamedAddress(g, LLVMGlobalUnnamedAddr);
			LLVMSetGlobalConstant(g, true);

			lbValue value = {};
			value.value = g;
			value.type = alloc_type_pointer(t);

			lb_global_type_info_data_entity = alloc_entity_variable(nullptr, make_token_ident(LB_TYPE_INFO_DATA_NAME), t, EntityState_Resolved);
			lb_add_entity(m, lb_global_type_info_data_entity, value);

		}
		{ // Type info member buffer
			// NOTE(bill): Removes need for heap allocation by making it global memory
			isize count = 0;
			isize offsets_extra = 0;

			for (auto const &tt : m->info->type_info_types_hash_map) {
				Type *t = tt.type;
				if (t == nullptr) {
					continue;
				}
				isize index = lb_type_info_index(m->info, t, false);
				if (index < 0) {
					continue;
				}

				switch (t->kind) {
				case Type_Union:
					count += t->Union.variants.count;
					break;
				case Type_Struct:
					count += t->Struct.fields.count;
					break;
				case Type_Tuple:
					count += t->Tuple.variables.count;
					break;
				case Type_BitField:
					count += t->BitField.fields.count;
					// Twice is needed for the bit_offsets
					offsets_extra += t->BitField.fields.count;
					break;
				}
			}

			auto const global_type_info_make = [](lbModule *m, char const *name, Type *elem_type, i64 count) -> lbAddr {
				Type *t = alloc_type_array(elem_type, count);
				LLVMValueRef g = LLVMAddGlobal(m->mod, lb_type(m, t), name);
				LLVMSetInitializer(g, LLVMConstNull(lb_type(m, t)));
				LLVMSetLinkage(g, LLVMInternalLinkage);
				lb_make_global_private_const(g);
				lb_set_odin_rtti_section(g);
				return lb_addr({g, alloc_type_pointer(t)});
			};

			lb_global_type_info_member_types   = global_type_info_make(m, LB_TYPE_INFO_TYPES_NAME,   t_type_info_ptr, count);
			lb_global_type_info_member_names   = global_type_info_make(m, LB_TYPE_INFO_NAMES_NAME,   t_string,        count);
			lb_global_type_info_member_offsets = global_type_info_make(m, LB_TYPE_INFO_OFFSETS_NAME, t_uintptr,       count+offsets_extra);
			lb_global_type_info_member_usings  = global_type_info_make(m, LB_TYPE_INFO_USINGS_NAME,  t_bool,          count);
			lb_global_type_info_member_tags    = global_type_info_make(m, LB_TYPE_INFO_TAGS_NAME,    t_string,        count);
		}
	}


	isize global_variable_max_count = 0;
	bool already_has_entry_point = false;

	for (Entity *e : info->entities) {
		String name = e->token.string;

		if (e->kind == Entity_Variable) {
			global_variable_max_count++;
		} else if (e->kind == Entity_Procedure) {
			if ((e->scope->flags&ScopeFlag_Init) && name == "main") {
				GB_ASSERT(e == info->entry_point);
			}
			if (build_context.command_kind == Command_test &&
			    (e->Procedure.is_export || e->Procedure.link_name.len > 0)) {
				String link_name = e->Procedure.link_name;
				if (e->pkg->kind == Package_Runtime) {
					if (link_name == "main"           ||
					    link_name == "_main"          ||
					    link_name == "DllMain"        ||
					    link_name == "WinMain"        ||
					    link_name == "wWinMain"       ||
					    link_name == "mainCRTStartup" ||
					    link_name == "_start") {
						already_has_entry_point = true;
					}
				}
			}
		}
	}


	auto global_variables = array_make<lbGlobalVariable>(permanent_allocator(), 0, global_variable_max_count);

	// Under -hot-reload, load the manifest so we can tell original globals (emit
	// normally, resolved to the exe's live copy) from new ones (redirected into
	// the reserved arena so their state persists across reloads). The manifest,
	// the new-global init list, and the local-static symbol list are generator-
	// scoped: both this (single-threaded) loop and `lb_build_static_variables`
	// (on the procedure thread pool) contribute to them. The manifest is written
	// and the init table emitted only after all procedures — and therefore all
	// local statics — have been generated (see below).
	HotReloadManifest &hot_reload_manifest = gen->hot_reload_manifest;
	Array<HotReloadInitEntry> &hot_reload_inits = gen->hot_reload_inits;
	if (build_context.hot_reload) {
		hot_reload_inits = array_make<HotReloadInitEntry>(heap_allocator(), 0, 16);
		gen->hot_reload_tls_syms = array_make<lbHotReloadStaticSym>(heap_allocator(), 0, 16);
		gen->hot_reload_refresh_syms = array_make<lbHotReloadRefreshSym>(heap_allocator(), 0, 16);
		hot_reload_manifest_read(&hot_reload_manifest);
	}

	for (DeclInfo *d : info->variable_init_order) {
		Entity *e = d->entity;

		if ((e->scope->flags & ScopeFlag_File) == 0) {
			continue;
		}

		if (e->min_dep_count.load(std::memory_order_relaxed) == 0) {
			continue;
		}

		DeclInfo *decl = decl_info_of_entity(e);
		if (decl == nullptr) {
			continue;
		}
		GB_ASSERT(e->kind == Entity_Variable);


		bool is_foreign = e->Variable.is_foreign;
		bool is_export  = e->Variable.is_export;

		lbModule *default_module = &gen->default_module;

		lbModule *m = default_module;
		lbModule *e_module = lb_module_of_entity(gen, e, default_module);

		bool const split_globals_across_modules = false;
		if (split_globals_across_modules) {
			m = e_module;
		}

		String name = lb_get_entity_name(m, e);

		lbGlobalVariable var = {};
		var.decl = decl;

		if (build_context.hot_reload && !is_foreign) {
			bool is_refresh = lb_is_hot_reload_refresh_global(e, decl);
			if (is_refresh) {
				// Immutable embedded data (@(rodata) / `#load`): keep it a NORMAL global
				// (never arena-backed) and record {link name, size} so the loader repoints
				// the exe's copy at this reload's fresh data ("repoint old -> new"). An
				// ORIGINAL one flows through the orig type-guard below and its references
				// alias to the exe's single canonical copy (which the loader overwrites); a
				// NEW one falls through to object-local emission (resolved fresh each reload).
				lbHotReloadRefreshSym rs = { name, gb_max(type_size_of(e->type), 1) };
				array_add(&gen->hot_reload_refresh_syms, rs);
			}
			if (hot_reload_manifest.exists) {
				u64 th = type_hash_canonical_type(e->type);
				u64 *orig_th = string_map_get(&hot_reload_manifest.orig, name);
				if (orig_th != nullptr) {
					// Original global: emit normally below; the loader preserves it (or, for
					// an immutable-data global, repoints it — see is_refresh above).
					if (*orig_th != th) {
						error(e->token, "hot-reload: global '%.*s' changed type/layout across a reload; its preserved memory cannot be reinterpreted safely", LIT(name));
					}
				} else if (is_refresh) {
					// Brand-new immutable-data global: emit normally below (an object-local
					// fresh copy each reload) rather than routing into the persist-arena, so
					// its data is re-provided every reload and stays genuinely read-only.
				} else if (e->Variable.thread_local_model.len != 0) {
					// Brand-new thread-local introduced by this reload: place it in the
					// per-thread TLS arena (reserved in the exe) at a manifest-pinned
					// offset. Access goes through the arena's thread_local symbol, so the
					// loader's SECREL handler resolves it to the exe's TLS block. Odin
					// thread-locals cannot have initializers (checker rule), so this is
					// always zero-init — and the per-thread arena is already zeroed.
					i64 offset = 0;
					HotReloadNewEntry *ne = string_map_get(&hot_reload_manifest.tls_newg, name);
					if (ne != nullptr) {
						offset = ne->offset;
						if (ne->type_hash != th) {
							error(e->token, "hot-reload: new thread-local '%.*s' changed type/layout across a reload; its TLS arena storage cannot be reinterpreted safely", LIT(name));
						}
					} else {
						i64 al = gb_max(type_align_of(e->type), 1);
						i64 sz = gb_max(type_size_of(e->type), 1);
						offset = align_formula(hot_reload_manifest.tls_next_free, al);
						hot_reload_manifest.tls_next_free = offset + sz;
						if (hot_reload_manifest.tls_next_free > hot_reload_manifest.tls_arena_size) {
							error(e->token, "hot-reload: new-thread-local TLS arena exhausted (%lld/%lld bytes); rebuild the exe with a larger -hot-reload-tls-arena-size", cast(long long)hot_reload_manifest.tls_next_free, cast(long long)hot_reload_manifest.tls_arena_size);
						}
						HotReloadNewEntry added = {offset, th, -1};
						string_map_set(&hot_reload_manifest.tls_newg, name, added);
					}

					lbValue g = {};
					g.type  = alloc_type_pointer(e->type);
					g.value = lb_hot_reload_tls_arena_ptr(m, offset, alloc_type_pointer(e->type));
					var.is_initialized = true;
					var.var = g;
					array_add(&global_variables, var);
					lb_add_entity(m, e, g);
					lb_add_member(m, name, g);
					continue;
				} else {
					// Brand-new global introduced by this reload: redirect into the arena.
					//
					// Classify the initializer: none/zero/nil -> zero-init (the arena is
					// already zero); a compile-time constant -> the loader copies its bytes
					// into the arena slot once (guarded by a flag byte); anything runtime
					// (including new @(init)) -> unsupported.
					bool has_const_init = false;
					bool runtime_init   = false;
					lbValue init = {};
					if (decl->init_expr != nullptr) {
						if (is_type_any(e->type)) {
							runtime_init = true;
						} else {
							TypeAndValue tav = type_and_value_of_expr(decl->init_expr);
							if (tav.mode != Addressing_Invalid && tav.value.kind != ExactValue_Invalid) {
								if (!is_type_untyped_nil(tav.type)) {
									auto cc = LB_CONST_CONTEXT_DEFAULT;
									cc.allow_local = false;
									init = lb_const_value(m, e->type, tav.value, cc);
									if (init.value != nullptr && !LLVMIsNull(init.value)) {
										has_const_init = true;
									}
								}
							} else {
								runtime_init = true;
							}
						}
					}
					if (runtime_init) {
						error(e->token, "hot-reload: new global '%.*s' has a non-constant initializer; only compile-time constant initializers are supported for a global introduced across a reload (runtime initializers and new @(init) are not yet supported)", LIT(name));
					}

					i64 offset   = 0;
					i64 flag_off = -1;
					HotReloadNewEntry *ne = string_map_get(&hot_reload_manifest.newg, name);
					if (ne != nullptr) {
						offset   = ne->offset;
						flag_off = ne->init_flag_offset;
						if (ne->type_hash != th) {
							error(e->token, "hot-reload: new global '%.*s' changed type/layout across a reload; its arena storage cannot be reinterpreted safely", LIT(name));
						}
					} else {
						i64 al = gb_max(type_align_of(e->type), 1);
						i64 sz = gb_max(type_size_of(e->type), 1);
						offset = align_formula(hot_reload_manifest.next_free, al);
						hot_reload_manifest.next_free = offset + sz;
						if (has_const_init) {
							// One byte, gating the once-only copy in the loader.
							flag_off = hot_reload_manifest.next_free;
							hot_reload_manifest.next_free = flag_off + 1;
						}
						if (hot_reload_manifest.next_free > hot_reload_manifest.arena_size) {
							error(e->token, "hot-reload: new-global arena exhausted (%lld/%lld bytes); rebuild the exe with a larger -hot-reload-arena-size", cast(long long)hot_reload_manifest.next_free, cast(long long)hot_reload_manifest.arena_size);
						}
						HotReloadNewEntry added = {offset, th, flag_off};
						string_map_set(&hot_reload_manifest.newg, name, added);

						// Only the introducing build emits the constant + descriptor.
						if (has_const_init) {
							char const *blob_name = gb_bprintf("__odin_hrg_init_%td", cast(isize)hot_reload_inits.count);
							LLVMValueRef blob = LLVMAddGlobal(m->mod, LLVMTypeOf(init.value), blob_name);
							LLVMSetInitializer(blob, init.value);
							LLVMSetGlobalConstant(blob, true);
							LLVMSetLinkage(blob, LLVMPrivateLinkage);
							HotReloadInitEntry ie = {offset, flag_off, gb_max(type_size_of(e->type), 1), blob};
							array_add(&hot_reload_inits, ie);
						}
					}

					lbValue g = {};
					g.type  = alloc_type_pointer(e->type);
					g.value = lb_hot_reload_arena_ptr(m, offset, alloc_type_pointer(e->type));
					var.is_initialized = true;
					var.var = g;
					array_add(&global_variables, var);
					lb_add_entity(m, e, g);
					lb_add_member(m, name, g);
					continue;
				}
			} else {
				// Base (exe) build: record this global as original for later reloads.
				string_map_set(&hot_reload_manifest.orig, name, type_hash_canonical_type(e->type));
			}
		}

		lbValue g = {};
		g.type = alloc_type_pointer(e->type);
		g.value = LLVMAddGlobal(m->mod, lb_type(m, e->type), alloc_cstring(permanent_allocator(), name));

		if (decl->init_expr != nullptr) {
			TypeAndValue tav = type_and_value_of_expr(decl->init_expr);
			if (build_context.hot_reload && lb_call_basic_directive_name(decl->init_expr) == "load_directory") {
				// #load_directory yields a runtime VALUE, so a package-scope global would
				// normally be built by the startup runtime — leaving the reload object's
				// static storage zero, which the refresh repoint cannot use. Under
				// -hot-reload, bake the const slice as the initializer (like #load) so the
				// object carries a real header the loader repoints at the fresh backing data.
				lbValue init = lb_const_load_directory_slice(m, unparen_expr(decl->init_expr));
				LLVMDeleteGlobal(g.value);
				g.value = LLVMAddGlobal(m->mod, LLVMTypeOf(init.value), alloc_cstring(permanent_allocator(), name));
				LLVMSetInitializer(g.value, init.value);
				var.is_initialized = true;
			} else if (!is_type_any(e->type)) {
				if (tav.mode != Addressing_Invalid) {
					if (tav.value.kind != ExactValue_Invalid) {
						auto cc = LB_CONST_CONTEXT_DEFAULT;
						cc.is_rodata = e->kind == Entity_Variable && e->Variable.is_rodata;
						cc.allow_local = false;
						cc.link_section = e->Variable.link_section;

						ExactValue v = tav.value;
						lbValue init = lb_const_value(m, e->type, v, cc);


						LLVMDeleteGlobal(g.value);
						g.value = nullptr;
						g.value = LLVMAddGlobal(m->mod, LLVMTypeOf(init.value), alloc_cstring(permanent_allocator(), name));

						LLVMSetInitializer(g.value, init.value);
						var.is_initialized = true;
						if (cc.is_rodata) {
							LLVMSetGlobalConstant(g.value, true);
						}
					}
				}
			}
			if (!var.is_initialized && is_type_untyped_nil(tav.type)) {
				var.is_initialized = true;
				if (e->kind == Entity_Variable && e->Variable.is_rodata) {
					LLVMSetGlobalConstant(g.value, true);
				}
			}
		} else if (e->kind == Entity_Variable && e->Variable.is_rodata) {
			LLVMSetGlobalConstant(g.value, true);
		}


		lb_apply_thread_local_model(g.value, e->Variable.thread_local_model);

		if (is_foreign) {
			LLVMSetLinkage(g.value, LLVMExternalLinkage);
			LLVMSetDLLStorageClass(g.value, LLVMDLLImportStorageClass);
			LLVMSetExternallyInitialized(g.value, true);
			lb_add_foreign_library_path(m, e->Variable.foreign_library);
		} else if (LLVMGetInitializer(g.value) == nullptr) {
			LLVMSetInitializer(g.value, LLVMConstNull(lb_type(m, e->type)));
		}
		if (is_export) {
			LLVMSetLinkage(g.value, LLVMDLLExportLinkage);
			LLVMSetDLLStorageClass(g.value, LLVMDLLExportStorageClass);
		} else if (!is_foreign) {
			LLVM_SET_INTERNAL_WEAK_LINKAGE(g.value);
		}
		lb_set_linkage_from_entity_flags(m, g.value, e->flags);
		LLVMSetAlignment(g.value, cast(u32)type_align_of(e->type));

		if (e->Variable.link_section.len > 0) {
			LLVMSetSection(g.value, alloc_cstring(permanent_allocator(), e->Variable.link_section));
		}
		if (e->flags & EntityFlag_Require) {
			lb_append_to_compiler_used(m, g.value);
		}

		// Hot reload: a thread-local global is accessed via a per-variable SECREL
		// offset into the exe's TLS block, not a plain pointer — so it cannot be
		// resolved like an ordinary global. Record the raw thread_local global (a
		// later pass emits an accessor thunk + a HOT_RELOAD_KIND_TLS table entry so
		// the loader can rewrite SECREL sites to the exe's offset). `g.value` here is
		// still the raw global, before the const-pointer-cast below.
		if (build_context.hot_reload && !is_foreign && e->Variable.thread_local_model.len != 0) {
			lbHotReloadStaticSym s = {name, g.value, type_hash_canonical_type(e->type)};
			array_add(&gen->hot_reload_tls_syms, s);
		}

		if (m->debug_builder) {
			String global_name = e->token.string;
			if (global_name.len != 0 && global_name != "_") {
				LLVMMetadataRef llvm_file = lb_get_llvm_metadata(m, e->file);
				LLVMMetadataRef llvm_scope = llvm_file;

				LLVMBool local_to_unit = LLVMGetLinkage(g.value) == LLVMInternalLinkage;

				LLVMMetadataRef llvm_expr = LLVMDIBuilderCreateExpression(m->debug_builder, nullptr, 0);
				LLVMMetadataRef llvm_decl = nullptr;

				u32 align_in_bits = cast(u32)(8*type_align_of(e->type));

				// Under -hot-reload the loader resolves a reloaded object's reference to a
				// pre-existing global by looking its LINK name up in the exe's PDB. LLVM's
				// CodeView emitter names a global's PDB symbol after the debug DISPLAY name
				// (not the linkage name), and a global's display name is only its source
				// identifier (`hits`, not `pkg::hits`) — so a reload's `pkg::hits`
				// reference would miss and silently get a fresh copy (state not preserved).
				// Functions already store their link name in the PDB, so they resolve. Make
				// globals resolvable too by using the link name as the debug name here.
				// (A hot-reload build is a dev build; the debugger then shows `pkg::hits`.)
				String dbg_name = build_context.hot_reload ? name : global_name;
				char const *link_name = build_context.hot_reload ? cast(char const *)name.text : "";
				isize       link_len  = build_context.hot_reload ? name.len                  : 0;
				LLVMMetadataRef global_variable_metadata = LLVMDIBuilderCreateGlobalVariableExpression(
					m->debug_builder, llvm_scope,
					cast(char const *)dbg_name.text, dbg_name.len,
					link_name, link_len, // linkage name (PDB-resolvable under -hot-reload)
					llvm_file, e->token.pos.line,
					lb_debug_type(m, e->type),
					local_to_unit,
					llvm_expr,
					llvm_decl,
					align_in_bits
				);
				lb_set_llvm_metadata(m, g.value, global_variable_metadata);
				LLVMGlobalSetMetadata(g.value, 0, global_variable_metadata);
			}
		}

		if (default_module == m) {
			g.value = LLVMConstPointerCast(g.value, lb_type(m, alloc_type_pointer(e->type)));

			var.var = g;
			array_add(&global_variables, var);
		} else {
			lbValue local_g = {};
			local_g.type  = alloc_type_pointer(e->type);
			local_g.value = LLVMAddGlobal(default_module->mod, lb_type(default_module, e->type), alloc_cstring(permanent_allocator(), name));
			LLVMSetLinkage(local_g.value, LLVMExternalLinkage);

			var.var = local_g;
			array_add(&global_variables, var);

			lb_add_entity(default_module, e, local_g);
			lb_add_member(default_module, name, local_g);
		}

		lb_add_entity(m, e, g);
		lb_add_member(m, name, g);
	}

	// NOTE: the once-only new-global init table (`__odin_hot_reload_new_global_inits`)
	// and the manifest write are emitted *after* procedure generation, because local
	// `@(static)` variables — which also contribute new-global inits and manifest
	// entries — are only emitted while generating procedure bodies (see below).

	if (build_context.ODIN_DEBUG) {
		// Custom `.raddbg` section for its debugger
		if (build_context.metrics.os == TargetOs_windows) {
			lbModule *m = default_module;
			LLVMModuleRef mod = m->mod;
			LLVMContextRef ctx = m->ctx;

			{
				LLVMTypeRef type = LLVMArrayType(LLVMInt8TypeInContext(ctx), 1);
				LLVMValueRef global = LLVMAddGlobal(mod, type, "raddbg_is_attached_byte_marker");
				LLVMSetInitializer(global, LLVMConstNull(type));
				LLVMSetSection(global, ".raddbg");
			}

			if (gen->info->entry_point) {
				String mangled_name = lb_get_entity_name(m, gen->info->entry_point);
				char const *str = alloc_cstring(temporary_allocator(), mangled_name);
				lb_add_raddbg_string(m, "entry_point: \"", str, "\"");
			}
		}
	}

	TIME_SECTION("LLVM Runtime Objective-C Names Creation");
	gen->objc_names = lb_create_objc_names(default_module);

	TIME_SECTION("LLVM Runtime Startup Creation (Global Variables & @(init))");
	gen->startup_runtime = lb_create_startup_runtime(default_module, gen->objc_names, global_variables);

	TIME_SECTION("LLVM Runtime Cleanup Creation & @(fini)");
	gen->cleanup_runtime = lb_create_cleanup_runtime(default_module);


	if (build_context.ODIN_DEBUG) {
		for (auto const &entry : builtin_pkg->scope->elements) {
			Entity *e = entry.value;
			lb_add_debug_info_for_global_constant_from_entity(gen, e);
		}
	}

	if (gen->modules.count <= 1) {
		do_threading = false;
	}

	TIME_SECTION("LLVM Global Procedures and Types");
	lb_create_global_procedures_and_types(gen, info, do_threading);

	TIME_SECTION("LLVM Procedure Generation");
	lb_generate_procedures(gen, do_threading);

	if (build_context.command_kind == Command_test && !already_has_entry_point) {
		TIME_SECTION("LLVM main");
		lb_create_main_procedure(default_module, gen->startup_runtime, gen->cleanup_runtime);
	}

	TIME_SECTION("LLVM Procedure Generation (missing)");
	lb_generate_missing_procedures(gen, do_threading);

	if (gen->objc_names) {
		TIME_SECTION("Finalize objc names");
		lb_finalize_objc_names(gen, gen->objc_names);
	}

	if (build_context.hot_reload) {
		TIME_SECTION("LLVM Hot Reload Support Symbols");
		lb_hot_reload_emit_support(gen);

		// Autowired pre/post-patch hooks (Live++-style). Baked into the exe and every
		// reload object; the loader calls the pre set (from the exe) before patching
		// and the post set (from the object) after, passing the changed-type set.
		lb_hot_reload_emit_patch_hook_table(gen, info, true,  "__odin_hot_reload_pre_patch_hooks");
		lb_hot_reload_emit_patch_hook_table(gen, info, false, "__odin_hot_reload_post_patch_hooks");

		// Change-detection baseline/delta: a per-procedure content-hash table so the loader
		// patches only procedures whose code actually changed (see lb_hot_reload_emit_func_hashes).
		// Emitted here, after all procedures are generated, so every proc is included.
		lb_hot_reload_emit_func_hashes(gen);

		// Build-identity fingerprint (F6): baked into the exe and every reload object; the
		// loader refuses a reload built against a different exe layout. Must run after
		// func-hash emission so the manifest's `sig` map (folded into the id) is complete.
		lb_hot_reload_emit_build_id(gen);

		// Emit the once-only init descriptor table for new globals (file-scope and
		// local `@(static)`) with constant initializers. Layout: { i64 count;
		// Entry[count] } where Entry = { i64 arena_offset; i64 flag_offset; i64 size;
		// rawptr blob }. The loader copies each blob into the arena once, gated by its
		// flag byte. Emitted here (after all procedures) so local statics are included.
		if (hot_reload_inits.count > 0) {
			lbModule *m = &gen->default_module;
			LLVMTypeRef i64t = lb_type(m, t_i64);
			LLVMTypeRef ptrt = lb_type(m, t_rawptr);
			LLVMTypeRef entry_field_types[4] = { i64t, i64t, i64t, ptrt };
			LLVMTypeRef entry_t = LLVMStructTypeInContext(m->ctx, entry_field_types, 4, false);

			auto entry_vals = array_make<LLVMValueRef>(temporary_allocator(), 0, hot_reload_inits.count);
			for (HotReloadInitEntry const &ie : hot_reload_inits) {
				LLVMValueRef fields[4] = {};
				fields[0] = LLVMConstInt(i64t, cast(u64)ie.arena_offset, false);
				fields[1] = LLVMConstInt(i64t, cast(u64)ie.flag_offset, false);
				fields[2] = LLVMConstInt(i64t, cast(u64)ie.size, false);
				fields[3] = LLVMConstPointerCast(ie.blob, ptrt);
				array_add(&entry_vals, LLVMConstStructInContext(m->ctx, fields, 4, false));
			}
			LLVMTypeRef arr_t = LLVMArrayType(entry_t, cast(unsigned)entry_vals.count);
			LLVMValueRef arr = LLVMConstArray(entry_t, entry_vals.data, cast(unsigned)entry_vals.count);

			LLVMTypeRef tbl_field_types[2] = { i64t, arr_t };
			LLVMTypeRef tbl_t = LLVMStructTypeInContext(m->ctx, tbl_field_types, 2, false);
			LLVMValueRef tbl_fields[2] = { LLVMConstInt(i64t, cast(u64)entry_vals.count, false), arr };
			LLVMValueRef tbl_val = LLVMConstStructInContext(m->ctx, tbl_fields, 2, false);

			LLVMValueRef tbl = LLVMAddGlobal(m->mod, tbl_t, "__odin_hot_reload_new_global_inits");
			LLVMSetInitializer(tbl, tbl_val);
			LLVMSetGlobalConstant(tbl, true);
			LLVMSetLinkage(tbl, LLVMInternalLinkage);
			lb_append_to_compiler_used(m, tbl); // the loader reads it by name; keep it from being stripped
		}

		// Emit the immutable-data ("refresh") symbol table for the loader: for each
		// @(rodata)/#load global, its {size, link name}. The loader looks each name up in
		// both the exe (PDB) and this reload object, then overwrites the exe's copy with
		// the object's fresh copy so edits to the data appear after a reload. Encoded as a
		// SELF-CONTAINED byte blob (no pointer relocations) so it can be read straight from
		// the mapped section: [ i64 count ] then per entry [ i64 size ][ i64 name_len ][ name bytes ].
		if (gen->hot_reload_refresh_syms.count > 0) {
			lbModule *m = &gen->default_module;
			auto buf = array_make<u8>(heap_allocator(), 0, 256);
			lb_hot_reload_put_u64_le(&buf, cast(u64)gen->hot_reload_refresh_syms.count);
			for (lbHotReloadRefreshSym const &rs : gen->hot_reload_refresh_syms) {
				lb_hot_reload_put_u64_le(&buf, cast(u64)rs.size);
				lb_hot_reload_put_u64_le(&buf, cast(u64)rs.name.len);
				for (isize i = 0; i < rs.name.len; i++) {
					array_add(&buf, rs.name.text[i]);
				}
			}
			LLVMValueRef blob = LLVMConstStringInContext(m->ctx, cast(char const *)buf.data, cast(unsigned)buf.count, true);
			LLVMValueRef tbl = LLVMAddGlobal(m->mod, LLVMTypeOf(blob), "__odin_hot_reload_refresh_syms");
			LLVMSetInitializer(tbl, blob);
			LLVMSetGlobalConstant(tbl, true);
			LLVMSetLinkage(tbl, LLVMInternalLinkage);
			LLVMSetAlignment(tbl, 8);
			lb_append_to_compiler_used(m, tbl); // the loader reads it by name; keep it from being stripped
			array_free(&buf);
		}

		// Persist the manifest: the base build records every original global (and local
		// static); a reload build additionally records the arena offsets it assigned to
		// new ones so the next reload reuses them (preserving state).
		hot_reload_manifest_write(&hot_reload_manifest);
		array_free(&hot_reload_inits);
		array_free(&gen->hot_reload_refresh_syms);
	}

	if (build_context.ODIN_DEBUG) {
		TIME_SECTION("LLVM Debug Info Complete Types and Finalize");
		lb_debug_info_complete_types_and_finalize(gen);

		// Custom `.raddbg` section for its debugger
		if (build_context.metrics.os == TargetOs_windows) {
			lbModule *m = default_module;
			LLVMModuleRef mod = m->mod;
			LLVMContextRef ctx = m->ctx;

			lb_add_raddbg_string(m, "type_view: {type: \"[]?\",        expr: \"array(data, len)\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"string\",     expr: \"array(data, len)\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"[dynamic]?\", expr: \"rows($, array(data, len), len, cap, allocator)\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"[dynamic;?]?\", expr: \"rows($, array(data, len), len)\"}");

			// column major matrices
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[1, ?]?\",  expr: \"columns($.data, $[0])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[2, ?]?\",  expr: \"columns($.data, $[0], $[1])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[3, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[4, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[5, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[6, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[7, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[8, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[9, ?]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[10, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[11, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[12, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[13, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[14, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[15, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13], $[14])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"matrix[16, ?]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13], $[14], $[15])\"}");

			// row major matrices
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 1]?\",  expr: \"columns($.data, $[0])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 2]?\",  expr: \"columns($.data, $[0], $[1])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 3]?\",  expr: \"columns($.data, $[0], $[1], $[2])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 4]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 5]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 6]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 7]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 8]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 9]?\",  expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 10]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 11]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 12]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 13]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 14]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 15]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13], $[14])\"}");
			lb_add_raddbg_string(m, "type_view: {type: \"#row_major matrix[?, 16]?\", expr: \"columns($.data, $[0], $[1], $[2], $[3], $[4], $[5], $[6], $[7], $[8], $[9], $[10], $[11], $[12], $[13], $[14], $[15])\"}");


			TEMPORARY_ALLOCATOR_GUARD();
			for (RaddbgTypeView const &type_view : gen->info->raddbg_type_views) {
				if (type_view.type == nullptr) {
					continue;
				}

				if (type_view.view.len == 0) {
					continue;
				}

				String t_str = type_to_canonical_string(temporary_allocator(), type_view.type);

				gbString s = gb_string_make(temporary_allocator(), "");

				s = gb_string_appendc(s, "type_view: {type: \"");
				s = gb_string_append_length(s, t_str.text, t_str.len);
				s = gb_string_appendc(s, "\", expr: \"");
				s = gb_string_append_length(s, type_view.view.text, type_view.view.len);
				s = gb_string_appendc(s, "\"}");

				lb_add_raddbg_string(m, s);
			}

			TEMPORARY_ALLOCATOR_GUARD();
			u32 global_name_index = 0;
			for (String str = {}; mpsc_dequeue(&gen->raddebug_section_strings, &str); /**/) {
				LLVMValueRef data = LLVMConstStringInContext(ctx, cast(char const *)str.text, cast(unsigned)str.len, false);
				LLVMTypeRef type = LLVMTypeOf(data);

				gbString global_name = gb_string_make(temporary_allocator(), "raddbg_data__");
				global_name = gb_string_append_fmt(global_name, "%u", global_name_index);
				global_name_index += 1;

				LLVMValueRef global = LLVMAddGlobal(mod, type, global_name);

				LLVMSetInitializer(global, data);
				LLVMSetAlignment(global, 1);

				LLVMSetSection(global, ".raddbg");
			}
		}
	}

	if (do_threading) {
		isize non_empty_module_count = 0;
		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			if (!lb_is_module_empty(m)) {
				non_empty_module_count += 1;
			}
		}
		if (non_empty_module_count <= 1) {
			do_threading = false;
		}
	}

	TIME_SECTION("LLVM Add Foreign Library Paths");
	lb_add_foreign_library_paths(gen);

	TIME_SECTION("LLVM Function Pass");
	lb_llvm_function_passes(gen, do_threading && !build_context.ODIN_DEBUG);

	TIME_SECTION("LLVM Remove Unused Functions and Globals");
	lb_remove_unused_functions_and_globals(gen);

	TIME_SECTION("LLVM Module Pass and Verification");
	lb_llvm_module_passes_and_verification(gen, do_threading);

	TIME_SECTION("LLVM Correct Entity Linkage");
	lb_correct_entity_linkage(gen);

	if (build_context.build_diagnostics) {
		lb_do_build_diagnostics(gen);
	}

	llvm_error = nullptr;
	defer (LLVMDisposeMessage(llvm_error));

	if (build_context.keep_temp_files ||
	    build_context.build_mode == BuildMode_LLVM_IR) {
		TIME_SECTION("LLVM Print Module to File");

		for (auto const &entry : gen->modules) {
			lbModule *m = entry.value;
			if (lb_is_module_empty(m)) {
				continue;
			}
			String filepath_ll = lb_filepath_ll_for_module(m);
			if (LLVMPrintModuleToFile(m->mod, cast(char const *)filepath_ll.text, &llvm_error)) {
				gb_printf_err("LLVM Error: %s\n", llvm_error);
				exit_with_errors();
				return false;
			}
			array_add(&gen->output_temp_paths, filepath_ll);

		}
		if (build_context.build_mode == BuildMode_LLVM_IR) {
			return true;
		}
	}


	////////////////////////////////////////////
	for (auto const &entry: gen->modules) {
		lbModule *m = entry.value;
		if (!lb_is_module_empty(m)) {
			gen->used_module_count += 1;
		}
	}

	gbString label_object_generation = gb_string_make(heap_allocator(), "LLVM Object Generation");
	if (gen->used_module_count > 1) {
		label_object_generation = gb_string_append_fmt(label_object_generation, " (%td used modules)", gen->used_module_count);
	}
	TIME_SECTION_WITH_LEN(label_object_generation, gb_string_length(label_object_generation));
	
	if (build_context.ignore_llvm_build) {
		gb_printf_err("LLVM object generation has been ignored!\n");
		return false;
	}
	if (!lb_llvm_object_generation(gen, do_threading)) {
		return false;
	}


	if (build_context.sanitizer_flags & SanitizerFlag_Address) {
		switch (build_context.metrics.os) {
		case TargetOs_windows: {
			auto paths = array_make<String>(heap_allocator(), 0, 1);
			String path = concatenate_strings(permanent_allocator(), build_context.ODIN_ROOT, str_lit("\\bin\\llvm\\windows\\clang_rt.asan-x86_64.lib"));
			array_add(&paths, path);
			Entity *lib = alloc_entity_library_name(nullptr, make_token_ident("asan_lib"), nullptr, slice_from_array(paths), str_lit("asan_lib"));
			array_add(&gen->foreign_libraries, lib);
		} break;
		case TargetOs_darwin:
		case TargetOs_linux:
		case TargetOs_freebsd:
			if (!build_context.extra_linker_flags.text) {
				build_context.extra_linker_flags = str_lit("-fsanitize=address");
			} else {
				build_context.extra_linker_flags = concatenate_strings(permanent_allocator(), build_context.extra_linker_flags, str_lit(" -fsanitize=address"));
			}
			break;
		}
	}
	if (build_context.sanitizer_flags & SanitizerFlag_Memory) {
		switch (build_context.metrics.os) {
		case TargetOs_linux:
		case TargetOs_freebsd:
			if (!build_context.extra_linker_flags.text) {
				build_context.extra_linker_flags = str_lit("-fsanitize=memory");
			} else {
				build_context.extra_linker_flags = concatenate_strings(permanent_allocator(), build_context.extra_linker_flags, str_lit(" -fsanitize=memory"));
			}
			break;
		}
	}
	if (build_context.sanitizer_flags & SanitizerFlag_Thread) {
		switch (build_context.metrics.os) {
		case TargetOs_darwin:
		case TargetOs_linux:
		case TargetOs_freebsd:
			if (!build_context.extra_linker_flags.text) {
				build_context.extra_linker_flags = str_lit("-fsanitize=thread");
			} else {
				build_context.extra_linker_flags = concatenate_strings(permanent_allocator(), build_context.extra_linker_flags, str_lit(" -fsanitize=thread"));
			}
			break;
		}
	}

	array_sort(gen->foreign_libraries, foreign_library_cmp);

	return true;
}
