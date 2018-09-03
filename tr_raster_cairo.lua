
--glyph drawing to cairo contexts.
--Written by Cosmin Apreutesei. Public Domain.

if not ... then require'tr_demo'; return end

local ffi = require'ffi'
local glue = require'glue'
local box2d = require'box2d'
local color = require'color'
local ft = require'freetype'
local cairo = require'cairo'
local rs_ft = require'tr_raster_ft'
local zone = require'jit.zone' --glue.noop

local update = glue.update
local round = glue.round
local fit = box2d.fit

local cairo_rs = update({}, rs_ft)
setmetatable(cairo_rs, cairo_rs)

cairo_rs.rasterize_glyph_ft = rs_ft.rasterize_glyph

function cairo_rs:rasterize_glyph(
	font, font_size, glyph_index,
	x_offset, y_offset
)

	local glyph = self:rasterize_glyph_ft(
		font, font_size, glyph_index,
		x_offset, y_offset
	)

	if glyph.bitmap then

		local w = glyph.bitmap.width
		local h = glyph.bitmap.rows

		glyph.surface = cairo.image_surface{
			data = glyph.bitmap.buffer,
			format = glyph.bitmap_format,
			w = w, h = h,
			stride = glyph.bitmap.pitch,
		}

		--scale raster glyphs which freetype cannot scale by itself.
		if font.scale ~= 1 then
			local bw = font.wanted_size
			if w ~= bw and h ~= bw then
				local w1, h1 = fit(w, h, bw, bw)
				local sr0 = glyph.surface
				local sr1 = cairo.image_surface(
					glyph.bitmap_format,
					math.ceil(w1),
					math.ceil(h1))
				local cr = sr1:context()
				cr:translate(x_offset, y_offset)
				cr:scale(w1 / w, h1 / h)
				cr:source(sr0)
				cr:paint()
				cr:rgb(0, 0, 0) --release source
				cr:free()
				sr0:free()
				glyph.surface = sr1
			end
		end

		glyph.paint = glyph.bitmap_format == 'g8'
			and self.paint_g8_glyph
			or self.paint_bgra8_glyph

		local free_bitmap = glyph.free
		function glyph:free()
			free_bitmap(self)
			self.surface:free()
		end

	end

	return glyph
end

cairo_rs.default_color = '#888' --safe default not knowing the bg color
cairo_rs.operator = 'over'

function cairo_rs:setcontext(cr, text_run)
	local r, g, b, a = color.parse(text_run.color or self.default_color, 'rgb')
	cr:rgba(r, g, b, a or 1)
	cr:operator(text_run.operator or self.default_operator)
end

--NOTE: clip_left and clip_right are relative to bitmap's left edge.
function cairo_rs:paint_glyph(cr, glyph, x, y, clip_left, clip_right)
	local paint = glyph.paint
	if not paint then return end
	if clip_left or clip_right then
		cr:save()
		cr:new_path()
		local x1 = x + (clip_left or 0)
		local x2 = x + glyph.bitmap.width + (clip_right or 0)
		cr:rectangle(x1, y, x2 - x1, glyph.bitmap.rows)
		cr:clip()
		paint(self, cr, glyph, x, y)
		cr:restore()
	else
		paint(self, cr, glyph, x, y)
	end
end

function cairo_rs:paint_g8_glyph(cr, glyph, x, y)
	cr:mask(glyph.surface, x, y)
end

function cairo_rs:paint_bgra8_glyph(cr, glyph, x, y)
	cr:source(glyph.surface, x, y)
	cr:paint()
	cr:rgb(0, 0, 0) --clear source
end

return cairo_rs
