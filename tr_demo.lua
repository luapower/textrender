
local tr = require'tr'
local nw = require'nw'
local bundle = require'bundle'
local gfonts = require'gfonts'
local time = require'time'
local box2d = require'box2d'
local color = require'color'

local tr = tr()

nw:app():maxfps(1/0)

local function fps_function()
	local count_per_sec = 2
	local frame_count, last_frame_count, last_time = 0, 0
	return function()
		last_time = last_time or time.clock()
		frame_count = frame_count + 1
		local time = time.clock()
		if time - last_time > 1 / count_per_sec then
			last_frame_count, frame_count = frame_count, 0
			last_time = time
		end
		return last_frame_count * count_per_sec
	end
end

local fps = fps_function()

local win = nw:app():window{
	x = 100, y = 60,
	w = 1800, h = 900,
	--w = 800, h = 600,
}

local function font(file, name)
	local name = name or assert(file:match('([^\\/]+)%.[a-z]+$')):lower()
	local font = tr:add_font_file(file, name)
	--print(font:internal_name())
end

local function gfont(name)
	local file = assert(gfonts.font_file(tr.rs.font_db:parse_font(name)))
	font(file, name)
end

gfont'eb garamond'
gfont'dancing script'
gfont'open sans'
gfont'open sans italic'
gfont'open sans bold italic'
gfont'open sans 300'
gfont'open sans 300 italic'
font'media/fonts/NotoColorEmoji.ttf'
--font'media/fonts/NotoEmoji-Regular.ttf'
--font'media/fonts/EmojiSymbols-Regular.ttf'
--font'media/fonts/SubwayTicker.ttf'
--font'media/fonts/dotty.ttf'
--font'media/fonts/ss-emoji-microsoft.ttf'
--font'media/fonts/Hand Faces St.ttf'
--font'media/fonts/FSEX300.ttf'
font'media/fonts/amiri-regular.ttf'

--tr.rs.font_db:dump()

local function rect(cr, col, x, y, w, h)
	local r, g, b, a = color.parse(col, 'rgb')
	cr:save()
	cr:rectangle(x, y, w, h)
	cr:line_width(1)
	cr:rgba(r, g, b, a or 1)
	cr:stroke()
	cr:restore()
end

local function dot(cr, col, x, y, size)
	local r, g, b, a = color.parse(col, 'rgb')
	cr:save()
	cr:circle(x, y, size or 5)
	cr:rgba(r, g, b, a or 1)
	cr:fill()
	cr:restore()
end

local text = require'glue'.readfile('winapi_history.md')

local segs, lines, cursor

function win:repaint()
	self:title(string.format('%d fps', fps()))

	local cr = self:bitmap():cairo()
	--cr:rgb(1, 1, 1); cr:paint(); cr:rgb(0, 0, 0)
	cr:rgb(0, 0, 0); cr:paint(); cr:rgb(1, 1, 1)

	local t0 = time.clock()

	if false then

		local segs = tr:shape{
			('\xF0\x9F\x98\x81'):rep(2), font_name = 'NotoColorEmoji,34',
		}
		local x, y, w, h = 100, 100, 80, 80
		rect(cr, '#888', x, y, w, h)
		tr:paint(cr, segs, x, y, w, h, 'center', 'bottom')

	elseif true then

		--local s1 = ('gmmI '):rep(1)
		--local s2 = ('fi AV (ثلاثة 1234 خمسة) '):rep(1)
		--local s3 = ('Hebrew (אדםה (adamah))'):rep(1)

		local x, y, w, h = box2d.offset(-50, 0, 0, win:client_size())
		rect(cr, '#888', x, y, w, h)

		segs = segs or tr:shape{
			line_spacing = 1.5,
			--dir = 'rtl',
			--{'A'},
			font_name = 'amiri,120',
			{
				line_spacing = 1.2,
				font_name = 'amiri,120',

				--font_name = 'eb garamond, 200',
				--font_name = 'open sans, 200',
				--'خمسة المفاتيح'

				--multiple glyphs with the same cluster value
				--{'\x15\x09\0\0\x4D\x09\0\0\x15\x09\0\0\x3F\x09\0\0\x15\x09\0\0', charset = 'utf32'},
				--{'\x15\x09\0\0\x4D\x09\0\0\x15\x09\0\0\x3F\x09\0\0\x15\x09\0\0', charset = 'utf32'},
				--'BDgt \u{65}\u{301}ffi fi D\r\nTd  VA Dg'
			},

			{font_name = 'amiri,100', 'المفاتيح\n'},
			{font_name = 'amiri,100', 'المفاتيح ABC\n'},
			{font_name = 'amiri,100', 'ABC المفاتيح'},

			{
				--{font_name = 'eb garamond, 100',
				--'fa AVy ffix xfl lg MM f\n',
				--{'DEF EF F D glm\n'},
			},

			--{font_name = 'eb garamond, 100', 'ffix xfl ffi fl\n'},
			--{font_name = 'amiri, 100', 'ffix xfl ffi fl'},

			--{font_name = 'NotoColorEmoji,34', ('\xF0\x9F\x98\x81'):rep(3)},
		}
		lines = lines or segs:layout(x, y, w, h, 'center', 'middle')
		lines:paint(cr)

		cursor = cursor or segs:cursor()
		cursor:set_lines(lines)

		local cx, cy = cursor:pos(cursor.text_offset)

		local x = lines.x
		local y = lines.y + lines.baseline
		for i,line in ipairs(lines) do
			local hit = cursor.line_i == i
			local x = x + line.x
			local y = y + line.y
			rect(cr, hit and '#f22' or '#222', x + line.hlsb, y, line.w, -line.spacing_ascent)
			rect(cr, hit and '#f22' or '#022', x + line.hlsb, y, line.w, -line.spacing_descent)
			rect(cr, hit and '#fff' or '#888', x + line.hlsb, y, line.w, -line.ascent)
			rect(cr, hit and '#0ff' or '#088', x + line.hlsb, y, line.w, -line.descent)
			dot(cr, '#fff', x, y, 8)
			dot(cr, '#ff0', x + line.advance_x, y, 8)
			local ax = x
			local ay = y
			for i,seg in ipairs(line) do
				local run = seg.glyph_run
				local hit = hit and cursor.seg_i == i
				rect(cr, hit and '#f00' or '#555', ax + run.hlsb, ay + run.htsb, run.w, run.h)
				dot(cr, '#f0f', ax, ay, 4)
				dot(cr, '#0f0', ax + run.advance_x, ay, 6)
				for i,cx in ipairs(run.cursor_xs) do
					local px = ax + cx
					local hit = hit and cursor.cursor_i == i
					dot(cr, '#0ff', px, ay, 3)
				end
				ax = ax + run.advance_x
			end
		end

		local x, y, h = cursor:pos()
		rect(cr, '#fff', x, y, 2, h)

		rect(cr, '#f00', cx, cy, 2, h)

	end

	--local s = (time.clock() - t0)
	--print(string.format('%0.2f ms    %d fps', s * 1000, 1 / s))
	--print(string.format('word  cache size:  %d KB', tr.glyph_runs.total_size / 1024))
	--print(string.format('word  count:       %d   ', tr.glyph_runs.lru.length))
	--print(string.format('glyph cache size:  %d KB', tr.rs.glyphs.total_size / 1024))
	--print(string.format('glyph count:       %d   ', tr.rs.glyphs.lru.length))
	--self:invalidate()
end

function win:mousemove(mx, my)
	if not cursor then return end
	cursor:move_to_pos(mx, my)
	self:invalidate()
end

function win:keydown(key)

	if key == 'enter' then
		require'inspect'({tr, lines}, {
			process = function(v)
				if v == '_next' or v == '_prev' then return end
				return v
			end,
		})
	end

	if key == 'right' then
			--if self.hit_text_run
	elseif key == 'left' then

	end
end


nw:app():run()

tr:free()
