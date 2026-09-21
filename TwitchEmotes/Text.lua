-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local _, E = ...
local sub, byte, find, format = string.sub, string.byte, string.find, string.format
local floor, max = math.floor, math.max
local EMPTY = {}
local LINK = "addon:ForeverEmotes:"
E.linkPrefix=LINK

local function word(b)
    return b and (b>=128 or b>=48 and b<=57 or b>=65 and b<=90 or b>=97 and b<=122 or b==95)
end
local function hex(text) return (text:gsub(".",function(c) return format("%02x",byte(c)) end)) end
function E:NameFromLink(link)
    if type(link)~="string" or sub(link,1,#LINK)~=LINK then return nil end
    local encoded=sub(link,#LINK+1)
    if #encoded==0 or #encoded>256 or #encoded%2~=0 or encoded:find("[^%da-f]") then return nil end
    local name=(encoded:gsub("..",function(v) return string.char(tonumber(v,16)) end))
    return self.ValidEmoteName(name) and name or nil
end

function E:BuildMatcher()
    local root={}
    for _,entry in ipairs(self.names) do
        local node=root
        for i=1,#entry.name do local b=byte(entry.name,i); node[b]=node[b] or {}; node=node[b] end
        node.entry=entry
        entry.encodedName=hex(entry.name)
        entry.linkStart="|H"..LINK..entry.encodedName.."|h"
    end
    self.trie=root
end

function E:Render(entry,pixels,time,hyperlink)
    pixels=pixels or self.db.size
    local index=0
    if time and self.db.animate and entry.frames>1 then
        -- A sequence replays stored cells in its own order, so deduplicated frames keep source timing.
        local sequence=entry.sequence
        index=floor(max(0,time)*entry.fps)%(sequence and #sequence or entry.frames)
        if sequence then index=byte(sequence,index+1) end
    end
    local width=max(1,floor(pixels*entry.width/entry.height+0.5))
    local columns=entry.columns or 1
    local left=(index%columns)*(entry.cellWidth or entry.sheetWidth)
    local top=floor(index/columns)*entry.height
    local texture=format("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t",entry.path,pixels,width,entry.sheetWidth,entry.sheetHeight,left,left+entry.width,top,top+entry.height)
    if hyperlink then return (entry.linkStart or "|H"..LINK..hex(entry.name).."|h")..texture.."|h" end
    return texture
end

-- Skip complete markup units so display text in an item/player link is never rewritten.
local function markupEnd(text,pos)
    local tag=sub(text,pos+1,pos+1)
    if tag=="H" then
        local first=find(text,"|h",pos+2,true)
        local last=first and find(text,"|h",first+2,true)
        return last and last+1 or #text
    elseif tag=="T" or tag=="A" then
        local last=find(text,tag=="T" and "|t" or "|a",pos+2,true)
        return last and last+1 or #text
    elseif tag=="c" and sub(text,pos+2,pos+9):match("^%x%x%x%x%x%x%x%x$") then return pos+9
    elseif tag=="r" then return pos+1
    elseif tag=="|" then
        local last=find(text,"%s",pos+2); return last and last-1 or #text
    end
    return pos+1
end

local function opaqueWordEnd(text,pos)
    if pos>1 and not sub(text,pos-1,pos-1):match("%s") then return nil end
    local last=find(text,"%s",pos) or #text+1
    local token=sub(text,pos,last-1):gsub("^[%p]+","")
    if token:find("^%a[%w+.-]*://") or token:find("^www%.") or token:find("^[^@]+@[^@]+%.[^@]+$") then return last-1 end
end

local function rightBoundary(text,pos)
    while sub(text,pos,pos)=="|" do
        local tag=sub(text,pos+1,pos+1)
        if tag=="r" then pos=pos+2
        elseif tag=="c" and sub(text,pos+2,pos+9):match("^%x%x%x%x%x%x%x%x$") then pos=pos+10
        else break end
    end
    return not word(byte(text,pos))
end

function E:Transform(text,time)
    if self:IsRestricted(text) or type(text)~="string" or not self.db.enabled or #text>8192 then return text,EMPTY,false end
    local parts,names={},{}
    local pos,plain,animated,boundary=1,1,false,true
    local root=self.trie or {}
    while pos<=#text do
        local current=byte(text,pos)
        local opaque
        if current==124 then opaque=markupEnd(text,pos) else opaque=opaqueWordEnd(text,pos) end
        if opaque then
            local tag=sub(text,pos+1,pos+1)
            if current~=124 or (tag~="c" and tag~="r") then boundary=false end
            pos=opaque+1
        elseif boundary and root[current] then
            local node,scan,match,last=root,pos,nil,nil
            while scan<=#text and node[byte(text,scan)] do
                node=node[byte(text,scan)]; scan=scan+1
                if node.entry and rightBoundary(text,scan) then match,last=node.entry,scan-1 end
            end
            if match then
                parts[#parts+1]=sub(text,plain,pos-1); parts[#parts+1]=self:Render(match,nil,time,true)
                names[#names+1]=match.name; animated=animated or match.frames>1
                boundary=not word(byte(text,last)); pos=last+1; plain=pos
            else boundary=not word(current); pos=pos+1 end
        else boundary=not word(current); pos=pos+1 end
    end
    if #names==0 then return text,names,false end
    parts[#parts+1]=sub(text,plain)
    return table.concat(parts),names,animated
end

function E:AnimateText(text,time)
    if self:IsRestricted(text) or type(text)~="string" then return text end
    local parts,pos,plain,animated={},1,1,false
    while pos<=#text do
        local start=find(text,"|",pos,true)
        if not start then break end
        local last=markupEnd(text,start)
        if sub(text,start+1,start+1)=="H" then
            local first=find(text,"|h",start+2,true)
            local name=first and self:NameFromLink(sub(text,start+2,first-1))
            if name and find(text,"|h",first+2,true) then
                local entry=self.catalog[name]
                animated=animated or (entry and self.db.enabled and entry.frames>1) or false
                parts[#parts+1]=sub(text,plain,start-1)
                parts[#parts+1]=entry and self.db.enabled and self:Render(entry,nil,time,true) or name
                plain=last+1
            end
        end
        pos=last+1
    end
    if #parts==0 then return text,false end
    parts[#parts+1]=sub(text,plain)
    return table.concat(parts),animated
end

function E:Complete(text,cursor,limit)
    if self:IsRestricted(text) or self:IsRestricted(cursor) or type(text)~="string" or type(cursor)~="number" or #text>8192 or not self.db.enabled then return nil end
    cursor=floor(cursor); if cursor<1 or cursor>#text then return nil end
    local scan=1
    while scan<=cursor do
        local start=find(text,"|",scan,true)
        if not start or start>cursor then break end
        local last=markupEnd(text,start)
        local tag=sub(text,start+1,start+1)
        if tag~="c" and tag~="r" and cursor<=last then return nil end
        scan=last+1
    end
    local first=cursor
    while first>1 and not sub(text,first-1,first-1):match("%s") do first=first-1 end
    local token=sub(text,first,cursor)
    if sub(token,1,1)~=":" or token:find("|",1,true) then return nil end
    local query=sub(token,2):lower()
    if #query<1 or #query>128 then return nil end
    local last=cursor
    while last<#text and not sub(text,last+1,last+1):match("[%s|]") do last=last+1 end
    local entries={}
    -- Binary lower bound over the pre-sorted catalog avoids scanning every emote on each keypress.
    local source=self.completionNames or self.names
    local low,high=1,#source+1
    while low<high do local mid=floor((low+high)/2); if source[mid].completionName<query then low=mid+1 else high=mid end end
    for i=low,#source do
        local e=source[i]
        if sub(e.completionName,1,#query)~=query then break end
        entries[#entries+1]=e; if #entries>=(limit or 8) then break end
    end
    if #entries==0 then return nil end
    return {first=first,last=last,query=query,entries=entries}
end

function E:ApplyCompletion(text,completion,name)
    if not completion or not self.catalog[name] then return text,nil end
    local prefix,suffix=sub(text,1,completion.first-1),sub(text,completion.last+1)
    local result=prefix..name..suffix
    return result,#prefix+#name
end
