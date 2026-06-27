--[[
	not mine
]]
local src = "ByteCode.luac"
local dst = "DecompiledOutput.lua"

local function shr(val, n)
	return math.floor(val / 2 ^ n)
end

local function band(a, b)
	local pos, res = 1, 0
	while a > 0 and b > 0 do
		local ra = a % 2
		local rb = b % 2
		if ra + rb > 1 then
			res += pos
		end
		a = (a - ra) / 2
		b = (b - rb) / 2
		pos *= 2
	end
	return res
end

local ops = {
	MOVE = 0, LOADK = 1, LOADBOOL = 2, LOADNIL = 3,
	GETUPVAL = 4, GETGLOBAL = 5, GETTABLE = 6, SETGLOBAL = 7,
	SETUPVAL = 8, SETTABLE = 9, NEWTABLE = 10, SELF = 11,
	ADD = 12, SUB = 13, MUL = 14, DIV = 15, MOD = 16, POW = 17,
	UNM = 18, NOT = 19, LEN = 20, CONCAT = 21, JMP = 22,
	EQ = 23, LT = 24, LE = 25, TEST = 26, TESTSET = 27,
	CALL = 28, TAILCALL = 29, RETURN = 30, FORLOOP = 31,
	FORPREP = 32, TFORLOOP = 33, SETLIST = 34, CLOSE = 35,
	CLOSURE = 36, VARARG = 37
}

local opN = {}
for k, v in pairs(ops) do
	opN[v] = k
end

local Reader = {}
Reader.__index = Reader

function Reader.new(data: string)
	return setmetatable({ data = data, pos = 1, le = true, isize = 4, ssize = 4 }, Reader)
end

function Reader:byte()
	local b = self.data:byte(self.pos)
	self.pos += 1
	return b
end

function Reader:bytes(n: number)
	local t = {}
	for i = 1, n do
		local b = self:byte()
		if not b then return nil end
		t[i] = b
	end
	return t
end

function Reader:int(size: number)
	local t = self:bytes(size)
	if not t then return nil end
	local acc = 0
	if self.le then
		for i = 1, size do
			acc += t[i] * (2 ^ ((i - 1) * 8))
		end
	else
		for i = 1, size do
			acc += t[i] * (2 ^ ((size - i) * 8))
		end
	end
	return acc
end

function Reader:readInt()
	return self:int(self.isize)
end

function Reader:readSize()
	return self:int(self.ssize)
end

function Reader:readNum()
	local t = self:bytes(8)
	if not t then return 0 end
	if not self.le then
		local r = {}
		for i = 8, 1, -1 do r[9 - i] = t[i] end
		t = r
	end
	local sign = (t[8] > 127) and -1 or 1
	local exp = band(t[8], 127) * 16 + shr(t[7], 4)
	local mant = band(t[7], 15)
	for i = 6, 1, -1 do
		mant = mant * 256 + t[i]
	end
	if exp == 0 then
		return (mant == 0) and 0 or sign * mant * 3.4175792574734563e-227
	elseif exp == 2047 then
		return (mant == 0) and sign * (1 / 0) or 0 / 0
	end
	return sign * (1 + mant / (2 ^ 52)) * (2 ^ (exp - 1023))
end

function Reader:readStr()
	local len = self:readSize()
	if not len or len == 0 then return nil end
	local s = self.data:sub(self.pos, self.pos + len - 2)
	self.pos += len
	return s
end

local function readHdr(r)
	assert(r:byte() == 27 and r:byte() == 76 and r:byte() == 117 and r:byte() == 97, "bad bytecode")
	r:byte()
	r:byte()
	local endian = r:byte()
	r.le = (endian == 1)
	r.isize = r:byte()
	r.ssize = r:byte()
	r:byte()
	r:byte()
	r:byte()
end

local fnId = 0

local function readFn(r, parent)
	fnId += 1
	local fn = {
		id = fnId,
		src = r:readStr(),
		lineStart = r:readInt(),
		lineEnd = r:readInt(),
		nups = r:byte(),
		nparams = r:byte(),
		vararg = r:byte(),
		maxstack = r:byte(),
		instrs = {},
		consts = {},
		children = {}
	}

	local nc = r:readInt()
	for i = 1, nc do
		local raw = r:readInt()
		local op = raw % 64
		local a = math.floor(raw / 64) % 256
		local c = math.floor(raw / 16384) % 512
		local b = math.floor(raw / 8388608) % 512
		local bx = math.floor(raw / 16384) % 262144
		fn.instrs[i] = { opcode = op, a = a, b = b, c = c, bx = bx, sbx = bx - 131071 }
	end

	local nk = r:readInt()
	for i = 1, nk do
		local t = r:byte()
		if t == 0 then
			fn.consts[i] = { t = "nil" }
		elseif t == 1 then
			fn.consts[i] = { t = "bool", v = r:byte() ~= 0 }
		elseif t == 3 then
			fn.consts[i] = { t = "num", v = r:readNum() }
		elseif t == 4 then
			fn.consts[i] = { t = "str", v = r:readStr() }
		end
	end

	local nch = r:readInt()
	for i = 1, nch do
		fn.children[i] = readFn(r, fn)
	end

	local nli = r:readInt()
	for i = 1, nli do r:readInt() end

	local nlv = r:readInt()
	for i = 1, nlv do
		r:readStr(); r:readInt(); r:readInt()
	end

	local nuv = r:readInt()
	for i = 1, nuv do r:readStr() end

	return fn
end

local function rname(idx: number, fid: number): string
	return "r" .. idx .. "f" .. (fid or 0)
end

local function kstr(k): string
	if k.t == "nil" then return "nil"
	elseif k.t == "bool" then return k.v and "true" or "false"
	elseif k.t == "num" then return tostring(k.v)
	elseif k.t == "str" then return string.format("%q", k.v)
	end
	return "nil"
end

local function isid(name: string): boolean
	return name:match("^[%a_][%w_]*$") ~= nil
end

local function emit(ctx, line: string)
	local pad = string.rep("  ", ctx.indent)
	table.insert(ctx.lines, pad .. line)
end

local function greg(ctx, i: number): string
	if not ctx.regs[i] then
		ctx.regs[i] = rname(i, ctx.fn.id)
	end
	return ctx.regs[i]
end

local function gexp(ctx, i: number): string
	return ctx.exprs[i] or greg(ctx, i)
end

local function sexp(ctx, i: number, expr)
	ctx.exprs[i] = expr
end

local function grk(ctx, rk: number): string
	if rk < 256 then
		return gexp(ctx, rk)
	else
		return kstr(ctx.fn.consts[rk - 256 + 1])
	end
end

local function gupv(ctx, idx: number): string
	return "upv" .. idx
end

local function flow(fn)
	local instrs = fn.instrs
	local bounds = {}
	for pc = 1, #instrs do
		local ins = instrs[pc]
		if ins.opcode == ops.EQ or ins.opcode == ops.LT or ins.opcode == ops.LE
			or ins.opcode == ops.TEST or ins.opcode == ops.TESTSET then
			local nxt = instrs[pc + 1]
			if nxt and nxt.opcode == ops.JMP then
				local tgt = pc + 2 + nxt.sbx
				if not bounds[tgt] then bounds[tgt] = {} end
				table.insert(bounds[tgt], "cond")
			else
				if not bounds[pc + 2] then bounds[pc + 2] = {} end
				table.insert(bounds[pc + 2], "cond")
			end
		end
		if ins.opcode == ops.FORPREP then
			local tgt = pc + 1 + ins.sbx + 1
			if not bounds[tgt] then bounds[tgt] = {} end
			table.insert(bounds[tgt], "loop")
		end
	end
	return { bounds = bounds }
end

local function mkctx(fn, parent)
	return {
		fn = fn,
		parent = parent,
		exprs = {},
		regs = {},
		declared = {},
		selfInfo = nil,
		tables = {},
		closures = {},
		indent = 0,
		lines = {},
		flow = flow(fn)
	}
end

local function btbl(ctx, reg: number, ind: number): string
	local ti = ctx.tables[reg]
	if not ti then return "{}" end
	local parts = {}
	for _, e in ipairs(ti.entries) do
		if e.safeKey then
			table.insert(parts, e.key .. " = " .. e.val)
		else
			table.insert(parts, "[" .. e.key .. "] = " .. e.val)
		end
	end
	for _, v in ipairs(ti.arr) do
		table.insert(parts, v)
	end
	if #parts == 0 then return "{}" end
	if #parts <= 3 and not ti.hasFuncs then
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	local out = {"{"}
	for _, p in ipairs(parts) do
		table.insert(out, string.rep("  ", ind + 1) .. p .. ",")
	end
	table.insert(out, string.rep("  ", ind) .. "}")
	return table.concat(out, "\n")
end

local function cani(ctx, reg: number): boolean
	return false
end

local recon

local function inlf(ctx, proto, ind: number): string
	local child = mkctx(proto, ctx)
	child.indent = 0
	recon(child, proto)
	local lines = {}
	for _, l in ipairs(child.lines) do
		table.insert(lines, l)
	end
	return "function(...)\n" .. table.concat(lines, "\n") .. "\nend"
end

recon = function(ctx, fn)
	local instrs = fn.instrs
	local pc = 1
	local flow = ctx.flow

	while pc <= #instrs do
		if flow.bounds[pc] then
			for _ in ipairs(flow.bounds[pc]) do
				ctx.indent = math.max(0, ctx.indent - 1)
				emit(ctx, "end")
			end
		end

		local ins = instrs[pc]
		local op = ins.opcode
		local a = ins.a
		local b = ins.b
		local c = ins.c
		local bx = ins.bx
		local sbx = ins.sbx

		if op == ops.MOVE then
			sexp(ctx, a, gexp(ctx, b))

		elseif op == ops.LOADK then
			sexp(ctx, a, kstr(fn.consts[bx + 1]))

		elseif op == ops.LOADBOOL then
			sexp(ctx, a, b ~= 0 and "true" or "false")
			if c ~= 0 then pc += 1 end

		elseif op == ops.LOADNIL then
			for i = a, b do
				sexp(ctx, i, "nil")
			end

		elseif op == ops.GETUPVAL then
			sexp(ctx, a, gupv(ctx, b))

		elseif op == ops.GETGLOBAL then
			sexp(ctx, a, fn.consts[bx + 1].v)

		elseif op == ops.GETTABLE then
			local obj = gexp(ctx, b)
			local key = grk(ctx, c)
			if c >= 256 then
				local ck = fn.consts[c - 256 + 1]
				if ck.t == "str" and isid(ck.v) then
					sexp(ctx, a, obj .. "." .. ck.v)
				else
					sexp(ctx, a, obj .. "[" .. key .. "]")
				end
			else
				sexp(ctx, a, obj .. "[" .. key .. "]")
			end

		elseif op == ops.SETGLOBAL then
			emit(ctx, fn.consts[bx + 1].v .. " = " .. gexp(ctx, a))

		elseif op == ops.SETUPVAL then
			emit(ctx, gupv(ctx, b) .. " = " .. gexp(ctx, a))

		elseif op == ops.SETTABLE then
			local keyRef = grk(ctx, b)
			local valRef = c < 256 and ctx.closures[c] or nil
			if not valRef then valRef = grk(ctx, c) end
			if c < 256 then ctx.closures[c] = nil end

			if ctx.tables[a] then
				local safeK = false
				local kName = keyRef
				if b >= 256 then
					local ck = fn.consts[b - 256 + 1]
					if ck.t == "str" and isid(ck.v) then
						safeK = true
						kName = ck.v
					end
				end
				if valRef:match("^function%(") then
					ctx.tables[a].hasFuncs = true
				end
				table.insert(ctx.tables[a].entries, { key = kName, val = valRef, safeKey = safeK })
			else
				local obj = gexp(ctx, a)
				local tgt
				if b >= 256 then
					local ck = fn.consts[b - 256 + 1]
					if ck.t == "str" and isid(ck.v) then
						tgt = obj .. "." .. ck.v
					else
						tgt = obj .. "[" .. keyRef .. "]"
					end
				else
					tgt = obj .. "[" .. keyRef .. "]"
				end
				emit(ctx, tgt .. " = " .. valRef)
			end

		elseif op == ops.NEWTABLE then
			ctx.tables[a] = { entries = {}, arr = {}, hasFuncs = false }
			sexp(ctx, a, nil)

		elseif op == ops.SELF then
			local obj = gexp(ctx, b)
			local mname = nil
			if c >= 256 then
				local cm = fn.consts[c - 256 + 1]
				if cm.t == "str" then mname = cm.v end
			end
			ctx.selfInfo = { obj = obj, method = mname, raw = grk(ctx, c) }
			sexp(ctx, a + 1, obj)
			if mname and isid(mname) then
				sexp(ctx, a, obj .. ":" .. mname)
			else
				sexp(ctx, a, obj .. "[" .. ctx.selfInfo.raw .. "]")
			end

		elseif op >= ops.ADD and op <= ops.POW then
			local opMap = {
				[ops.ADD] = "+", [ops.SUB] = "-", [ops.MUL] = "*",
				[ops.DIV] = "/", [ops.MOD] = "%", [ops.POW] = "^"
			}
			sexp(ctx, a, grk(ctx, b) .. " " .. opMap[op] .. " " .. grk(ctx, c))

		elseif op == ops.UNM then
			sexp(ctx, a, "-" .. gexp(ctx, b))

		elseif op == ops.NOT then
			sexp(ctx, a, "not " .. gexp(ctx, b))

		elseif op == ops.LEN then
			sexp(ctx, a, "#" .. gexp(ctx, b))

		elseif op == ops.CONCAT then
			local parts = {}
			for i = b, c do
				table.insert(parts, gexp(ctx, i))
			end
			sexp(ctx, a, table.concat(parts, " .. "))

		elseif op == ops.JMP then

		elseif op == ops.EQ or op == ops.LT or op == ops.LE then
			local cmpOp
			if op == ops.EQ then
				cmpOp = (a ~= 0) and "~=" or "=="
			elseif op == ops.LT then
				cmpOp = (a ~= 0) and ">=" or "<"
			else
				cmpOp = (a ~= 0) and ">" or "<="
			end
			emit(ctx, "if " .. grk(ctx, b) .. " " .. cmpOp .. " " .. grk(ctx, c) .. " then")
			ctx.indent += 1

		elseif op == ops.TEST then
			local cond = (c == 0) and "not " .. gexp(ctx, a) or gexp(ctx, a)
			emit(ctx, "if " .. cond .. " then")
			ctx.indent += 1

		elseif op == ops.TESTSET then
			local cond = (c == 0) and "not " .. gexp(ctx, b) or gexp(ctx, b)
			sexp(ctx, a, gexp(ctx, b))
			emit(ctx, "if " .. cond .. " then")
			ctx.indent += 1

		elseif op == ops.CALL then
			local fnExpr
			local args = {}

			if ctx.selfInfo then
				local si = ctx.selfInfo
				if si.method and isid(si.method) then
					fnExpr = si.obj .. ":" .. si.method
				else
					fnExpr = si.obj .. "[" .. si.raw .. "]"
				end
				if b > 2 then
					for i = a + 2, a + b - 1 do
						local ae = gexp(ctx, i)
						if ctx.tables[i] then ae = btbl(ctx, i, ctx.indent); ctx.tables[i] = nil end
						if ctx.closures[i] then ae = ctx.closures[i]; ctx.closures[i] = nil end
						table.insert(args, ae)
					end
				elseif b == 0 then
					local ae = gexp(ctx, a + 1)
					if ae and ae ~= rname(a + 1, ctx.fn.id) then
						table.insert(args, ae)
					end
				end
				ctx.selfInfo = nil
			else
				fnExpr = gexp(ctx, a)
				if b > 1 then
					for i = a + 1, a + b - 1 do
						local ae = gexp(ctx, i)
						if ctx.tables[i] then ae = btbl(ctx, i, ctx.indent); ctx.tables[i] = nil end
						if ctx.closures[i] then ae = ctx.closures[i]; ctx.closures[i] = nil end
						table.insert(args, ae)
					end
				elseif b == 0 then
					local ae = gexp(ctx, a + 1)
					if ae and ae ~= rname(a + 1, ctx.fn.id) then
						table.insert(args, ae)
					end
				end
			end

			local call = fnExpr .. "(" .. table.concat(args, ", ") .. ")"

			if c == 0 then
				sexp(ctx, a, call)
			elseif c == 1 then
				emit(ctx, call)
			elseif c == 2 then
				local rn = greg(ctx, a)
				if not ctx.declared[a] then
					ctx.declared[a] = true
					emit(ctx, "local " .. rn .. " = " .. call)
				else
					emit(ctx, rn .. " = " .. call)
				end
				sexp(ctx, a, rn)
				ctx.regs[a] = rn
			else
				local rets = {}
				for i = a, a + c - 2 do
					local rn = greg(ctx, i)
					table.insert(rets, rn)
					ctx.declared[i] = true
					sexp(ctx, i, rn)
					ctx.regs[i] = rn
				end
				emit(ctx, "local " .. table.concat(rets, ", ") .. " = " .. call)
			end

		elseif op == ops.TAILCALL then
			local fe = gexp(ctx, a)
			local targs = {}
			if b > 1 then
				for i = a + 1, a + b - 1 do
					table.insert(targs, gexp(ctx, i))
				end
			end
			emit(ctx, "return " .. fe .. "(" .. table.concat(targs, ", ") .. ")")

		elseif op == ops.RETURN then
			if b == 1 then
				emit(ctx, "return")
			elseif b == 2 then
				emit(ctx, "return " .. gexp(ctx, a))
			else
				local rets = {}
				for i = a, a + b - 2 do
					table.insert(rets, gexp(ctx, i))
				end
				emit(ctx, "return " .. table.concat(rets, ", "))
			end

		elseif op == ops.FORLOOP then

		elseif op == ops.FORPREP then
			emit(ctx, "for " .. greg(ctx, a + 3) .. " = " ..
				gexp(ctx, a) .. ", " ..
				gexp(ctx, a + 1) .. ", " ..
				gexp(ctx, a + 2) .. " do")
			ctx.indent += 1
			ctx.declared[a + 3] = true

		elseif op == ops.TFORLOOP then
			local ivars = {}
			for i = a + 3, a + 2 + c do
				table.insert(ivars, greg(ctx, i))
				ctx.declared[i] = true
			end
			emit(ctx, "for " .. table.concat(ivars, ", ") .. " in " .. gexp(ctx, a) .. " do")
			ctx.indent += 1

		elseif op == ops.SETLIST then
			if ctx.tables[a] then
				for i = 1, b do
					table.insert(ctx.tables[a].arr, gexp(ctx, a + i))
				end
			end

		elseif op == ops.CLOSURE then
			local proto = fn.children[bx + 1]
			local params = {}
			for i = 0, proto.nparams - 1 do
				table.insert(params, rname(i, proto.id))
			end
			if proto.vararg ~= 0 then
				table.insert(params, "...")
			end

			if cani(ctx, a) then
				local code = inlf(ctx, proto, ctx.indent)
				ctx.closures[a] = code
				sexp(ctx, a, code)
			else
				local nextIns = instrs[pc + 1]
				local isNamed = nextIns and nextIns.opcode == ops.SETGLOBAL and nextIns.a == a
				local fname = isNamed and fn.consts[nextIns.bx + 1].v or nil
				if fname and not isid(fname) then fname = nil; isNamed = false end

				if isNamed then
					emit(ctx, "function " .. fname .. "(" .. table.concat(params, ", ") .. ")")
				else
					emit(ctx, "local " .. greg(ctx, a) .. " = function(" .. table.concat(params, ", ") .. ")")
					ctx.declared[a] = true
				end

				local child = mkctx(proto, ctx)
				child.indent = ctx.indent + 1
				recon(child, proto)
				for _, l in ipairs(child.lines) do
					table.insert(ctx.lines, l)
				end

				emit(ctx, "end")
				sexp(ctx, a, greg(ctx, a))

				if isNamed then pc += 1 end
			end
			pc += proto.nups

		elseif op == ops.CLOSE then

		elseif op == ops.VARARG then
			if b == 0 then
				sexp(ctx, a, "...")
			else
				local vargs = {}
				for i = a, a + b - 2 do
					table.insert(vargs, greg(ctx, i))
					ctx.declared[i] = true
				end
				emit(ctx, "local " .. table.concat(vargs, ", ") .. " = ...")
			end
		end

		pc += 1
	end
end

local function conv(src: string): string
	local lines = src:split("\n")
	local out = {}

	for i, line in ipairs(lines) do
		local pad = line:match("^(%s*)")
		local code = line:sub(#pad + 1)

		code = code:gsub("math%.floor%((.-)%s*/%s*(.-)%)", "(%1 // %2)")
		code = code:gsub("string%.len%((.-)%)", "#%1")
		code = code:gsub("table%.getn%((.-)%)", "#%1")
		code = code:gsub("type%((.-)%)%s*==%s*\"(.-)\"", "typeof(%1) == \"%2\"")
		code = code:gsub("for%s+(.-)%s+in%s+pairs%((.-)%)", "for %1 in %2")
		code = code:gsub("for%s+(.-)%s+in%s+ipairs%((.-)%)", "for %1 in %2")

		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%+%s*(.+)$", "%1 += %2")
		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%-%s*(.+)$", "%1 -= %2")
		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%*%s*(.+)$", "%1 *= %2")
		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%/%s*(.+)$", "%1 /= %2")
		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%%%s*(.+)$", "%1 %%= %2")
		code = code:gsub("^([%w%.%[%]]+)%s*=%s*%1%s*%.%.%s*(.+)$", "%1 ..= %2")

		table.insert(out, pad .. code)
	end

	return table.concat(out, "\n")
end

local raw = readfile(src)
local reader = Reader.new(raw)
readHdr(reader)
local mfn = readFn(reader, nil)

local ctx = mkctx(mfn, nil)
recon(ctx, mfn)

local lout = table.concat(ctx.lines, "\n")
local uout = conv(lout)

writefile("output.luac", lout)
writefile("output.luau", uout)
