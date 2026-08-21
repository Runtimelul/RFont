-- RFont v1.0
-- High-performance TrueType software rasterizer for Roblox.
-- No FontFace/TextLabel is used for the large rendered text.
--
-- Pipeline:
-- TTF -> sfnt tables -> cmap -> loca/glyf -> quadratic outlines ->
-- supersampled scanline rasterization -> glyph cache -> kerning ->
-- RGBA framebuffer -> EditableImage.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")

local W, H = 1024, 420
local FONT_NAME = nil
local FONT_SIZE = 84
local OVERSAMPLE = 3
local DEFAULT_TEXT = "RFont — TrueType in Luau"
local MAX_COMPOSITE_DEPTH = 12

local TEXT_R, TEXT_G, TEXT_B = 244, 247, 255
local BG_R, BG_G, BG_B = 10, 13, 19

local function clamp(x,a,b)
	if x<a then return a elseif x>b then return b end
	return x
end

local function packRGBA(r,g,b,a)
	r=clamp(math.floor(r+0.5),0,255)
	g=clamp(math.floor(g+0.5),0,255)
	b=clamp(math.floor(b+0.5),0,255)
	a=clamp(math.floor(a+0.5),0,255)
	return r + g*256 + b*65536 + a*16777216
end

-- TrueType is big-endian; Roblox buffer integer reads are little-endian.
local function U8(b,p) return buffer.readu8(b,p) end
local function I8(b,p)
	local v=U8(b,p)
	return v>=128 and v-256 or v
end
local function U16(b,p) return U8(b,p)*256 + U8(b,p+1) end
local function I16(b,p)
	local v=U16(b,p)
	return v>=32768 and v-65536 or v
end
local function U32(b,p)
	return U8(b,p)*16777216 + U8(b,p+1)*65536 + U8(b,p+2)*256 + U8(b,p+3)
end
local function tag(b,p)
	return string.char(U8(b,p),U8(b,p+1),U8(b,p+2),U8(b,p+3))
end

----------------------------------------------------------------
-- LOAD IMPORTED FONT
----------------------------------------------------------------

local root=ReplicatedStorage:WaitForChild("RFontFonts")
local folder

if FONT_NAME then
	folder=root:WaitForChild(FONT_NAME)
else
	local list=root:GetChildren()
	table.sort(list,function(a,b) return a.Name<b.Name end)
	for _,v in ipairs(list) do
		if v:IsA("Folder") and v:GetAttribute("Format")=="TTF" then
			folder=v
			break
		end
	end
end

if not folder then error("RFont: no imported TTF found") end

local vals=folder:WaitForChild("Data"):GetChildren()
table.sort(vals,function(a,b) return a.Name<b.Name end)

local compressedLength=folder:GetAttribute("CompressedByteLength")
local cb=buffer.create(compressedLength)
local co=0

for _,v in ipairs(vals) do
	if v:IsA("StringValue") then
		local d=EncodingService:Base64Decode(buffer.fromstring(v.Value))
		local n=buffer.len(d)
		buffer.copy(cb,co,d,0,n)
		co+=n
	end
end

if co~=compressedLength then
	error(("RFont compressed byte mismatch %d/%d"):format(co,compressedLength))
end

local fontData=EncodingService:DecompressBuffer(cb,Enum.CompressionAlgorithm.Zstd)

----------------------------------------------------------------
-- SFNT TABLES
----------------------------------------------------------------

local tables={}
local numTables=U16(fontData,4)

for i=0,numTables-1 do
	local p=12+i*16
	tables[tag(fontData,p)]={offset=U32(fontData,p+8),length=U32(fontData,p+12)}
end

local function need(name)
	local t=tables[name]
	if not t then error("RFont missing table: "..name) end
	return t
end

local head=need("head")
local hhea=need("hhea")
local maxp=need("maxp")
local hmtx=need("hmtx")
local loca=need("loca")
local glyf=need("glyf")
local cmap=need("cmap")

local unitsPerEm=U16(fontData,head.offset+18)
local locaFormat=I16(fontData,head.offset+50)
local numGlyphs=U16(fontData,maxp.offset+4)
local ascent=I16(fontData,hhea.offset+4)
local descent=I16(fontData,hhea.offset+6)
local lineGap=I16(fontData,hhea.offset+8)
local numHMetrics=U16(fontData,hhea.offset+34)

print(("[RFont] %s | units/em=%d | glyphs=%d"):format(folder.Name,unitsPerEm,numGlyphs))

----------------------------------------------------------------
-- METRICS
----------------------------------------------------------------

local advanceCache={}
local function hmetric(gid)
	local c=advanceCache[gid]
	if c then return c[1],c[2] end

	local adv,lsb
	if gid<numHMetrics then
		local p=hmtx.offset+gid*4
		adv=U16(fontData,p)
		lsb=I16(fontData,p+2)
	else
		local p=hmtx.offset+(numHMetrics-1)*4
		adv=U16(fontData,p)
		local extra=gid-numHMetrics
		lsb=I16(fontData,hmtx.offset+numHMetrics*4+extra*2)
	end

	advanceCache[gid]={adv,lsb}
	return adv,lsb
end

local function glyphOffset(gid)
	if locaFormat==0 then
		return U16(fontData,loca.offset+gid*2)*2
	else
		return U32(fontData,loca.offset+gid*4)
	end
end

----------------------------------------------------------------
-- CMAP FORMAT 4 / 12
----------------------------------------------------------------

local cmap4Offset=nil
local cmap12Offset=nil
local nEnc=U16(fontData,cmap.offset+2)

for i=0,nEnc-1 do
	local p=cmap.offset+4+i*8
	local platform=U16(fontData,p)
	local encoding=U16(fontData,p+2)
	local sub=cmap.offset+U32(fontData,p+4)
	local fmt=U16(fontData,sub)

	if fmt==12 then
		if platform==3 and encoding==10 then
			cmap12Offset=sub
		elseif not cmap12Offset and platform==0 then
			cmap12Offset=sub
		end
	elseif fmt==4 then
		if platform==3 and (encoding==1 or encoding==10) then
			cmap4Offset=sub
		elseif not cmap4Offset and platform==0 then
			cmap4Offset=sub
		end
	end
end

local cmap12Groups=nil
if cmap12Offset then
	local n=U32(fontData,cmap12Offset+12)
	cmap12Groups=table.create(n)
	local p=cmap12Offset+16
	for i=1,n do
		cmap12Groups[i]={U32(fontData,p),U32(fontData,p+4),U32(fontData,p+8)}
		p+=12
	end
end

local cmap4=nil
if cmap4Offset then
	local segCount=U16(fontData,cmap4Offset+6)/2
	local ends=cmap4Offset+14
	local starts=ends+segCount*2+2
	local deltas=starts+segCount*2
	local ranges=deltas+segCount*2
	cmap4={count=segCount,ends=ends,starts=starts,deltas=deltas,ranges=ranges}
end

local function lookup12(cp)
	if not cmap12Groups then return nil end
	local lo,hi=1,#cmap12Groups
	while lo<=hi do
		local mid=math.floor((lo+hi)/2)
		local g=cmap12Groups[mid]
		if cp<g[1] then hi=mid-1
		elseif cp>g[2] then lo=mid+1
		else return g[3]+(cp-g[1]) end
	end
	return nil
end

local function lookup4(cp)
	if not cmap4 or cp>65535 then return nil end
	for i=0,cmap4.count-1 do
		local ending=U16(fontData,cmap4.ends+i*2)
		if cp<=ending then
			local starting=U16(fontData,cmap4.starts+i*2)
			if cp<starting then return 0 end
			local delta=I16(fontData,cmap4.deltas+i*2)
			local rangeAddress=cmap4.ranges+i*2
			local ro=U16(fontData,rangeAddress)
			if ro==0 then return (cp+delta)%65536 end
			local addr=rangeAddress+ro+(cp-starting)*2
			local gid=U16(fontData,addr)
			if gid==0 then return 0 end
			return (gid+delta)%65536
		end
	end
	return 0
end

local cpCache={}
local function glyphFor(cp)
	local c=cpCache[cp]
	if c~=nil then return c end
	local g=lookup12(cp)
	if g==nil then g=lookup4(cp) end
	g=g or 0
	cpCache[cp]=g
	return g
end

----------------------------------------------------------------
-- KERN FORMAT 0
----------------------------------------------------------------

local kernPairs={}
local kern=tables["kern"]

if kern and U16(fontData,kern.offset)==0 then
	local count=U16(fontData,kern.offset+2)
	local p=kern.offset+4

	for _=1,count do
		local length=U16(fontData,p+2)
		local coverage=U16(fontData,p+4)
		local format=math.floor(coverage/256)

		if format==0 then
			local nPairs=U16(fontData,p+6)
			local q=p+14
			for _=1,nPairs do
				local l=U16(fontData,q)
				local r=U16(fontData,q+2)
				local value=I16(fontData,q+4)
				kernPairs[l*65536+r]=value
				q+=6
			end
		end

		if length<=0 then break end
		p+=length
	end
end

local function kerning(a,b)
	if not a or not b then return 0 end
	return kernPairs[a*65536+b] or 0
end

----------------------------------------------------------------
-- GLYF DECODER
----------------------------------------------------------------

local ON=0x01
local XS=0x02
local YS=0x04
local REP=0x08
local XEQ=0x10
local YEQ=0x20

local outlines={}

local function simpleGlyph(base,nContours)
	local ends=table.create(nContours)
	local p=base+10

	for i=1,nContours do
		ends[i]=U16(fontData,p)
		p+=2
	end

	local nPoints=ends[nContours]+1
	local instructionLength=U16(fontData,p)
	p+=2+instructionLength

	local flags=table.create(nPoints)
	local i=1
	while i<=nPoints do
		local f=U8(fontData,p)
		p+=1
		flags[i]=f
		i+=1
		if bit32.band(f,REP)~=0 then
			local n=U8(fontData,p)
			p+=1
			for _=1,n do
				flags[i]=f
				i+=1
			end
		end
	end

	local xs=table.create(nPoints)
	local x=0
	for j=1,nPoints do
		local f=flags[j]
		if bit32.band(f,XS)~=0 then
			local d=U8(fontData,p); p+=1
			x += bit32.band(f,XEQ)~=0 and d or -d
		elseif bit32.band(f,XEQ)==0 then
			x+=I16(fontData,p); p+=2
		end
		xs[j]=x
	end

	local ys=table.create(nPoints)
	local y=0
	for j=1,nPoints do
		local f=flags[j]
		if bit32.band(f,YS)~=0 then
			local d=U8(fontData,p); p+=1
			y += bit32.band(f,YEQ)~=0 and d or -d
		elseif bit32.band(f,YEQ)==0 then
			y+=I16(fontData,p); p+=2
		end
		ys[j]=y
	end

	local result=table.create(nContours)
	local start=1

	for ci=1,nContours do
		local ending=ends[ci]+1
		local contour={}
		for j=start,ending do
			contour[#contour+1]={
				x=xs[j],
				y=ys[j],
				on=bit32.band(flags[j],ON)~=0,
			}
		end
		result[ci]=contour
		start=ending+1
	end

	return result
end

local ARG_WORDS=0x0001
local ARGS_XY=0x0002
local HAVE_SCALE=0x0008
local MORE=0x0020
local HAVE_XY_SCALE=0x0040
local HAVE_2X2=0x0080

local function f2dot14(v)
	if v>=32768 then v-=65536 end
	return v/16384
end

local decodeOutline

decodeOutline=function(gid,depth)
	depth=depth or 0
	if depth>MAX_COMPOSITE_DEPTH then return {} end
	if outlines[gid] then return outlines[gid] end

	local s=glyphOffset(gid)
	local e=glyphOffset(gid+1)
	if s==e then outlines[gid]={}; return outlines[gid] end

	local base=glyf.offset+s
	local nc=I16(fontData,base)

	if nc>=0 then
		local result=nc==0 and {} or simpleGlyph(base,nc)
		outlines[gid]=result
		return result
	end

	local result={}
	local p=base+10
	local flags

	repeat
		flags=U16(fontData,p)
		local childGid=U16(fontData,p+2)
		p+=4

		local arg1,arg2
		if bit32.band(flags,ARG_WORDS)~=0 then
			arg1=I16(fontData,p)
			arg2=I16(fontData,p+2)
			p+=4
		else
			arg1=I8(fontData,p)
			arg2=I8(fontData,p+1)
			p+=2
		end

		local dx,dy=0,0
		if bit32.band(flags,ARGS_XY)~=0 then
			dx,dy=arg1,arg2
		end

		local a,b,c,d=1,0,0,1

		if bit32.band(flags,HAVE_SCALE)~=0 then
			local s2=f2dot14(U16(fontData,p)); p+=2
			a,d=s2,s2
		elseif bit32.band(flags,HAVE_XY_SCALE)~=0 then
			a=f2dot14(U16(fontData,p))
			d=f2dot14(U16(fontData,p+2))
			p+=4
		elseif bit32.band(flags,HAVE_2X2)~=0 then
			a=f2dot14(U16(fontData,p))
			b=f2dot14(U16(fontData,p+2))
			c=f2dot14(U16(fontData,p+4))
			d=f2dot14(U16(fontData,p+6))
			p+=8
		end

		local child=decodeOutline(childGid,depth+1)

		for _,contour in ipairs(child) do
			local transformed={}
			for _,pt in ipairs(contour) do
				-- OpenType composite matrix:
				-- x' = a*x + c*y; y' = b*x + d*y
				transformed[#transformed+1]={
					x=a*pt.x+c*pt.y+dx,
					y=b*pt.x+d*pt.y+dy,
					on=pt.on,
				}
			end
			result[#result+1]=transformed
		end
	until bit32.band(flags,MORE)==0

	outlines[gid]=result
	return result
end

----------------------------------------------------------------
-- CONTOUR -> FLATTENED LINE SEGMENTS
----------------------------------------------------------------

local function midpoint(a,b)
	return {x=(a.x+b.x)*0.5,y=(a.y+b.y)*0.5,on=true}
end

local function expandContour(contour)
	local n=#contour
	local nodes={}
	for i=1,n do
		local a=contour[i]
		local b=contour[(i%n)+1]
		nodes[#nodes+1]=a
		if not a.on and not b.on then
			nodes[#nodes+1]=midpoint(a,b)
		end
	end
	return nodes
end

local function line(seg,x0,y0,x1,y1)
	if math.abs(x1-x0)+math.abs(y1-y0)<1e-8 then return end
	seg[#seg+1]={x0=x0,y0=y0,x1=x1,y1=y1}
end

local function quad(seg,p0,p1,p2,scale)
	local l1=math.sqrt((p1.x-p0.x)^2+(p1.y-p0.y)^2)
	local l2=math.sqrt((p2.x-p1.x)^2+(p2.y-p1.y)^2)
	local steps=clamp(math.ceil((l1+l2)*scale/6),2,18)
	local px,py=p0.x,p0.y

	for i=1,steps do
		local t=i/steps
		local q=1-t
		local x=q*q*p0.x+2*q*t*p1.x+t*t*p2.x
		local y=q*q*p0.y+2*q*t*p1.y+t*t*p2.y
		line(seg,px,py,x,y)
		px,py=x,y
	end
end

local function segmentsFor(contours,scale)
	local seg={}

	for _,contour in ipairs(contours) do
		local nodes=expandContour(contour)
		if #nodes<2 then continue end

		local startIndex=nil
		for i,v in ipairs(nodes) do
			if v.on then startIndex=i; break end
		end
		if not startIndex then continue end

		local ordered={}
		for k=0,#nodes-1 do
			ordered[#ordered+1]=nodes[((startIndex-1+k)%#nodes)+1]
		end
		ordered[#ordered+1]=ordered[1]

		local current=ordered[1]
		local i=2

		while i<=#ordered do
			local n=ordered[i]
			if n.on then
				line(seg,current.x,current.y,n.x,n.y)
				current=n
				i+=1
			else
				local target=ordered[i+1]
				if not target then break end
				quad(seg,current,n,target,scale)
				current=target
				i+=2
			end
		end
	end

	return seg
end

----------------------------------------------------------------
-- GLYPH RASTERIZER + CACHE
----------------------------------------------------------------

local glyphCache={}

local function rasterGlyph(gid,size)
	local key=("%d:%d:%d"):format(gid,size,OVERSAMPLE)
	local cached=glyphCache[key]
	if cached then return cached end

	local scale=size/unitsPerEm
	local adv=hmetric(gid)
	local contours=decodeOutline(gid)

	if #contours==0 then
		local g={w=0,h=0,ox=0,oy=0,advance=adv*scale,alpha=buffer.create(0)}
		glyphCache[key]=g
		return g
	end

	local raw=segmentsFor(contours,scale)
	local seg={}
	local minX,minY=math.huge,math.huge
	local maxX,maxY=-math.huge,-math.huge

	for _,s in ipairs(raw) do
		local x0=s.x0*scale
		local y0=-s.y0*scale
		local x1=s.x1*scale
		local y1=-s.y1*scale

		seg[#seg+1]={x0=x0,y0=y0,x1=x1,y1=y1}
		minX=math.min(minX,x0,x1)
		maxX=math.max(maxX,x0,x1)
		minY=math.min(minY,y0,y1)
		maxY=math.max(maxY,y0,y1)
	end

	local pad=1
	local ox=math.floor(minX)-pad
	local oy=math.floor(minY)-pad
	local gw=math.max(0,math.ceil(maxX)-ox+pad)
	local gh=math.max(0,math.ceil(maxY)-oy+pad)

	if gw==0 or gh==0 then
		local g={w=0,h=0,ox=ox,oy=oy,advance=adv*scale,alpha=buffer.create(0)}
		glyphCache[key]=g
		return g
	end

	local ss=OVERSAMPLE
	local hw,hh=gw*ss,gh*ss
	local high=buffer.create(hw*hh)
	local xs={}

	for sy=0,hh-1 do
		local scanY=oy+(sy+0.5)/ss
		table.clear(xs)

		for _,e in ipairs(seg) do
			if (e.y0<=scanY and scanY<e.y1) or (e.y1<=scanY and scanY<e.y0) then
				local t=(scanY-e.y0)/(e.y1-e.y0)
				xs[#xs+1]=e.x0+(e.x1-e.x0)*t
			end
		end

		table.sort(xs)

		for p=1,math.floor(#xs/2) do
			local x0=xs[(p-1)*2+1]
			local x1=xs[(p-1)*2+2]
			if x1<x0 then x0,x1=x1,x0 end

			local sx0=clamp(math.ceil((x0-ox)*ss-0.5),0,hw-1)
			local sx1=clamp(math.floor((x1-ox)*ss-0.5),0,hw-1)

			local row=sy*hw
			for sx=sx0,sx1 do
				buffer.writeu8(high,row+sx,255)
			end
		end
	end

	local alpha=buffer.create(gw*gh)
	local nSamples=ss*ss

	for y=0,gh-1 do
		for x=0,gw-1 do
			local sum=0
			for yy=0,ss-1 do
				local row=(y*ss+yy)*hw+x*ss
				for xx=0,ss-1 do
					sum+=buffer.readu8(high,row+xx)
				end
			end
			buffer.writeu8(alpha,y*gw+x,math.floor(sum/nSamples+0.5))
		end
	end

	local g={w=gw,h=gh,ox=ox,oy=oy,advance=adv*scale,alpha=alpha}
	glyphCache[key]=g
	return g
end

----------------------------------------------------------------
-- SOFTWARE FRAMEBUFFER + BLENDING
----------------------------------------------------------------

local fb=buffer.create(W*H*4)
local bg=buffer.create(W*H*4)
local bgPixel=packRGBA(BG_R,BG_G,BG_B,255)

for i=0,W*H-1 do buffer.writeu32(bg,i*4,bgPixel) end

local function clear()
	buffer.copy(fb,0,bg,0,buffer.len(bg))
end

local function blend(x,y,r,g,b,a)
	if x<0 or y<0 or x>=W or y>=H or a<=0 then return end
	local p=(y*W+x)*4

	if a>=255 then
		buffer.writeu32(fb,p,packRGBA(r,g,b,255))
		return
	end

	local inv=255-a
	local orr=buffer.readu8(fb,p)
	local og=buffer.readu8(fb,p+1)
	local ob=buffer.readu8(fb,p+2)

	buffer.writeu32(
		fb,p,
		packRGBA(
			(r*a+orr*inv)/255,
			(g*a+og*inv)/255,
			(b*a+ob*inv)/255,
			255
		)
	)
end

local function blit(g,x,baseline,r,gg,b)
	local sx=math.floor(x+g.ox)
	local sy=math.floor(baseline+g.oy)

	for y=0,g.h-1 do
		local dy=sy+y
		if dy<0 or dy>=H then continue end
		local row=y*g.w

		for xx=0,g.w-1 do
			local dx=sx+xx
			if dx<0 or dx>=W then continue end
			local a=buffer.readu8(g.alpha,row+xx)
			if a>0 then blend(dx,dy,r,gg,b,a) end
		end
	end
end

local function glyphRun(text)
	local run={}
	for _,cp in utf8.codes(text) do
		run[#run+1]={cp=cp,gid=glyphFor(cp)}
	end
	return run
end

local function measure(text,size)
	local run=glyphRun(text)
	local scale=size/unitsPerEm
	local pen=0
	local prev=nil

	for _,v in ipairs(run) do
		if prev then pen+=kerning(prev,v.gid)*scale end
		local g=rasterGlyph(v.gid,size)
		pen+=g.advance
		prev=v.gid
	end

	return pen,run
end

local function drawText(text,size,cx,baseline,r,g,b)
	local width,run=measure(text,size)
	local scale=size/unitsPerEm
	local pen=cx-width/2
	local prev=nil

	for _,v in ipairs(run) do
		if prev then pen+=kerning(prev,v.gid)*scale end
		local glyph=rasterGlyph(v.gid,size)
		blit(glyph,pen,baseline,r,g,b)
		pen+=glyph.advance
		prev=v.gid
	end

	return width
end

----------------------------------------------------------------
-- EDITABLEIMAGE UI
----------------------------------------------------------------

local player=Players.LocalPlayer
local pg=player:WaitForChild("PlayerGui")

local old=pg:FindFirstChild("RFontGui")
if old then old:Destroy() end

local gui=Instance.new("ScreenGui")
gui.Name="RFontGui"
gui.IgnoreGuiInset=true
gui.ResetOnSpawn=false
gui.Parent=pg

local img=Instance.new("ImageLabel")
img.AnchorPoint=Vector2.new(0.5,0.5)
img.Position=UDim2.fromScale(0.5,0.45)
img.Size=UDim2.fromScale(0.88,0.62)
img.BackgroundColor3=Color3.new()
img.BorderSizePixel=0
img.ScaleType=Enum.ScaleType.Fit
img.ResampleMode=Enum.ResamplerMode.Default
img.Parent=gui

local aspect=Instance.new("UIAspectRatioConstraint")
aspect.AspectRatio=W/H
aspect.DominantAxis=Enum.DominantAxis.Width
aspect.Parent=img

local editable=AssetService:CreateEditableImage({Size=Vector2.new(W,H)})
if not editable then error("RFont CreateEditableImage failed") end
img.ImageContent=Content.fromObject(editable)

-- Native TextBox is only an input device. Large text is software-rendered.
local input=Instance.new("TextBox")
input.AnchorPoint=Vector2.new(0.5,1)
input.Position=UDim2.new(0.5,0,1,-24)
input.Size=UDim2.fromOffset(700,44)
input.BackgroundColor3=Color3.fromRGB(21,25,34)
input.BorderSizePixel=0
input.TextColor3=Color3.fromRGB(225,230,240)
input.PlaceholderColor3=Color3.fromRGB(120,126,140)
input.TextSize=18
input.Font=Enum.Font.Code
input.ClearTextOnFocus=false
input.Text=DEFAULT_TEXT
input.PlaceholderText="Type here — large text is rendered by RFont"
input.Parent=gui

local debug=Instance.new("TextLabel")
debug.Position=UDim2.fromOffset(16,16)
debug.Size=UDim2.fromOffset(560,110)
debug.BackgroundColor3=Color3.new()
debug.BackgroundTransparency=0.3
debug.BorderSizePixel=0
debug.Font=Enum.Font.Code
debug.TextSize=14
debug.TextColor3=Color3.fromRGB(220,226,238)
debug.TextXAlignment=Enum.TextXAlignment.Left
debug.TextYAlignment=Enum.TextYAlignment.Top
debug.Parent=gui

local generation=0

local function render(text)
	generation+=1
	local my=generation
	local start=os.clock()

	clear()

	local width=drawText(
		text,
		FONT_SIZE,
		W*0.5,
		H*0.58,
		TEXT_R,TEXT_G,TEXT_B
	)

	drawText(
		"cmap • glyf • quadratic bezier • kerning • cached",
		26,
		W*0.5,
		H-43,
		110,174,255
	)

	if my~=generation then return end

	editable:WritePixelsBuffer(Vector2.zero,Vector2.new(W,H),fb)

	local ms=(os.clock()-start)*1000
	local cacheCount=0
	for _ in pairs(glyphCache) do cacheCount+=1 end

	debug.Text=(
		"RFONT TRUE-TYPE SOFTWARE RASTERIZER\n"
		.."FONT        %s\n"
		.."CANVAS      %dx%d\n"
		.."SIZE        %d px | %dx supersampling\n"
		.."TEXT WIDTH  %.1f px\n"
		.."GLYPH CACHE %d\n"
		.."RENDER      %.2f ms"
	):format(folder.Name,W,H,FONT_SIZE,OVERSAMPLE,width,cacheCount,ms)

	print(("[RFont] %q -> %.2f ms | glyph cache %d"):format(text,ms,cacheCount))
end

local pending=false
local function request()
	if pending then return end
	pending=true

	task.defer(function()
		pending=false
		render(input.Text=="" and " " or input.Text)
	end)
end

input:GetPropertyChangedSignal("Text"):Connect(request)

render(DEFAULT_TEXT)

print("[RFont] canvas is software-rasterized from raw TrueType outlines; Roblox font rendering is not used.")
