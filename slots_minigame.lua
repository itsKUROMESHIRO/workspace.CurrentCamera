--[[
    AFK Slots Minigame v2  (for Delta / Roblox)
    - 3 to 10 reels, 4 icons
    - Endless upgrades: Payout, Luck, Income, More Reels (3 -> 10)
    - Rebirth + Prestige (prestige gives Prestige Tokens)
    - Tech Tree: endless upgrades bought with Prestige Tokens
    - Big number suffixes: K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc ... and beyond
    - Auto Spin + Auto Bet for AFK farming
    - Open / Close button + draggable window
    - Saves progress if your executor supports writefile/readfile
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local GUI_NAME = "AFKSlotsMinigame"
local SAVE_FILE = "AFKSlots_save.json"

-- icon, pick weight, payout multiplier when ALL reels match (at 3 reels)
local ICONS = {
    { icon = "🍒", weight = 40, payout = 3  },
    { icon = "🍋", weight = 30, payout = 5  },
    { icon = "💎", weight = 20, payout = 10 },
    { icon = "7️⃣", weight = 10, payout = 25 },
}
local TWO_MATCH_PAYOUT = 0.8   -- payout for the smallest winning match (2 same icons)
local MATCH_GROWTH = 1.4       -- every extra matching icon multiplies payout by this
local MIN_REELS, MAX_REELS = 3, 10
local BASE_START_COINS = 100
local COIN_CAP = 1e300

local SUFFIXES = {
    "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No",
    "Dc", "UDc", "DDc", "TDc", "QaDc", "QiDc", "SxDc", "SpDc", "OcDc", "NoDc", "Vg",
}

-- bet steps: 10, 50, 100, 500, 1K, 5K ... (very far)
local BETS = {}
for e = 1, 100 do
    table.insert(BETS, 10 ^ e)
    table.insert(BETS, 5 * 10 ^ e)
end

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local state = {
    coins = BASE_START_COINS,
    betIndex = 1,
    reels = MIN_REELS,
    -- coin upgrades (reset on rebirth)
    payout = 0,
    luck = 0,
    income = 0,
    -- progression
    rebirths = 0,
    prestige = 0,
    tokens = 0,
    -- tech tree (permanent, bought with tokens)
    tPayout = 0,
    tLuck = 0,
    tIncome = 0,
    tRebirth = 0,
    tStart = 0,
}

local alive = true
local spinning = false
local autoSpin = false
local autoBet = false

---------------------------------------------------------------------
-- SAVE / LOAD (optional)
---------------------------------------------------------------------
local canFile = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

local function saveGame()
    if not canFile then return end
    pcall(function()
        writefile(SAVE_FILE, HttpService:JSONEncode(state))
    end)
end

local function loadGame()
    if not canFile then return end
    pcall(function()
        if isfile(SAVE_FILE) then
            local data = HttpService:JSONDecode(readfile(SAVE_FILE))
            for k, v in pairs(data) do
                if state[k] ~= nil and type(v) == "number" and v == v and v ~= math.huge then
                    state[k] = v
                end
            end
            -- migrate from v1 save
            if data.upgrade and data.payout == nil then
                state.payout = data.upgrade
            end
            if data.tokens == nil and (data.prestige or 0) > 0 then
                state.tokens = data.prestige * (data.prestige + 1) / 2
            end
        end
    end)
    state.reels = math.clamp(math.floor(state.reels), MIN_REELS, MAX_REELS)
    state.betIndex = math.clamp(math.floor(state.betIndex), 1, #BETS)
    state.coins = math.min(state.coins, COIN_CAP)
end

loadGame()

---------------------------------------------------------------------
-- NUMBER FORMATTING
---------------------------------------------------------------------
local function fmt(n)
    if n ~= n then return "0" end
    if n < 1000 then return tostring(math.floor(n)) end
    local group = math.floor(math.log10(n) / 3)
    local v = n / 1000 ^ group
    if v >= 999.995 then
        group = group + 1
        v = n / 1000 ^ group
    end
    if group >= #SUFFIXES then
        return string.format("%.2e", n)
    end
    return string.format("%.2f%s", v, SUFFIXES[group + 1])
end

local function fmtDec(n)
    if n < 1000 then return string.format("%.2f", n) end
    return fmt(n)
end

---------------------------------------------------------------------
-- GAME MATH
---------------------------------------------------------------------
local function startCoins()    return BASE_START_COINS * 5 ^ state.tStart end

local function payoutMult()    return 1 + 0.10 * state.payout end
local function rebirthPer()    return 0.5 + 0.1 * state.tRebirth end
local function rebirthMult()   return 1 + rebirthPer() * state.rebirths end
local function prestigeMult()  return 1 + 1.00 * state.prestige end
local function techMult()      return 1 + 0.25 * state.tPayout end
local function totalMult()     return payoutMult() * rebirthMult() * prestigeMult() * techMult() end

local function luckLevels()    return state.luck + 5 * state.tLuck end
local function incomePerSec()  return (1 + state.income) * (1 + 0.5 * state.tIncome) * totalMult() end

local function payoutCost()    return 100 * 1.5 ^ state.payout end
local function luckCost()      return 250 * 1.8 ^ state.luck end
local function incomeCost()    return 200 * 1.6 ^ state.income end
local function reelCost()      return 2500 * 8 ^ (state.reels - MIN_REELS) end
local function rebirthCost()   return 5000 * 2.5 ^ state.rebirths end
local function prestigeNeed()  return 5 + 2 * state.prestige end

local function addCoins(x)
    state.coins = math.min(COIN_CAP, state.coins + x)
end

local function pickIcon()
    local f = 1 + 0.03 * luckLevels()
    local ws, total = {}, 0
    for i, it in ipairs(ICONS) do
        ws[i] = it.weight * f ^ (i - 1)
        total = total + ws[i]
    end
    local r = math.random() * total
    local acc = 0
    for i = 1, #ICONS do
        acc = acc + ws[i]
        if r <= acc then return i end
    end
    return 1
end

local function bestBetIndex(limit)
    local idx = 1
    for i, b in ipairs(BETS) do
        if b <= limit then idx = i else break end
    end
    return idx
end

---------------------------------------------------------------------
-- GUI HELPERS
---------------------------------------------------------------------
local function getGuiParent()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then
        local ok2 = pcall(function()
            local f = Instance.new("Folder")
            f.Parent = core
            f:Destroy()
        end)
        if ok2 then return core end
    end
    return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function corner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = obj
end

local function mkLabel(parentObj, text, pos, size, textSize, color)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Text = text
    l.Position = pos
    l.Size = size
    l.Font = Enum.Font.GothamBold
    l.TextSize = textSize or 14
    l.TextColor3 = color or Color3.new(1, 1, 1)
    l.TextWrapped = true
    l.Parent = parentObj
    return l
end

local function mkButton(parentObj, text, pos, size, color)
    local b = Instance.new("TextButton")
    b.Text = text
    b.Position = pos
    b.Size = size
    b.BackgroundColor3 = color
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextWrapped = true
    b.BorderSizePixel = 0
    b.AutoButtonColor = true
    b.Parent = parentObj
    corner(b, 8)
    return b
end

local function mkScroll(parentObj, pos, size)
    local s = Instance.new("ScrollingFrame")
    s.Position = pos
    s.Size = size
    s.BackgroundTransparency = 1
    s.BorderSizePixel = 0
    s.ScrollBarThickness = 4
    s.CanvasSize = UDim2.new(0, 0, 0, 0)
    s.AutomaticCanvasSize = Enum.AutomaticSize.Y
    s.Parent = parentObj
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 6)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = s
    return s
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos
    handle.Active = true
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

---------------------------------------------------------------------
-- GUI BUILD
---------------------------------------------------------------------
local parent = getGuiParent()
local old = parent:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = parent

gui.Destroying:Connect(function()
    alive = false
    autoSpin = false
end)

-- Main window
local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 360, 0, 500)
main.Position = UDim2.new(0.5, -180, 0.5, -250)
main.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
main.BorderSizePixel = 0
main.Visible = true
main.Parent = gui
corner(main, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 200, 60)
stroke.Thickness = 2
stroke.Parent = main

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 56)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
corner(titleBar, 12)
makeDraggable(titleBar, main)

local titleLabel = mkLabel(titleBar, "🎰  AFK Slots  ∞", UDim2.new(0, 12, 0, 0), UDim2.new(1, -60, 1, 0), 16, Color3.fromRGB(255, 210, 80))
titleLabel.TextXAlignment = Enum.TextXAlignment.Left

local closeBtn = mkButton(titleBar, "X", UDim2.new(1, -34, 0, 4), UDim2.new(0, 28, 0, 28), Color3.fromRGB(200, 60, 60))

-- Stats
local coinsLabel = mkLabel(main, "", UDim2.new(0, 0, 0, 42), UDim2.new(1, 0, 0, 28), 20, Color3.fromRGB(255, 220, 90))
local multLabel = mkLabel(main, "", UDim2.new(0, 6, 0, 70), UDim2.new(1, -12, 0, 20), 12, Color3.fromRGB(180, 180, 200))

-- Tabs
local tabHolder = Instance.new("Frame")
tabHolder.BackgroundTransparency = 1
tabHolder.Position = UDim2.new(0, 12, 0, 96)
tabHolder.Size = UDim2.new(1, -24, 0, 30)
tabHolder.Parent = main

local TAB_NAMES = { "Play", "Upgrades", "Tech" }
local TAB_TEXT = { Play = "🎰 Play", Upgrades = "⬆ Upgrades", Tech = "🌳 Tech Tree" }
local tabButtons = {}
for i, name in ipairs(TAB_NAMES) do
    tabButtons[name] = mkButton(tabHolder, TAB_TEXT[name], UDim2.new((i - 1) / 3, 2, 0, 0), UDim2.new(1 / 3, -4, 1, 0), Color3.fromRGB(70, 70, 95))
end

-- Pages
local pageHolder = Instance.new("Frame")
pageHolder.BackgroundTransparency = 1
pageHolder.Position = UDim2.new(0, 12, 0, 132)
pageHolder.Size = UDim2.new(1, -24, 0, 330)
pageHolder.Parent = main

local pages = {}
for _, name in ipairs(TAB_NAMES) do
    local p = Instance.new("Frame")
    p.BackgroundTransparency = 1
    p.Size = UDim2.new(1, 0, 1, 0)
    p.Visible = (name == "Play")
    p.Parent = pageHolder
    pages[name] = p
end

local function showTab(name)
    for n, p in pairs(pages) do
        p.Visible = (n == name)
        tabButtons[n].BackgroundColor3 = (n == name) and Color3.fromRGB(255, 190, 50) or Color3.fromRGB(70, 70, 95)
        tabButtons[n].TextColor3 = (n == name) and Color3.fromRGB(20, 20, 20) or Color3.new(1, 1, 1)
    end
end

-- Status line (always visible)
local statusLabel = mkLabel(main, "Press SPIN to play!", UDim2.new(0, 10, 0, 466), UDim2.new(1, -20, 0, 26), 13, Color3.fromRGB(200, 200, 220))

local function setResult(text, color)
    statusLabel.Text = text
    statusLabel.TextColor3 = color or Color3.fromRGB(200, 200, 220)
end

local RED = Color3.fromRGB(255, 120, 120)
local GREEN = Color3.fromRGB(110, 255, 140)
local BLUE = Color3.fromRGB(120, 180, 255)

-- PLAY PAGE -----------------------------------------------------------
local playPage = pages.Play

local reelHolder = Instance.new("Frame")
reelHolder.BackgroundTransparency = 1
reelHolder.Position = UDim2.new(0, 0, 0, 0)
reelHolder.Size = UDim2.new(1, 0, 0, 120)
reelHolder.Parent = playPage

local betMinus = mkButton(playPage, "-", UDim2.new(0, 0, 0, 132), UDim2.new(0, 40, 0, 34), Color3.fromRGB(70, 70, 95))
local betLabel = mkLabel(playPage, "", UDim2.new(0, 44, 0, 132), UDim2.new(1, -146, 0, 34), 15)
local betPlus = mkButton(playPage, "+", UDim2.new(1, -98, 0, 132), UDim2.new(0, 40, 0, 34), Color3.fromRGB(70, 70, 95))
local betMax = mkButton(playPage, "MAX", UDim2.new(1, -54, 0, 132), UDim2.new(0, 54, 0, 34), Color3.fromRGB(150, 90, 60))

local spinBtn = mkButton(playPage, "SPIN", UDim2.new(0, 0, 0, 174), UDim2.new(0.6, -4, 0, 42), Color3.fromRGB(50, 170, 90))
spinBtn.TextSize = 18
local autoBtn = mkButton(playPage, "Auto: OFF", UDim2.new(0.6, 4, 0, 174), UDim2.new(0.4, -4, 0, 42), Color3.fromRGB(90, 90, 120))
local autoBetBtn = mkButton(playPage, "Auto Bet (10% of coins): OFF", UDim2.new(0, 0, 0, 224), UDim2.new(1, 0, 0, 32), Color3.fromRGB(90, 90, 120))

local infoLabel = mkLabel(playPage, "", UDim2.new(0, 0, 0, 264), UDim2.new(1, 0, 0, 60), 12, Color3.fromRGB(160, 160, 185))
do
    local parts = {}
    for _, it in ipairs(ICONS) do
        table.insert(parts, it.icon .. " x" .. it.payout)
    end
    infoLabel.Text = "Match 2+ icons to win. More matches = bigger payout, all reels = JACKPOT!\nJackpot base: " .. table.concat(parts, "  ")
end

-- reels
local reels, reelStrokes = {}, {}
local DEFAULT_STROKE = Color3.fromRGB(90, 90, 120)

local function buildReels()
    for _, c in ipairs(reelHolder:GetChildren()) do c:Destroy() end
    reels, reelStrokes = {}, {}
    local n = state.reels
    local cols = (n <= 5) and n or math.ceil(n / 2)
    local rows = (n <= 5) and 1 or 2
    for i = 1, n do
        local r = math.floor((i - 1) / cols)
        local c = (i - 1) % cols
        local box = Instance.new("TextLabel")
        box.Size = UDim2.new(1 / cols, -6, 1 / rows, -6)
        box.Position = UDim2.new(c / cols, 3, r / rows, 3)
        box.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
        box.BorderSizePixel = 0
        box.Font = Enum.Font.GothamBold
        box.TextScaled = true
        box.TextColor3 = Color3.new(1, 1, 1)
        box.Text = ICONS[((i - 1) % #ICONS) + 1].icon
        box.Parent = reelHolder
        corner(box, 10)
        local cons = Instance.new("UITextSizeConstraint")
        cons.MaxTextSize = 48
        cons.Parent = box
        local pad = Instance.new("UIPadding")
        pad.PaddingTop = UDim.new(0, 6)
        pad.PaddingBottom = UDim.new(0, 6)
        pad.Parent = box
        local s = Instance.new("UIStroke")
        s.Color = DEFAULT_STROKE
        s.Thickness = 2
        s.Parent = box
        reels[i] = box
        reelStrokes[i] = s
    end
end

-- UPGRADES PAGE -------------------------------------------------------
local upScroll = mkScroll(pages.Upgrades, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, 0))

-- TECH PAGE -----------------------------------------------------------
local tokensLabel = mkLabel(pages.Tech, "", UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, 26), 16, Color3.fromRGB(255, 220, 90))
local techScroll = mkScroll(pages.Tech, UDim2.new(0, 0, 0, 30), UDim2.new(1, 0, 1, -30))

-- Toggle (open / close) button, always visible
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "Toggle"
toggleBtn.Size = UDim2.new(0, 46, 0, 46)
toggleBtn.Position = UDim2.new(0, 12, 0.5, -23)
toggleBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 60)
toggleBtn.Text = "🎰"
toggleBtn.TextSize = 24
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.BorderSizePixel = 0
toggleBtn.Parent = gui
corner(toggleBtn, 23)

---------------------------------------------------------------------
-- ENTRIES (upgrade / tech buttons) + REFRESH
---------------------------------------------------------------------
local GREY = Color3.fromRGB(70, 70, 80)
local entries = {}
local pending = {}

local function addEntry(listParent, color, getText, canAfford, onClick, confirmKey)
    local b = mkButton(listParent, "", UDim2.new(), UDim2.new(1, -8, 0, 58), color)
    b.Activated:Connect(onClick)
    table.insert(entries, {
        btn = b, color = color, getText = getText,
        canAfford = canAfford, confirmKey = confirmKey,
    })
end

local function refresh()
    coinsLabel.Text = "💰 " .. fmt(state.coins)
    multLabel.Text = string.format("x%s total | Rebirths %d | Prestige %d | 🪙 %s tokens",
        fmtDec(totalMult()), state.rebirths, state.prestige, fmt(state.tokens))
    betLabel.Text = "Bet: " .. fmt(BETS[state.betIndex])
    tokensLabel.Text = "🪙 Prestige Tokens: " .. fmt(state.tokens)

    for _, e in ipairs(entries) do
        if e.confirmKey and pending[e.confirmKey] then
            e.btn.Text = "Sure? Click again\n(resets your progress)"
            e.btn.BackgroundColor3 = Color3.fromRGB(200, 70, 70)
        else
            e.btn.Text = e.getText()
            e.btn.BackgroundColor3 = e.canAfford() and e.color or GREY
        end
    end
end

local function confirmClick(key, action)
    if pending[key] then
        pending[key] = nil
        action()
        refresh()
        saveGame()
        return
    end
    pending[key] = true
    refresh()
    task.delay(3, function()
        if pending[key] then
            pending[key] = nil
            if alive then refresh() end
        end
    end)
end

local function buy(cost, apply, msg)
    if state.coins >= cost then
        state.coins = state.coins - cost
        apply()
        setResult(msg, BLUE)
        refresh()
        saveGame()
    else
        setResult("Not enough coins!", RED)
    end
end

---------------------------------------------------------------------
-- SPIN LOGIC
---------------------------------------------------------------------
local function spin()
    if spinning or not alive then return end

    -- bailout so you never get stuck broke
    if state.coins < BETS[1] then
        state.coins = startCoins()
        setResult("Broke! Here's some free coins.", Color3.fromRGB(255, 200, 120))
    end

    -- lower bet if you can't afford it
    while state.betIndex > 1 and BETS[state.betIndex] > state.coins do
        state.betIndex = state.betIndex - 1
    end

    local bet = BETS[state.betIndex]
    local n = state.reels
    local rs, strokes = reels, reelStrokes

    spinning = true
    state.coins = state.coins - bet
    setResult("Spinning...", Color3.fromRGB(200, 200, 220))
    for i = 1, n do strokes[i].Color = DEFAULT_STROKE end
    refresh()

    local final = {}
    for i = 1, n do final[i] = pickIcon() end

    local stagger = math.max(2, math.floor(21 / n))
    local done = 0
    for i = 1, n do
        task.spawn(function()
            local ticks = 10 + (i - 1) * stagger
            for _ = 1, ticks do
                if not alive then return end
                rs[i].Text = ICONS[math.random(#ICONS)].icon
                task.wait(0.06)
            end
            rs[i].Text = ICONS[final[i]].icon
            done = done + 1
        end)
    end

    repeat task.wait() until done >= n or not alive
    if not alive then return end

    -- evaluate: best icon = the one that appears most (ties -> higher payout)
    local counts = {}
    for _, id in ipairs(final) do counts[id] = (counts[id] or 0) + 1 end
    local bestId, bestK = nil, 0
    for id = 1, #ICONS do
        local k = counts[id] or 0
        if k > bestK or (k == bestK and k > 0 and ICONS[id].payout > ICONS[bestId].payout) then
            bestId, bestK = id, k
        end
    end

    local base = 0
    local msg = ""
    if bestK >= 2 then
        if bestK == n then
            base = ICONS[bestId].payout * 2 ^ (n - MIN_REELS)
            msg = "🎉 JACKPOT! "
        else
            base = TWO_MATCH_PAYOUT * MATCH_GROWTH ^ (bestK - 2)
            msg = bestK .. " match! "
        end
        for i = 1, n do
            if final[i] == bestId then strokes[i].Color = GREEN end
        end
    end

    if base > 0 then
        local winnings = bet * base * totalMult()
        addCoins(winnings)
        setResult(msg .. "+" .. fmt(winnings), GREEN)
    else
        setResult("No match. Try again!", RED)
    end

    spinning = false
    refresh()
    saveGame()
end

---------------------------------------------------------------------
-- UPGRADE ENTRIES
---------------------------------------------------------------------
local C_BLUE = Color3.fromRGB(60, 110, 200)
local C_GREEN = Color3.fromRGB(40, 150, 110)
local C_TEAL = Color3.fromRGB(40, 140, 160)
local C_RED = Color3.fromRGB(190, 70, 90)
local C_PURPLE = Color3.fromRGB(150, 80, 200)
local C_GOLD = Color3.fromRGB(210, 140, 30)

addEntry(upScroll, C_BLUE,
    function()
        return string.format("⬆ Payout Boost Lv.%d  (+10%% payout each)\nCost: %s", state.payout, fmt(payoutCost()))
    end,
    function() return state.coins >= payoutCost() end,
    function() buy(payoutCost(), function() state.payout = state.payout + 1 end, "Payout boosted!") end)

addEntry(upScroll, C_GREEN,
    function()
        return string.format("🍀 Luck Lv.%d  (rarer icons more often)\nCost: %s", state.luck, fmt(luckCost()))
    end,
    function() return state.coins >= luckCost() end,
    function() buy(luckCost(), function() state.luck = state.luck + 1 end, "Luck increased!") end)

addEntry(upScroll, C_TEAL,
    function()
        return string.format("💸 Income Lv.%d  (%s coins/sec now)\nCost: %s", state.income, fmt(incomePerSec()), fmt(incomeCost()))
    end,
    function() return state.coins >= incomeCost() end,
    function() buy(incomeCost(), function() state.income = state.income + 1 end, "Income increased!") end)

addEntry(upScroll, C_RED,
    function()
        if state.reels >= MAX_REELS then
            return string.format("🎰 Reels: %d / %d  (MAX)", state.reels, MAX_REELS)
        end
        return string.format("🎰 More Reels  %d → %d  (permanent)\nCost: %s", state.reels, state.reels + 1, fmt(reelCost()))
    end,
    function() return state.reels < MAX_REELS and state.coins >= reelCost() end,
    function()
        if spinning then
            setResult("Wait for the spin to finish!", RED)
            return
        end
        if state.reels >= MAX_REELS then
            setResult("Reels are already maxed!", RED)
            return
        end
        buy(reelCost(), function()
            state.reels = state.reels + 1
            buildReels()
        end, "New reel added! (" .. (state.reels + 1) .. ")")
    end)

addEntry(upScroll, C_PURPLE,
    function()
        return string.format("🔄 Rebirth  (+%d%% permanent each)\nCost: %s", math.floor(rebirthPer() * 100 + 0.5), fmt(rebirthCost()))
    end,
    function() return state.coins >= rebirthCost() end,
    function()
        if state.coins < rebirthCost() then
            setResult("Not enough coins to rebirth.", RED)
            return
        end
        confirmClick("rebirth", function()
            state.rebirths = state.rebirths + 1
            state.coins = startCoins()
            state.payout, state.luck, state.income = 0, 0, 0
            state.betIndex = 1
            setResult("🔄 Reborn! Permanent multiplier increased.", Color3.fromRGB(220, 150, 255))
        end)
    end, "rebirth")

addEntry(upScroll, C_GOLD,
    function()
        return string.format("⭐ Prestige  (+%d tokens, +100%% permanent)\nNeed %d rebirths (have %d)", state.prestige + 1, prestigeNeed(), state.rebirths)
    end,
    function() return state.rebirths >= prestigeNeed() end,
    function()
        if state.rebirths < prestigeNeed() then
            setResult("Need " .. prestigeNeed() .. " rebirths to prestige.", RED)
            return
        end
        confirmClick("prestige", function()
            local gained = state.prestige + 1
            state.tokens = state.tokens + gained
            state.prestige = state.prestige + 1
            state.rebirths = 0
            state.coins = startCoins()
            state.payout, state.luck, state.income = 0, 0, 0
            state.betIndex = 1
            setResult("⭐ PRESTIGE! +" .. gained .. " tokens!", Color3.fromRGB(255, 220, 90))
        end)
    end, "prestige")

---------------------------------------------------------------------
-- TECH TREE (endless, costs Prestige Tokens)
---------------------------------------------------------------------
local TECH = {
    {
        key = "tPayout", name = "💠 Coin Mastery", base = 1, growth = 1.5, color = C_BLUE,
        desc = function(l) return "Now: +" .. (25 * l) .. "% payout (+25% each)" end,
    },
    {
        key = "tLuck", name = "🍀 Lucky Charm", base = 1, growth = 1.6, color = C_GREEN,
        desc = function(l) return "Now: +" .. (5 * l) .. " free Luck levels (+5 each)" end,
    },
    {
        key = "tIncome", name = "⚙ Passive Engine", base = 1, growth = 1.5, color = C_TEAL,
        desc = function(l) return "Now: +" .. (50 * l) .. "% passive income (+50% each)" end,
    },
    {
        key = "tRebirth", name = "🔁 Rebirth Power", base = 2, growth = 1.7, color = C_PURPLE,
        desc = function(l) return "Now: +" .. (10 * l) .. "% extra per rebirth (+10% each)" end,
    },
    {
        key = "tStart", name = "🚀 Head Start", base = 2, growth = 1.8, color = C_GOLD,
        desc = function(l) return "Start with " .. fmt(BASE_START_COINS * 5 ^ l) .. " coins (x5 each)" end,
    },
}

for _, t in ipairs(TECH) do
    local function cost() return math.ceil(t.base * t.growth ^ state[t.key]) end
    addEntry(techScroll, t.color,
        function()
            return string.format("%s  Lv.%d\n%s\nCost: %s tokens", t.name, state[t.key], t.desc(state[t.key]), fmt(cost()))
        end,
        function() return state.tokens >= cost() end,
        function()
            local c = cost()
            if state.tokens >= c then
                state.tokens = state.tokens - c
                state[t.key] = state[t.key] + 1
                setResult(t.name .. " upgraded!", BLUE)
                refresh()
                saveGame()
            else
                setResult("Not enough Prestige Tokens!", RED)
            end
        end)
end

---------------------------------------------------------------------
-- BUTTON EVENTS
---------------------------------------------------------------------
for _, name in ipairs(TAB_NAMES) do
    tabButtons[name].Activated:Connect(function() showTab(name) end)
end

spinBtn.Activated:Connect(spin)

autoBtn.Activated:Connect(function()
    autoSpin = not autoSpin
    autoBtn.Text = autoSpin and "Auto: ON" or "Auto: OFF"
    autoBtn.BackgroundColor3 = autoSpin and Color3.fromRGB(50, 170, 90) or Color3.fromRGB(90, 90, 120)
end)

autoBetBtn.Activated:Connect(function()
    autoBet = not autoBet
    autoBetBtn.Text = autoBet and "Auto Bet (10% of coins): ON" or "Auto Bet (10% of coins): OFF"
    autoBetBtn.BackgroundColor3 = autoBet and Color3.fromRGB(50, 170, 90) or Color3.fromRGB(90, 90, 120)
end)

betMinus.Activated:Connect(function()
    state.betIndex = math.max(1, state.betIndex - 1)
    refresh()
end)

betPlus.Activated:Connect(function()
    state.betIndex = math.min(#BETS, state.betIndex + 1)
    refresh()
end)

betMax.Activated:Connect(function()
    state.betIndex = bestBetIndex(state.coins)
    refresh()
end)

closeBtn.Activated:Connect(function()
    main.Visible = false
end)

toggleBtn.Activated:Connect(function()
    main.Visible = not main.Visible
end)

---------------------------------------------------------------------
-- BACKGROUND LOOPS
---------------------------------------------------------------------
-- auto spin
task.spawn(function()
    while alive do
        if autoSpin and not spinning then
            if autoBet then
                state.betIndex = bestBetIndex(math.max(state.coins * 0.1, BETS[1]))
            end
            spin()
            task.wait(0.4)
        else
            task.wait(0.2)
        end
    end
end)

-- passive income
task.spawn(function()
    while alive do
        task.wait(1)
        if not alive then break end
        addCoins(incomePerSec())
        refresh()
    end
end)

-- autosave
task.spawn(function()
    while alive do
        task.wait(15)
        saveGame()
    end
end)

buildReels()
showTab("Play")
refresh()
