package test_core_thread

import "core:testing"
import "core:thread"
import "base:intrinsics"
import "base:runtime"

@(test)
poly_data_test :: proc(_t: ^testing.T) {
	MAX :: size_of(rawptr) * thread.MAX_USER_ARGUMENTS

	@static poly_data_test_t: ^testing.T
	poly_data_test_t = _t

	b: [MAX]byte = 8
	t1 := thread.create_and_start_with_poly_data(b, proc(b: [MAX]byte) {
		b_expect: [MAX]byte = 8
		testing.expect(poly_data_test_t, b == b_expect, "thread poly data not correct")
	})
	defer free(t1)

	b1: [3]uintptr = 1
	b2: [MAX / 2]byte = 3
	t2 := thread.create_and_start_with_poly_data2(b1, b2, proc(b: [3]uintptr, b2: [MAX / 2]byte) {
		b_expect: [3]uintptr = 1
		b2_expect: [MAX / 2]byte = 3
		testing.expect(poly_data_test_t, b == b_expect,   "thread poly data not correct")
		testing.expect(poly_data_test_t, b2 == b2_expect, "thread poly data not correct")
	})
	defer free(t2)

	t3 := thread.create_and_start_with_poly_data3(b1, b2, uintptr(333), proc(b: [3]uintptr, b2: [MAX / 2]byte, b3: uintptr) {
		b_expect: [3]uintptr = 1
		b2_expect: [MAX / 2]byte = 3

		testing.expect(poly_data_test_t, b == b_expect,   "thread poly data not correct")
		testing.expect(poly_data_test_t, b2 == b2_expect, "thread poly data not correct")
		testing.expect(poly_data_test_t, b3 == 333,       "thread poly data not correct")
	})
	defer free(t3)

	t4 := thread.create_and_start_with_poly_data4(uintptr(111), b1, uintptr(333), u8(5), proc(n: uintptr, b: [3]uintptr, n2: uintptr, n4: u8) {
		b_expect: [3]uintptr = 1

		testing.expect(poly_data_test_t, n == 111,        "thread poly data not correct")
		testing.expect(poly_data_test_t, b == b_expect,   "thread poly data not correct")
		testing.expect(poly_data_test_t, n2 == 333,       "thread poly data not correct")
		testing.expect(poly_data_test_t, n4 == 5,         "thread poly data not correct")
	})
	defer free(t4)

	thread.join_multiple(t1, t2, t3, t4)
}

@(test)
test_pool_resets_temp_allocator_between_tasks :: proc(t: ^testing.T) {
	TASKS :: 10
	@static max_leftover: uint
	intrinsics.atomic_store(&max_leftover, 0)

	task :: proc(task: thread.Task) {
		// detect leftover temp allocations
		leftover := runtime.global_default_temp_allocator_data.arena.total_used
		for {
			cur := intrinsics.atomic_load(&max_leftover)
			if leftover <= cur || intrinsics.atomic_compare_exchange_strong(&max_leftover, cur, leftover) == cur {
				break
			}
		}
		_ = make([]byte, 1000, context.temp_allocator)
	}

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, 1)
	defer thread.pool_destroy(&pool)
	thread.pool_start(&pool)
	for i in 0..<TASKS {
		thread.pool_add_task(&pool, context.allocator, task, nil, i)
	}
	for thread.pool_num_done(&pool) < TASKS {
		thread.yield()
	}
	thread.pool_finish(&pool)

	testing.expect_value(t, intrinsics.atomic_load(&max_leftover), 0)
}

@(test)
name_test :: proc(_t: ^testing.T) {
	@static name_test_t: ^testing.T
	@static main_wait := true
	@static child_wait := true
	name_test_t = _t

	t := thread.create_and_start(name = "test_name", fn = proc() {
		intrinsics.atomic_store(&main_wait, false)

		for intrinsics.atomic_load(&child_wait) {}

		n, err  := thread.get_name()
		defer if err != nil {
			delete(n)
		}
		testing.expect(name_test_t, err == nil, "thread name allocation failed")
		testing.expectf(name_test_t, n == "test_name","thread name on self did not match : got %v", n)

	})
	defer free(t)

	for intrinsics.atomic_load(&main_wait) {}

	n, err := thread.get_name(t)
	defer if err != nil {
		delete(n)
	}
	testing.expect(name_test_t, err == nil, "thread name allocation failed")
	testing.expectf(name_test_t, n == "test_name","thread name on main did not match : got %v", n)

	intrinsics.atomic_store(&child_wait, false)

	thread.join(t)
}
