
--go@ luajit -jp=z test.lua

io.stdout:setvbuf'no'
io.stderr:setvbuf'no'
require'strict'

local tr = require'tr'
local time = require'time'
local bitmap = require'bitmap'
local cairo = require'cairo'
local glue = require'glue'

local bmp = bitmap.new(1000, 1000, 'bgra8', nil, true)
local sr = cairo.image_surface(bmp)
local cr = sr:context()

local tr = tr()
tr:add_font_file('media/fonts/amiri-regular.ttf', 'amiri')
tr:add_font_file('media/fonts/gfonts/apache/opensans/OpenSans-Regular.ttf ', 'open sans')

local t0 = time.clock()
local n = 20
local s = glue.readfile('winapi_history.md')
local t = {
	font_name = 'open_sans,16',
	--font_name = 'amiri,13',
	line_spacing = 1,
	{
		s
		--('ABCDEFGH abcdefgh 1234 '):rep(200),
	},
}
for i=1,n do
	local segs = tr:shape(t)
	local x = 100
	local y = 450
	local w = 550
	local h = 100
	tr:paint(cr, segs, x, y, w, h, 'right', 'bottom')
end

local s = (time.clock() - t0) / n
print(string.format('%0.2f ms    %d fps', s * 1000, 1 / s))
