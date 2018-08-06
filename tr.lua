
--Unicode text shaping and rendering.
--Written by Cosmin Apreutesei. Public Domain.

if not ... then require'tr_demo'; return end

local bit = require'bit'
local ffi = require'ffi'
local utf8 = require'utf8'
local hb = require'harfbuzz'
local fb = require'fribidi'
local ub = require'libunibreak'
local ft = require'freetype'
local glue = require'glue'
local box2d = require'box2d'
local lrucache = require'lrucache'
local xxhash64 = require'xxhash'.hash64
local detect_scripts = require'tr_shape_script'
local reorder_runs = require'tr_shape_reorder'
local zone = require'jit.zone' --glue.noop

local band = bit.band
local push = table.insert
local update = glue.update
local assert = glue.assert --assert with string formatting
local count = glue.count
local clamp = glue.clamp
local snap = glue.snap
local binsearch = glue.binsearch
local bounding_box = box2d.bounding_box
local hit_box = box2d.hit
local odd = function(x) return band(x, 1) == 1 end

--iterate a list of values in run-length encoded form.
local function pass(t, i) return t[i] end
local function runs(t, len, start, run_value)
	run_value = run_value or pass
	len = len + start
	local i = start
	return function()
		if i >= len then
			return nil
		end
		local i1, n, val1 = i, 1, run_value(t, i)
		while true do
			i = i + 1
			if i >= len then
				return i1, n, val1
			end
			local val = run_value(t, i)
			if val ~= val1 then
				return i1, n, val1
			end
			n = n + 1
		end
	end
end

local tr = {}
setmetatable(tr, tr)

tr.glyph_run_cache_size = 1024^2 * 10 --10MB net (arbitrary default)

tr.rasterizer_module = 'tr_raster_cairo' --who does rs:paint_glyph()

function tr:create_rasterizer()
	return require(self.rasterizer_module)()
end

function tr:__call()
	self = update({}, self)

	self.rs = self:create_rasterizer()

	self.glyph_runs = lrucache{max_size = self.glyph_run_cache_size}
	function self.glyph_runs:value_size(glyph_run)
		return glyph_run.mem_size
	end
	function self.glyph_runs:free_value(glyph_run)
		glyph_run:free()
	end

	return self
end

function tr:free()
	self.glyph_runs:free()
	self.glyph_runs = false

	self.rs:free()
	self.rs = false
end

local function override_font(font)
	local inherited = font.load
	function font:load()
		inherited(self)
		assert(not self.hb_font)
		self.hb_font = assert(hb.ft_font(self.ft_face, nil))
		self.hb_font:set_ft_load_flags(self.ft_load_flags)
	end
	local inherited = font.unload
	function font:unload()
		self.hb_font:free()
		self.hb_font = false
		inherited(self)
	end
	function font:size_changed()
		self.hb_font:ft_changed()
	end
	return font
end

function tr:add_font_file(...)
	return override_font(self.rs:add_font_file(...))
end

function tr:add_mem_font(...)
	return override_font(self.rs:add_mem_font(...))
end

--convert a Lua table into an array of hb_feature_t.
local function hb_feature_list(features)
	local feats_count = count(features)
	if feats_count == 0 then return nil end
	local feats = ffi.new('hb_feature_t[?]', feats_count)
	local i = 0
	for k,v in pairs(features) do
		assert(hb.feature(k, #k, feats[i]) == 1)
		feats[i].value = v
		i = i + 1
	end
	return feats, feats_count
end

--convert a tree of nested text runs into a flat list of runs with properties
--dynamically inherited from the parent nodes.
local function flatten_text_tree(parent, runs)
	for _,run_or_text in ipairs(parent) do
		local run
		if type(run_or_text) == 'string' and #run_or_text > 0 then
			run = {text = run_or_text}
			push(runs, run)
		else
			run = run_or_text
			flatten_text_tree(run, runs)
		end
		--TODO: make features individually inheritable.
		if run.features then
			run.features, run.feat_count = hb_feature_list(run.features)
		end
		run.__index = parent
		setmetatable(run, run)
	end
	return runs
end

--static, auto-growing temp buffers used for shaping.

local len0 = 0

local function realloc(var, ctype, len)
	if len > len0 then
		return ffi.new(ctype, len)
	else
		return var
	end
end

local
	str, scripts, langs,
	bidi_types, bracket_types, levels, vstr,
	linebreaks

local tr_free = tr.free
function tr:free()
	str, scripts, langs,
	bidi_types, bracket_types, levels, vstr,
	linebreaks = nil
	tr_free(self)
end

--shaping of a single text run into an array of glyphs

local glyph_run = {} --glyph run methods
tr.glyph_run_class = glyph_run

function glyph_run:free()
	self.hb_buf:free()
	self.hb_buf = false
	self.font:unref()
	self.font = false
end

function glyph_run:glyphs()

	local hb_buf = self.hb_buf

	local glyph_count = hb_buf:get_length()
	local glyph_info  = hb_buf:get_glyph_infos()
	local glyph_pos   = hb_buf:get_glyph_positions()

	local i = -1
	return function()
		i = i + 1
		if i == glyph_count then
			return nil
		end

		local glyph_index = glyph_info[i].codepoint

		--glyph origin relative to the start of the run.
		local px = glyph_pos[i].x_offset / 64
		local py = glyph_pos[i].y_offset / 64

		return i, glyph_index, px, py
	end
end

function glyph_run:glyph_metrics(glyph_index)
	return self.tr.rs:glyph_metrics(self.font, self.font_size, glyph_index)
end

local hb_glyph_size =
	ffi.sizeof'hb_glyph_info_t'
	+ ffi.sizeof'hb_glyph_position_t'

local function isnewline(c)
	return c == 10 or c == 13
end

function tr:shape_text_run(
	vstr, vstr_i, len,
	font, font_size, features, feat_count, rtl, script, lang
)
	font:ref()
	font:setsize(font_size)

	local hb_buf = hb.buffer()

	local dir = rtl and hb.C.HB_DIRECTION_RTL or hb.C.HB_DIRECTION_LTR
	hb_buf:set_direction(dir)
	hb_buf:set_script(script)
	hb_buf:set_language(lang)

	--ignore trailing line breaks, if any
	for i = len-1, 0, -1 do
		if isnewline(vstr[vstr_i+i]) then
			len = len - 1
		end
	end

	hb_buf:add_utf32(vstr + vstr_i, len)

	zone'hb_shape_full'
	hb_buf:shape_full(font.hb_font, features, feat_count)
	zone()

	local glyph_count = hb_buf:get_length()
	local glyph_info  = hb_buf:get_glyph_infos()
	local glyph_pos   = hb_buf:get_glyph_positions()

	zone'hb_shape_metrics'
	local bx, by, bw, bh = 0, 0, 0, 0 --bounding box
	local ax, ay = 0, 0 --glyph advance
	for i = 0, glyph_count-1 do

		--glyph origin relative to the start of the run.
		local px = ax + glyph_pos[i].x_offset
		local py = ay - glyph_pos[i].y_offset

		local glyph_index = glyph_info[i].codepoint

		local m = self.rs:glyph_metrics(font, font_size, glyph_index)
		bx, by, bw, bh = bounding_box(bx, by, bw, bh,
			px / 64 + m.hlsb,
			py / 64 - m.htsb,
			m.w, m.h)

		ax = ax + glyph_pos[i].x_advance
		ay = ay - glyph_pos[i].y_advance

		--put glyph origin into x/y_offset!
		glyph_pos[i].x_offset = px
		glyph_pos[i].y_offset = py
	end
	zone()

	local glyph_run = update({
		tr = self,
		--for glyph painting
		font = font,
		font_size = font_size,
		hb_buf = hb_buf,
		--for positioning in horizontal flow
		advance_x = ax / 64,
		--for positioning in vertical flow (NYI)
		advance_y = ay / 64,
		--for vertical alignment, line spacing and line hit-testing
		ascent = font.ascent,
		descent = font.descent,
		--for horizontal alignment and for line wrapping
		hlsb = bx, --left-side-bearing for horizontal flow
		htsb = by, --top-side bearing for horizontal flow
		w = bw,
		h = bh,
		--for lru cache
		mem_size =
			224 --hb_buffer_t
			+ 200 --this table
			+ 4 * len --input text
			+ hb_glyph_size * glyph_count, --output glyphs
	}, self.glyph_run_class)

	return glyph_run
end

function tr:glyph_run(
	vstr, i, len,
	font, font_size, features, feat_count, rtl, script, lang
)
	font:ref()
	local text_hash = tonumber(xxhash64(vstr + i, 4 * len, 0))
	local lang_id = tonumber(lang) or false
	local key = font.tuple(text_hash, font_size, rtl, script, lang_id)
	local glyph_run = self.glyph_runs:get(key)
	if not glyph_run then
		glyph_run = self:shape_text_run(
			vstr, i, len,
			font, font_size, features, feat_count, rtl, script, lang
		)
		self.glyph_runs:put(key, glyph_run)
	end
	font:unref()
	return glyph_run
end

function tr:shape(text_tree)

	local text_runs = flatten_text_tree(text_tree, {})

	--find (font, size) of each text run and get text length in codepoints.
	local len = 0
	for _,run in ipairs(text_runs) do

		--find (font, size) of each run.
		run.font, run.font_size = self.rs.font_db:find_font(
			run.font_name,
			run.font_weight,
			run.font_slant,
			run.font_size
		)
		assert(run.font, 'Font not found: %s', run.font_name)
		assert(run.font_size, 'Font size missing')
		run.font_size = snap(run.font_size, self.rs.font_size_resolution)

		--find length in codepoints of each run.
		run.text_size = run.text_size or #run.text
		assert(run.text_size, 'text buffer size missing')
		run.charset = run.charset or 'utf8'
		if run.charset == 'utf8' then
			run.len = utf8.decode(run.text, run.text_size, false)
		elseif run.charset == 'utf32' then
			run.len = math.floor(run.text_size / 4)
		else
			assert(false, 'invalid charset: %s', run.charset)
		end

		len = len + run.len
	end

	local segments = update({tr = self}, self.segments_class) --{seg1, ...}

	if len == 0 then
		return segments
	end

	--convert and concatenate text into a single utf32 buffer.
	str = realloc(str, 'uint32_t[?]', len)
	local offset = 0
	for _,run in ipairs(text_runs) do
		local str = str + offset
		if run.charset == 'utf8' then
			utf8.decode(run.text, run.text_size, str, run.len)
		elseif run.charset == 'utf32' then
			ffi.copy(str, run.text, run.text_size)
		end
		run.offset = offset
		offset = offset + run.len
	end

	--detect the script and lang properties for each char of the entire text.
	scripts = realloc(scripts, 'hb_script_t[?]', len)
	langs = realloc(langs, 'hb_language_t[?]', len)
	zone'detect_script'
	detect_scripts(str, len, scripts)
	zone()

	--override scripts and langs with user-provided values.
	for _,run in ipairs(text_runs) do
		if run.script then
			local script = hb.script(run.script)
			assert(script, 'invalid script: ', run.script)
			for i = run.offset, run.offset + run.len - 1 do
				scripts[i] = script
			end
		end
		if run.lang then
			local lang = hb.language(run.lang)
			assert(lang, 'invalid lang: ', run.lang)
			for i = run.offset, run.offset + run.len - 1 do
				langs[i] = lang
			end
		end
	end

	--Run fribidi over the entire text as follows:
	--Request mirroring since it's part of BiDi and harfbuzz doesn't do that.
	--Skip arabic shaping since harfbuzz does that better with font assistance.
	--Skip RTL reordering because 1) fribidi also reverses the _contents_ of
	--the RTL runs which harfbuzz also does, and 2) because bidi reordering
	--needs to be done after line breaking and is thus part of layouting.
	zone'bidi'
	local dir = (text_tree.dir or 'auto'):lower()
	dir = dir == 'rtl'  and fb.C.FRIBIDI_PAR_RTL
		or dir == 'ltr'  and fb.C.FRIBIDI_PAR_LTR
		or dir == 'auto' and fb.C.FRIBIDI_PAR_ON

	bidi_types    = realloc(bidi_types, 'FriBidiCharType[?]', len)
	bracket_types = realloc(bracket_types, 'FriBidiBracketType[?]', len)
	levels        = realloc(levels, 'FriBidiLevel[?]', len)
	vstr          = realloc(vstr, 'FriBidiChar[?]', len)

	fb.bidi_types(str, len, bidi_types)
	fb.bracket_types(str, len, bidi_types, bracket_types)
	local max_level, dir = fb.par_embedding_levels(bidi_types,
		bracket_types, len, dir, levels)
	assert(max_level, dir)
	ffi.copy(vstr, str, len * 4)
	fb.shape_mirroring(levels, len, vstr)
	zone()

	--run Unicode line breaking over each run of text with same language.
	zone'linebreak'
	linebreaks = realloc(linebreaks, 'char[?]', len)
	for i, len, lang in runs(langs, len, 0) do
		local lang = hb.language_tostring(lang)
		lang = lang and lang:sub(1, 2)
		ub.linebreaks(vstr + i, len, lang, linebreaks + i)
	end
	zone()

	--split text into segments of characters with the same properties
	--and shape those individually with harfbuzz.

	zone'segment'
	local offset = 0
	local text_run_index = 1
	local text_run = text_runs[1]
	local level, script, lang
	for i = 0, len do

		--0: break required, 1: break allowed, 2: break not allowed.
		local linebreak = i > 0 and linebreaks[i-1] or 2

		local text_run1, level1, script1, lang1
		local text_run_same_props

		if i == len then
			goto process
		end

		--change to the next text_run if we're past the current text run.
		if i > text_run.offset + text_run.len - 1 then
			text_run_index = text_run_index + 1
			text_run1 = text_runs[text_run_index]
			text_run_same_props =
				text_run1.font == text_run.font
				and text_run1.font_size == text_run.font_size
				and text_run1.features == text_run.features
				and text_run1.line_spacing == text_run.line_spacing
		else
			text_run1 = text_run
			text_run_same_props = true
		end

		level1 = levels[i]
		script1 = scripts[i]
		lang1 = langs[i]

		if i == 0 then
			goto advance
		end

		if linebreak > 1
			and text_run_same_props
			and level1 == level
			and script1 == script
			and lang1 == lang
		then
			goto advance
		end

		::process::
		push(segments, {
			--reusable part
			run = self:glyph_run(
				vstr, offset, i - offset,
				text_run.font,
				text_run.font_size,
				text_run.features,
				text_run.feat_count,
				odd(level),
				script,
				lang
			),
			--non-reusable part
			level = level,
			linebreak = linebreak == 0, --hard break
			line_spacing = text_run.line_spacing,
		})
		offset = i

		::advance::
		text_run, level, script, lang = text_run1, level1, script1, lang1
	end
	zone()

	len0 = len
	return segments
end

local segments = {} --methods for segment list
tr.segments_class = segments

function segments:layout(x, y, w, h, halign, valign)

	halign = halign or 'left'
	valign = valign or 'top'
	assert(halign == 'left' or halign == 'right' or halign == 'center')
	assert(valign == 'top' or valign == 'bottom' or valign == 'middle')

	local lines = update({tr = self.tr, segments = self}, self.tr.lines_class)

	if #self == 0 then
		return lines
	end

	--do line wrapping and compute line width and hlsb.
	zone'linewrap'
	local line
	local ax, dx --line x-advance for line width calculation.
	for i,seg in ipairs(self) do
		if not line or line.advance_x + dx + seg.run.hlsb + seg.run.w > w then
			ax = -seg.run.hlsb
			dx = halign == 'left' and 0 or ax
			line = {
				hlsb = seg.run.hlsb,
				advance_x = 0,
				w = 0,
				ascent = 0, descent = 0,
				spacing_ascent = 0, spacing_descent = 0,
			}
			push(lines, line)
		end
		line.w = ax + seg.run.hlsb + seg.run.w
		line.advance_x = line.advance_x + seg.run.advance_x
		ax = ax + seg.run.advance_x

		push(line, seg)
		if seg.linebreak then
			line = nil
		end
	end
	zone()

	--reorder RTL segments on each line separately and concatenate the runs.
	zone'reorder'
	for _,line in ipairs(lines) do
		local n = #line
		for i,seg in ipairs(line) do
			seg.next = line[i+1] or false
		end
		local seg = reorder_runs(line[1])
		local i = 0
		while seg do
			i = i + 1
			line[i] = seg
			seg = seg.next
		end
		assert(i == n)
	end
	zone()

	for i,line in ipairs(lines) do

		--compute line's aligned x position relative to the textbox.
		if halign == 'left' then
			line.x = 0
		elseif halign == 'right' then
			line.x = w - line.w - line.hlsb
		elseif halign == 'center' then
			line.x = (w - line.w) / 2 - line.hlsb
		end

		--compute line's vertical metrics.
		for _,seg in ipairs(line) do
			line.ascent = math.max(line.ascent, seg.run.ascent)
			line.descent = math.min(line.descent, seg.run.descent)
			local half_line_gap =
				(seg.run.ascent - seg.run.descent) * (seg.line_spacing - 1) / 2
			line.spacing_ascent
				= math.max(line.spacing_ascent, seg.run.ascent + half_line_gap)
			line.spacing_descent
				= math.min(line.spacing_descent, seg.run.descent - half_line_gap)
		end

		--compute line's y position relative to first line's baseline.
		if i == 1 then
			line.y = 0
		else
			local last_line = lines[i-1]
			line.y = last_line.y - last_line.spacing_descent + line.spacing_ascent
		end
	end

	--compute first line's baseline based on vertical alignment.
	if valign == 'top' then
		lines.baseline = lines[1].spacing_ascent
	else
		if valign == 'bottom' then
			lines.baseline = h - (lines[#lines].y - lines[#lines].spacing_descent)
		elseif valign == 'middle' then
			local lines_h = lines[#lines].y + lines[1].spacing_ascent - lines[#lines].spacing_descent
			lines.baseline = lines[1].spacing_ascent + (h - lines_h) / 2
		end
	end

	--store textbox's origin.
	--the textbox can be moved after layouting without requiring re-layouting.
	lines.x = x
	lines.y = y

	return lines
end

local lines = {} --methods for line list
tr.lines_class = lines

function lines:paint(cr)
	local rs = self.tr.rs

	for _,line in ipairs(self) do

		local ax = self.x + line.x
		local ay = self.y + self.baseline + line.y

		for _,seg in ipairs(line) do

			local run = seg.run
			local hb_buf = run.hb_buf

			local glyph_count = hb_buf:get_length()
			local glyph_info  = hb_buf:get_glyph_infos()
			local glyph_pos   = hb_buf:get_glyph_positions()

			for i = 0, glyph_count-1 do

				local glyph_index = glyph_info[i].codepoint

				--glyph origin relative to the start of the line.
				local px = ax + glyph_pos[i].x_offset / 64
				local py = ay + glyph_pos[i].y_offset / 64

				local glyph, bmpx, bmpy = rs:glyph(
					run.font, run.font_size, glyph_index, px, py)

				rs:paint_glyph(cr, glyph, bmpx, bmpy)
			end

			ax = ax + run.advance_x
			ay = ay + run.advance_y
		end
	end
	return self
end

function tr:textbox(text_tree, cr, x, y, w, h, halign, valign)
	return self
		:shape(text_tree)
		:layout(x, y, w, h, halign, valign)
		:paint(cr)
end

local function cmp_ys(line, y)
	return line.y - line.spacing_descent < y
end
function lines:hit_test_line(x, y,
	extend_top, extend_bottom, extend_left, extend_right
)
	x = x - self.x
	y = y - (self.y + self.baseline)
	if y < -self[1].spacing_ascent then
		return extend_top and 1 or nil
	elseif y > self[#self].y - self[#self].spacing_descent then
		return extend_bottom and #self or nil
	else
		local i = binsearch(y, self, cmp_ys) or #self
		local line = self[i]
		return (extend_left or x >= line.x)
			and (extend_right or x <= line.x + line.advance_x)
			and i or nil
	end
end

function lines:hit_test(x, y,
	extend_top, extend_bottom, extend_linegap, extend_left, extend_right
)
	local hit_line_i = self:hit_test_line(x, y,
		extend_top, extend_bottom, extend_linegap, extend_left, extend_right
	)
	if not hit_line_i then return nil end
	local line = self[hit_line_i]

	local rs = self.tr.rs

	local ax = self.x + line.x
	local ay = self.y + self.baseline + line.y

	local hit_seg_i, hit_glyph_i

	for seg_i, seg in ipairs(line) do

		local run = seg.run
		local hb_buf = run.hb_buf

		if x >= ax and x <= ax + run.advance_x then

			hit_seg_i = seg_i

			local glyph_count = hb_buf:get_length()
			local glyph_pos   = hb_buf:get_glyph_positions()

			local min_d = 1/0

			for i = 0, glyph_count do
				local px
				if i < glyph_count then
					px = ax + glyph_pos[i].x_offset / 64
				else
					px = ax + run.advance_x
				end
				local d = math.abs(x - px)
				if d < min_d then
					min_d = d
					hit_glyph_i = i
				end
			end

			if hit_glyph_i == glyph_count and hit_seg_i < #line then
				hit_seg_i = hit_seg_i + 1
				hit_glyph_i = 0
			end

			break
		end

		ax = ax + run.advance_x
		ay = ay + run.advance_y
	end

	return hit_line_i, hit_seg_i, hit_glyph_i

end

return tr
