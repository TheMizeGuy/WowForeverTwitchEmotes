-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local passed, failed = 0, 0
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function test(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. err) end
end
local LONG = "ThisSeemsLikeItWouldFit" .. string.rep("x", 77)
local function entry(name, frames)
    return {name = name, path = "Interface\\AddOns\\TwitchEmotes\\Media\\test.tga",
        width = 64, height = 32, sheetWidth = 64, sheetHeight = frames and 128 or 32,
        frames = frames or 1, fps = frames and 10 or 0}
end
local function setup()
    local E = {}
    for _, name in ipairs({"Core", "Text"}) do assert(loadfile("TwitchEmotes/" .. name .. ".lua"))("TwitchEmotes", E) end
    E:InitializeDB()
    local emotes = {}
    for _, name in ipairs({"KEKW", "Kappa", "!spin", "forsen", "Clap", "???", "Me:", ":tf:", ":3", "PagBounce", "dada", "o7", "L", LONG}) do
        emotes[#emotes + 1] = entry(name)
    end
    emotes[#emotes + 1] = entry("catJAM", 4)
    E:RegisterPack({id = "base", priority = 0, emotes = emotes})
    E:RebuildCatalog()
    return E
end
local function names(E, text) return select(2, E:Transform(text)) end

test("bare-domain and glued URLs stay untouched", function()
    local E = setup()
    for _, t in ipairs({"twitch.tv/forsen", "stream at twitch.tv/forsen tonight", "clips.twitch.tv/KEKW", "youtube.com/KEKW",
        "discord.gg/KEKW", "raider.io/characters/us/illidan/KEKW", "check:https://www.twitch.tv/KEKW", "(twitch.tv/KEKW)",
        "\226\128\156twitch.tv/KEKW\226\128\157", "https://x.y/KEKW"}) do
        equal(E:Transform(t), t)
    end
    local out, found = E:Transform("KEKW twitch.tv/forsen KEKW")
    equal(#found, 2); assert(out:find(" twitch.tv/forsen ", 1, true))
end)
test("dotted words and single-letter hosts still match", function()
    local E = setup()
    equal(names(E, "lol.KEKW")[1], "KEKW"); equal(names(E, "x.y/KEKW")[1], "KEKW")
    local found = names(E, "KEKW/forsen"); equal(found[1], "KEKW"); equal(found[2], "forsen")
end)

test("escaped pipes and URL or email tokens stop before a glued hyperlink", function()
    local E = setup()
    for _, t in ipairs({"|||cff71d5ff|Hspell:1|h[Big Kappa]|h|r", "|||cff71d5ff|Hspell:6343|h[Thunder Clap]|h|r",
        "https://x.y/z|cff71d5ff|Hspell:1|h[Big Kappa]|h|r", "me:bob@x.com|Hspell:1|h[Big Kappa]|h", "||KEKW", "||HKEKW"}) do
        equal(E:Transform(t), t)
    end
    equal(names(E, "|| KEKW")[1], "KEKW")
end)
test("a URL keeps escaped pipes inside its token", function()
    local E = setup()
    for _, t in ipairs({"https://x.y/a||/KEKW", "||https://x.y/KEKW", "twitch.tv/a||/KEKW"}) do equal(E:Transform(t), t) end
end)

test("hostile tokens cost linear time", function()
    local E = setup()
    for _, t in ipairs({"a@" .. string.rep(".", 8186) .. "@", string.rep("a", 8190), string.rep("a.", 4095),
        "a." .. string.rep("a", 8188), string.rep("||", 4095), string.rep("x@", 4095), string.rep(":", 8190)}) do
        local started = os.clock(); E:Transform(t)
        assert(os.clock() - started < 0.01, ("%d-byte token took %.1f ms"):format(#t, (os.clock() - started) * 1000))
    end
end)
test("emails stay opaque while neighbouring names still match", function()
    local E = setup()
    local out, found = E:Transform("bob@x.com KEKW")
    assert(out:find("bob@x.com ", 1, true)); equal(found[1], "KEKW")
    equal(E:Transform("foo@KEKW.com"), "foo@KEKW.com")
end)

print(string.format("text: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
