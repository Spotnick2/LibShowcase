-- harness.lua: assertions and the library loader. dofile it after wow_stubs.lua.
-- Run from the repo root so the relative paths resolve.
--
-- LIBSHOWCASE_MUTANT (tests/mutate.lua): a path whose content replaces
-- LibShowcase.lua, so the suite can be run against a deliberately broken copy.

local passed, failed = 0, 0

function check(cond, msg)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: " .. tostring(msg) .. "\n")
    end
end

function eq(actual, expected, msg)
    check(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

function done(name)
    io.write(string.format("%s: %d passed, %d failed\n", name, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

function readFile(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

-- The Lua files LibShowcase-1.0.xml loads, in order. Read from the XML itself,
-- so the tests load exactly what the client loads.
function xmlScripts(xmlPath)
    local xml = readFile(xmlPath or "LibShowcase-1.0.xml"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do files[#files + 1] = (file:gsub("\\", "/")) end
    return files
end

-- LF, whatever the checkout has: a Windows clone with core.autocrlf gets
-- CRLF, and synthetic()'s substitutions are written with "\n".
local function readSource(path)
    return (readFile(path):gsub("\r\n", "\n"))
end

local function source(file)
    local mutant = os.getenv("LIBSHOWCASE_MUTANT")
    if mutant and mutant ~= "" and file == "LibShowcase.lua" then file = mutant end
    return readSource(file)
end

-- One copy of the library: { { name, src } }, every file the XML lists.
-- `edit(file, src)` may rewrite a file's source (synthetic copies).
function copyOf(edit)
    local copy = {}
    for _, file in ipairs(xmlScripts()) do
        local src = source(file)
        if edit then src = edit(file, src) end
        copy[#copy + 1] = { name = file, src = src }
    end
    return copy
end

-- Load a copy the way the client loads an embedded library: every file the
-- XML lists, in order, each called with (host addon name, namespace).
function loadCopy(copy, host)
    local ns = {}
    for _, file in ipairs(copy) do
        local chunk = assert(loadstring(file.src, "=" .. file.name .. " (" .. tostring(host) .. ")"))
        chunk(host, ns)
    end
    return LibStub("LibShowcase-1.0")
end

-- A released copy, whole: `dir` (tests/fixtures/LibShowcase-rN) holds the
-- tag's XML and every file it lists, byte for byte, loaded in ITS order.
-- Never the checkout's files (a mutant included).
function releasedCopy(dir)
    local copy = {}
    for _, file in ipairs(xmlScripts(dir .. "/LibShowcase-1.0.xml")) do
        copy[#copy + 1] = { name = file, src = readSource(dir .. "/" .. file) }
    end
    return copy
end

-- A fresh client with this checkout embedded in `host`.
function freshLibrary(host)
    WoW.reset()
    WoW.resetLibStub()
    return loadCopy(copyOf(), host or "AltStable")
end

-- This checkout with a different MINOR and, optionally, `extra` Lua run just
-- before the completion marker (it sees the file's locals: lib, I, st, ...).
-- `replace` is a list of { from, to } plain-text substitutions, each of which
-- must match exactly once.
local MINOR_LINE = 'local MAJOR, MINOR = "LibShowcase%-1%.0", (%d+)'
function currentMinor()
    return tonumber(readFile("LibShowcase.lua"):match(MINOR_LINE))
end
function synthetic(minor, extra, replace)
    return copyOf(function(file, src)
        if file ~= "LibShowcase.lua" then return src end
        local n
        src, n = src:gsub(MINOR_LINE, 'local MAJOR, MINOR = "LibShowcase-1.0", ' .. minor)
        assert(n == 1, "synthetic: MINOR line not found")
        for _, r in ipairs(replace or {}) do
            local i, j = src:find(r[1], 1, true)
            assert(i and not src:find(r[1], j + 1, true), "synthetic: must match once: " .. r[1])
            src = src:sub(1, i - 1) .. r[2] .. src:sub(j + 1)
        end
        if extra then
            local i = src:find("\nlib.ready = MINOR%s*$")
            assert(i, "synthetic: the completion marker is not the last line")
            src = src:sub(1, i) .. extra .. "\n" .. src:sub(i + 1)
        end
        return src
    end)
end

-- A consumer window under UIParent.
function newWindow(strata)
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata(strata or "MEDIUM")
    f:SetPoint("CENTER", UIParent, "CENTER", 100, 0)
    return f
end

-- The calls logged since `from` (an index into WoW.calls).
function callsSince(from)
    local t = {}
    for i = (from or 0) + 1, #WoW.calls do t[#t + 1] = WoW.calls[i] end
    return t
end

function hasCall(prefix)
    for _, c in ipairs(WoW.calls) do
        if c:sub(1, #prefix) == prefix then return true end
    end
    return false
end
