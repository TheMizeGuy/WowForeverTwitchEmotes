-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local _, E = ...
local sub, byte, find, format = string.sub, string.byte, string.find, string.format
local floor, max = math.floor, math.max
local EMPTY = {}
local LINK = "addon:ForeverEmotes:"
E.linkPrefix=LINK
-- Code point ranges of non-ASCII spaces and punctuation; every other non-ASCII character, CJK included, continues a word.
local SEPARATORS = {0xA0,0xBF, 0x2000,0x206F, 0x3000,0x303F, 0xFF01,0xFF0F, 0xFF1A,0xFF20, 0xFF3B,0xFF40, 0xFF5B,0xFF65}

local function word(b)
    return b and (b>=128 or b>=48 and b<=57 or b>=65 and b<=90 or b>=97 and b<=122 or b==95)
end
-- Brackets pair up rather than run on, so ((7TV)) still holds (7TV).
local BRACKET = {[40]=true,[41]=true,[91]=true,[93]=true,[123]=true,[125]=true}
local function runsOn(b) return not word(b) and not BRACKET[b] end
-- Byte length of the character at pos and whether it continues a word; a malformed byte counts as a one-byte word character.
local function character(text,pos)
    local b=byte(text,pos)
    if not b then return 0,false elseif b<128 then return 1,word(b) end
    local length=b>=0xF5 and 1 or b>=0xF0 and 4 or b>=0xE0 and 3 or b>=0xC2 and 2 or 1
    if length==1 then return 1,true end
    local code=b%(length==2 and 32 or length==3 and 16 or 8)
    for i=1,length-1 do
        local c=byte(text,pos+i)
        if not c or c<128 or c>191 then return 1,true end
        code=code*64+c-128
    end
    for i=1,#SEPARATORS,2 do if code>=SEPARATORS[i] and code<=SEPARATORS[i+1] then return length,false end end
    return length,true
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
    local root,links={},{}
    for _,entry in ipairs(self.names) do
        local node=root
        for i=1,#entry.name do local b=byte(entry.name,i); node[b]=node[b] or {}; node=node[b] end
        node.entry=entry
        -- Entries outlive rebuilds and their names never change, so each name is encoded once.
        if not entry.encodedName then
            entry.encodedName=hex(entry.name)
            entry.linkStart="|H"..LINK..entry.encodedName.."|h"
        end
        links[entry.linkStart]=entry
    end
    self.trie,self.linkEntries=root,links
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
    end
    -- |r, an escaped pipe (||) and any other two-byte escape.
    return pos+1
end

-- A URL or email token ends at whitespace or markup; escaped pipes stay inside it. Every check here is linear.
local function opaqueWordEnd(text,pos)
    if pos>1 and not sub(text,pos-1,pos-1):match("%s") then return nil end
    local last=find(text,"[%s|]",pos)
    while last and sub(text,last,last+1)=="||" do last=find(text,"[%s|]",last+2) end
    last=last or #text+1
    local token=sub(text,pos,last-1)
    if find(token,"%w://") or find(token,"[%w-]%.%a%a+/") then return last-1 end
    token=token:gsub("^%p+","")
    local domain=token:match("^[^@]+@([^@]+)$")
    if find(token,"^www%.") or domain and find(sub(domain,2,-2),".",1,true) then return last-1 end
end

-- A name whose edge is punctuation never matches inside a longer run of that byte: ??? stays plain in ????.
local function rightBoundary(text,pos)
    local edge=byte(text,pos-1)
    while sub(text,pos,pos)=="|" do
        local tag=sub(text,pos+1,pos+1)
        if tag=="r" then pos=pos+2
        elseif tag=="c" and sub(text,pos+2,pos+9):match("^%x%x%x%x%x%x%x%x$") then pos=pos+10
        else break end
    end
    if byte(text,pos)==edge and runsOn(edge) then return false end
    local _,continues=character(text,pos)
    return not continues
end

function E:Transform(text,time)
    if self:IsRestricted(text) or type(text)~="string" or not self.db.enabled or #text>8192 then return text,EMPTY,false end
    local parts,names={},{}
    local pos,plain,animated,boundary=1,1,false,true
    local root=self.trie or {}
    while pos<=#text do
        local current=byte(text,pos)
        local opaque=opaqueWordEnd(text,pos) or current==124 and markupEnd(text,pos)
        if opaque then
            local tag=sub(text,pos+1,pos+1)
            if current~=124 or (tag~="c" and tag~="r") then boundary=false end
            pos=opaque+1
        else
            local match,last
            if boundary and root[current] and not (pos>1 and runsOn(current) and byte(text,pos-1)==current) then
                local node,scan=root,pos
                while scan<=#text and node[byte(text,scan)] do
                    node=node[byte(text,scan)]; scan=scan+1
                    if node.entry and rightBoundary(text,scan) then match,last=node.entry,scan-1 end
                end
            end
            if match then
                parts[#parts+1]=sub(text,plain,pos-1); parts[#parts+1]=self:Render(match,nil,time,true)
                names[#names+1]=match.name; animated=animated or match.frames>1
                boundary=not word(byte(text,last)); pos=last+1; plain=pos
            else
                local length,continues=character(text,pos)
                boundary=not continues; pos=pos+length
            end
        end
    end
    if #names==0 then return text,names,false end
    parts[#parts+1]=sub(text,plain)
    return table.concat(parts),names,animated
end

function E:AnimateText(text,time)
    if self:IsRestricted(text) or type(text)~="string" then return text end
    local links=self.linkEntries or EMPTY
    local parts,pos,plain,animated={},1,1,false
    while pos<=#text do
        local start=find(text,"|",pos,true)
        if not start then break end
        local last=markupEnd(text,start)
        if sub(text,start+1,start+1)=="H" then
            local first=find(text,"|h",start+2,true)
            local entry=first and links[sub(text,start,first+1)]
            local name=entry and entry.name or first and self:NameFromLink(sub(text,start+2,first-1))
            if name and find(text,"|h",first+2,true) then
                entry=entry or self.catalog[name]
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
    -- The native list takes the Enter meant to send, so a face such as :P and a token that is already a name never open it.
    if #query<2 or #query>128 then return nil end
    local last=cursor
    while last<#text and not sub(text,last+1,last+1):match("[%s|]") do last=last+1 end
    if self.known and self.known[sub(text,first,last)] then return nil end
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

function E:ApplyCompletion(text,completion,name,limit)
    if not completion or not self.catalog[name] then return text,nil end
    local prefix,suffix=sub(text,1,completion.first-1),sub(text,completion.last+1)
    local result=prefix..name..suffix
    if not self:IsRestricted(limit) and type(limit)=="number" and limit>0 then
        -- The chat box's limit counts visible bytes, so link and texture markup in the draft does not count.
        local size=self.VisibleTextBytes and self:VisibleTextBytes(result) or #result
        if size>limit then return text,nil end
    end
    return result,#prefix+#name
end
