-- RFont TrueType Importer
-- Save as a LOCAL Studio plugin.
-- Imports a raw TTF, Zstd-compresses it, then Base64-stores it in ReplicatedStorage.

local StudioService=game:GetService("StudioService")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local EncodingService=game:GetService("EncodingService")

local CHUNK=48*1024

local toolbar=plugin:CreateToolbar("RFont")
local button=toolbar:CreateButton("Import TTF","Import a TrueType font for RFont","")

local function sanitize(name)
	name=tostring(name or "Font")
	name=name:gsub("%.[Tt][Tt][Ff]$","")
	name=name:gsub("[^%w_%-%s]","_")
	name=name:gsub("%s+","_")
	return name=="" and "Font" or name
end

local function filename(file)
	local ok,v=pcall(function() return file.Name end)
	if ok and type(v)=="string" and v~="" then return sanitize(v) end
	return "Font_"..os.time()
end

local function root()
	local r=ReplicatedStorage:FindFirstChild("RFontFonts")
	if not r then
		r=Instance.new("Folder")
		r.Name="RFontFonts"
		r.Parent=ReplicatedStorage
	end
	return r
end

button.Click:Connect(function()
	local file=StudioService:PromptImportFileAsync({"ttf"})
	if not file then return end

	if file.Size>=100000000 then
		warn("RFont: font exceeds Studio file read limit")
		return
	end

	local bytes=file:GetBinaryContents()
	if not bytes or #bytes<12 then
		warn("RFont: invalid/empty TTF")
		return
	end

	if bytes:sub(1,4)=="OTTO" then
		warn("RFont v1 supports TrueType glyf outlines, not CFF/CFF2 OTTO fonts.")
		return
	end

	-- Basic check that a glyf table tag exists somewhere in the SFNT table directory.
	local numTables=string.byte(bytes,5)*256+string.byte(bytes,6)
	local hasGlyf=false

	for i=0,numTables-1 do
		local p=13+i*16 -- Lua strings are 1-based
		if bytes:sub(p,p+3)=="glyf" then
			hasGlyf=true
			break
		end
	end

	if not hasGlyf then
		warn("RFont v1 requires a TrueType font with a glyf table.")
		return
	end

	local raw=buffer.fromstring(bytes)
	local compressed=EncodingService:CompressBuffer(raw,Enum.CompressionAlgorithm.Zstd,12)
	local compressedLength=buffer.len(compressed)

	local r=root()
	local name=filename(file)
	local old=r:FindFirstChild(name)
	if old then old:Destroy() end

	local folder=Instance.new("Folder")
	folder.Name=name
	folder:SetAttribute("Format","TTF")
	folder:SetAttribute("RawByteLength",#bytes)
	folder:SetAttribute("CompressedByteLength",compressedLength)
	folder.Parent=r

	local data=Instance.new("Folder")
	data.Name="Data"
	data.Parent=folder

	local index=0
	for offset=0,compressedLength-1,CHUNK do
		index+=1
		local count=math.min(CHUNK,compressedLength-offset)
		local piece=buffer.create(count)
		buffer.copy(piece,0,compressed,offset,count)
		local encoded=EncodingService:Base64Encode(piece)

		local value=Instance.new("StringValue")
		value.Name=("%06d"):format(index)
		value.Value=buffer.tostring(encoded)
		value.Parent=data
	end

	folder:SetAttribute("ChunkCount",index)

	print(("[RFont] Imported %s | %.1f KiB raw -> %.1f KiB zstd | %d chunks")
		:format(name,#bytes/1024,compressedLength/1024,index))
end)
